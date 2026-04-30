// SPDX-License-Identifier: MIT
// ERC-8183: Agentic Commerce Protocol — Singleton Reference Implementation
pragma solidity ^0.8.28;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import "./IERC8183Hook.sol";
import "./IDisburser.sol";
import "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {EIP712Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";

/**
 * @title AgenticCommerceSingleton
 * @dev Credibly-neutral singleton implementation of ERC-8183.
 *      Admin scope is upgrade authorization only — no fee setter, no treasury,
 *      no hook whitelist. Refunds always route to job.client.
 *
 *      Settlement has two paths, switched by job.disburser:
 *        • disburser == address(0) (default): direct P2P. complete/settle
 *          transfer the full amount to job.provider. No platform fee, no
 *          IDisburser callback — the singleton itself takes nothing.
 *        • disburser != address(0): platform path. complete/settle transfer
 *          to the disburser, then call IDisburser.onSettlement so the
 *          disburser can split fees (platform/evaluator/provider) downstream.
 *
 *      Hooks: per-job opt-in, ERC-165 interface check at attach, no whitelist.
 *      claimRefund is intentionally non-hookable so escrow is always recoverable.
 */
contract AgenticCommerceSingleton is
    Initializable,
    AccessControlUpgradeable,
    ReentrancyGuardTransient,
    UUPSUpgradeable,
    EIP712Upgradeable
{
    using SafeERC20 for IERC20;

    enum JobStatus {
        Open,
        Funded,
        Submitted,
        Completed,
        Rejected,
        Expired
    }

    struct Job {
        uint256 id;
        address client;
        address provider;
        address evaluator;
        // Optional. If address(0) (default), settlement transfers directly to
        // `provider` and no platform fees apply. If set, settlement transfers
        // to this address, which is responsible for any fee splitting via the
        // IDisburser callback.
        address disburser;
        string description;
        uint256 budget;
        uint256 settledAmount;
        uint256 expiredAt;
        JobStatus status;
        address hook;
        address paymentToken;
        uint256 providerAgentId;
        uint256 submittedAt;
    }

    uint256 public constant EVALUATION_GRACE_PERIOD = 1 hours;

    mapping(uint256 => Job) public jobs;
    uint256 public jobCounter;

    event JobCreated(
        uint256 indexed jobId,
        address indexed client,
        address indexed provider,
        address evaluator,
        address disburser,
        uint256 expiredAt,
        address hook
    );
    event ProviderSet(uint256 indexed jobId, address indexed provider, uint256 agentId);
    event BudgetSet(uint256 indexed jobId, address indexed token, uint256 amount);
    event DisburserSet(uint256 indexed jobId, address indexed disburser);
    event JobFunded(uint256 indexed jobId, address indexed client, uint256 amount);
    event JobSubmitted(uint256 indexed jobId, address indexed provider, bytes32 deliverable);
    event JobCompleted(uint256 indexed jobId, address indexed evaluator, bytes32 reason);
    event JobRejected(uint256 indexed jobId, address indexed rejector, bytes32 reason);
    event JobExpired(uint256 indexed jobId);
    event PaymentReleased(uint256 indexed jobId, address indexed disburser, uint256 amount);
    event Refunded(uint256 indexed jobId, address indexed client, uint256 amount);
    event Settled(uint256 indexed jobId, uint256 cumulativeAmount, uint256 delta);

    error InvalidJob();
    error InvalidHook();
    error WrongStatus();
    error Unauthorized();
    error ZeroAddress();
    error ExpiryTooShort();
    error ProviderNotSet();
    error BudgetMismatch();
    error ProviderCannotBeEvaluator();
    error GracePeriodActive();
    error InvalidVoucherSignature();
    error NoNewSettlement();
    error ExceedsBudget();
    error InvalidDisburserResponse();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize() public initializer {
        __AccessControl_init();
        __EIP712_init("AgenticCommerce", "1");
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    /// @notice Authorize contract upgrades — the only admin power on this contract.
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    // ──────────────────── Hook Helpers ────────────────────

    function _beforeHook(
        address hook,
        uint256 jobId,
        bytes4 selector,
        bytes memory data
    ) internal {
        if (hook != address(0)) {
            IERC8183Hook(hook).beforeAction(jobId, selector, data);
        }
    }

    function _afterHook(
        address hook,
        uint256 jobId,
        bytes4 selector,
        bytes memory data
    ) internal {
        if (hook != address(0)) {
            IERC8183Hook(hook).afterAction(jobId, selector, data);
        }
    }

    /// @dev Push settlement context to the disburser if it opts in via ERC-165.
    ///      Passive receivers (EOAs, Safes, splitters) skip the callback.
    function _notifyDisburser(
        Job storage job,
        uint256 jobId,
        uint256 amount,
        bytes calldata optParams
    ) internal {
        address disburser = job.disburser;
        if (disburser == address(0) || disburser.code.length == 0) return;
        if (!ERC165Checker.supportsInterface(disburser, type(IDisburser).interfaceId)) return;

        bytes4 magic = IDisburser(disburser).onSettlement(
            jobId,
            job.paymentToken,
            amount,
            job.client,
            job.provider,
            job.evaluator,
            optParams
        );
        if (magic != IDisburser.onSettlement.selector) revert InvalidDisburserResponse();
    }

    // ──────────────────── Job Lifecycle ────────────────────

    function createJob(
        address provider,
        address evaluator,
        address disburser,
        uint256 expiredAt,
        string calldata description,
        address hook,
        uint256 providerAgentId
    ) external nonReentrant returns (uint256) {
        if (evaluator == address(0)) revert ZeroAddress();
        if (evaluator == provider) revert ProviderCannotBeEvaluator();
        if (expiredAt <= block.timestamp + 5 minutes) revert ExpiryTooShort();
        if (hook != address(0)) {
            if (
                !ERC165Checker.supportsInterface(
                    hook,
                    type(IERC8183Hook).interfaceId
                )
            ) revert InvalidHook();
        }

        uint256 jobId = ++jobCounter;
        jobs[jobId] = Job({
            id: jobId,
            client: msg.sender,
            provider: provider,
            evaluator: evaluator,
            disburser: disburser,
            description: description,
            budget: 0,
            settledAmount: 0,
            expiredAt: expiredAt,
            status: JobStatus.Open,
            hook: hook,
            paymentToken: address(0),
            providerAgentId: provider != address(0) ? providerAgentId : 0,
            submittedAt: 0
        });

        emit JobCreated(
            jobId,
            msg.sender,
            provider,
            evaluator,
            disburser,
            expiredAt,
            hook
        );

        _afterHook(
            hook,
            jobId,
            msg.sig,
            abi.encode(msg.sender, provider, evaluator, disburser)
        );

        return jobId;
    }

    function setProvider(uint256 jobId, address provider_, uint256 agentId) external {
        Job storage job = jobs[jobId];
        if (jobId == 0 || jobId > jobCounter) revert InvalidJob();
        if (job.status != JobStatus.Open) revert WrongStatus();
        if (msg.sender != job.client) revert Unauthorized();
        if (job.provider != address(0)) revert WrongStatus();
        if (provider_ == address(0)) revert ZeroAddress();
        if (provider_ == job.evaluator) revert ProviderCannotBeEvaluator();
        job.provider = provider_;
        job.providerAgentId = agentId;
        emit ProviderSet(jobId, provider_, agentId);
    }

    /// @notice Attach (or clear) a disburser before the job is funded.
    /// @dev Pass address(0) to keep the job on the direct P2P path (provider
    ///      receives full settlement, no platform fees). Pass a non-zero
    ///      address to route settlement through that contract for fee
    ///      splitting via the IDisburser callback. Locks at fund.
    function setDisburser(uint256 jobId, address disburser) external {
        Job storage job = jobs[jobId];
        if (jobId == 0 || jobId > jobCounter) revert InvalidJob();
        if (job.status != JobStatus.Open) revert WrongStatus();
        if (msg.sender != job.client) revert Unauthorized();
        job.disburser = disburser;
        emit DisburserSet(jobId, disburser);
    }

    function setBudget(
        uint256 jobId,
        address token,
        uint256 amount,
        bytes calldata optParams
    ) external nonReentrant {
        Job storage job = jobs[jobId];
        if (jobId == 0 || jobId > jobCounter) revert InvalidJob();
        if (job.status != JobStatus.Open) revert WrongStatus();
        if (msg.sender != job.client && msg.sender != job.provider) revert Unauthorized();
        if (token == address(0)) revert ZeroAddress();

        bytes memory data = abi.encode(msg.sender, token, amount, optParams);
        _beforeHook(job.hook, jobId, msg.sig, data);

        job.paymentToken = token;
        job.budget = amount;
        emit BudgetSet(jobId, token, amount);

        _afterHook(job.hook, jobId, msg.sig, data);
    }

    function fund(
        uint256 jobId,
        uint256 expectedBudget,
        bytes calldata optParams
    ) external nonReentrant {
        Job storage job = jobs[jobId];
        if (jobId == 0 || jobId > jobCounter) revert InvalidJob();
        if (job.status != JobStatus.Open) revert WrongStatus();
        if (msg.sender != job.client) revert Unauthorized();
        if (job.provider == address(0)) revert ProviderNotSet();
        if (job.budget != expectedBudget) revert BudgetMismatch();
        if (block.timestamp >= job.expiredAt) revert WrongStatus();

        bytes memory data = abi.encode(msg.sender, optParams);
        _beforeHook(job.hook, jobId, msg.sig, data);

        // disburser is locked from this point: setDisburser reverts on
        // any status != Open. Leaving job.disburser == 0 means the
        // settlement path will pay the provider directly.
        job.status = JobStatus.Funded;
        if (job.budget > 0) {
            IERC20(job.paymentToken).safeTransferFrom(
                job.client,
                address(this),
                job.budget
            );
        }
        emit JobFunded(jobId, job.client, job.budget);

        _afterHook(job.hook, jobId, msg.sig, data);
    }

    function submit(
        uint256 jobId,
        bytes32 deliverable,
        bytes calldata optParams
    ) external nonReentrant {
        Job storage job = jobs[jobId];
        if (jobId == 0 || jobId > jobCounter) revert InvalidJob();
        if (
            job.status != JobStatus.Funded &&
            (job.status != JobStatus.Open || job.budget > 0)
        ) revert WrongStatus();
        if (msg.sender != job.provider) revert Unauthorized();

        bytes memory data = abi.encode(msg.sender, deliverable, optParams);
        _beforeHook(job.hook, jobId, msg.sig, data);

        job.status = JobStatus.Submitted;
        job.submittedAt = block.timestamp;
        emit JobSubmitted(jobId, job.provider, deliverable);

        _afterHook(job.hook, jobId, msg.sig, data);
    }

    function complete(
        uint256 jobId,
        bytes32 reason,
        bytes calldata optParams
    ) external nonReentrant {
        Job storage job = jobs[jobId];
        if (jobId == 0 || jobId > jobCounter) revert InvalidJob();
        if (job.status != JobStatus.Submitted) revert WrongStatus();
        if (msg.sender != job.evaluator) revert Unauthorized();

        bytes memory data = abi.encode(msg.sender, reason, optParams);
        _beforeHook(job.hook, jobId, msg.sig, data);

        job.status = JobStatus.Completed;

        uint256 amount = job.budget - job.settledAmount;
        address payee;
        if (job.disburser != address(0)) {
            // Platform path: disburser handles any fee split downstream via
            // the IDisburser callback. Singleton itself does no fee math.
            payee = job.disburser;
            if (amount > 0) {
                IERC20(job.paymentToken).safeTransfer(payee, amount);
                _notifyDisburser(job, jobId, amount, optParams);
            }
        } else {
            // Direct P2P path: no platform attached, no fees taken, full
            // amount goes straight to the provider. Disburser callback is
            // not invoked — there is no disburser.
            payee = job.provider;
            if (amount > 0) {
                IERC20(job.paymentToken).safeTransfer(payee, amount);
            }
        }

        emit JobCompleted(jobId, job.evaluator, reason);
        emit PaymentReleased(jobId, payee, amount);

        _afterHook(job.hook, jobId, msg.sig, data);
    }

    function reject(
        uint256 jobId,
        bytes32 reason,
        bytes calldata optParams
    ) external nonReentrant {
        Job storage job = jobs[jobId];
        if (jobId == 0 || jobId > jobCounter) revert InvalidJob();

        if (job.status == JobStatus.Open) {
            if (msg.sender != job.client) revert Unauthorized();
        } else if (
            job.status == JobStatus.Funded || job.status == JobStatus.Submitted
        ) {
            if (msg.sender != job.evaluator) revert Unauthorized();
        } else {
            revert WrongStatus();
        }

        bytes memory data = abi.encode(msg.sender, reason, optParams);
        _beforeHook(job.hook, jobId, msg.sig, data);

        JobStatus prev = job.status;
        job.status = JobStatus.Rejected;

        uint256 refundAmount = job.budget - job.settledAmount;
        if (
            (prev == JobStatus.Funded || prev == JobStatus.Submitted) &&
            refundAmount > 0
        ) {
            IERC20(job.paymentToken).safeTransfer(job.client, refundAmount);
            emit Refunded(jobId, job.client, refundAmount);
        }

        emit JobRejected(jobId, msg.sender, reason);

        _afterHook(job.hook, jobId, msg.sig, data);
    }

    function claimRefund(uint256 jobId) external nonReentrant {
        Job storage job = jobs[jobId];
        if (jobId == 0 || jobId > jobCounter) revert InvalidJob();
        if (job.status != JobStatus.Open && job.status != JobStatus.Funded && job.status != JobStatus.Submitted)
            revert WrongStatus();
        if (block.timestamp < job.expiredAt) revert WrongStatus();
        if (job.status == JobStatus.Submitted &&
            block.timestamp < job.submittedAt + EVALUATION_GRACE_PERIOD)
            revert GracePeriodActive();

        job.status = JobStatus.Expired;

        uint256 refundAmount = job.budget - job.settledAmount;
        if (refundAmount > 0) {
            IERC20(job.paymentToken).safeTransfer(job.client, refundAmount);
            emit Refunded(jobId, job.client, refundAmount);
        }

        emit JobExpired(jobId);
    }

    // ──────────────────── View ────────────────────

    function getJob(uint256 jobId) external view returns (Job memory) {
        return jobs[jobId];
    }

    // ═══════════════ Partial Settlement ═══════════════

    bytes32 public constant VOUCHER_TYPEHASH =
        keccak256(
            "Voucher(uint256 jobId,uint256 cumulativeAmount,bytes optParams)"
        );

    function _verifyVoucher(
        uint256 jobId,
        uint256 cumulativeAmount,
        address expectedSigner,
        bytes calldata optParams,
        bytes calldata sig
    ) internal view {
        bytes32 structHash = keccak256(
            abi.encode(
                VOUCHER_TYPEHASH,
                jobId,
                cumulativeAmount,
                keccak256(optParams)
            )
        );
        bytes32 digest = _hashTypedDataV4(structHash);
        if (
            !SignatureChecker.isValidSignatureNowCalldata(
                expectedSigner,
                digest,
                sig
            )
        ) revert InvalidVoucherSignature();
    }

    /// @notice Voucher-based partial settlement (provider only). Releases the
    ///         delta beyond the previous cumulative amount to the disburser.
    function settle(
        uint256 jobId,
        uint256 cumulativeAmount,
        bytes calldata voucherSig,
        bytes calldata optParams
    ) external nonReentrant {
        Job storage job = jobs[jobId];
        if (jobId == 0 || jobId > jobCounter) revert InvalidJob();
        if (msg.sender != job.provider) revert Unauthorized();
        if (
            job.status != JobStatus.Funded && job.status != JobStatus.Submitted
        ) revert WrongStatus();
        if (block.timestamp >= job.expiredAt) revert WrongStatus();
        if (cumulativeAmount <= job.settledAmount) revert NoNewSettlement();
        if (cumulativeAmount > job.budget) revert ExceedsBudget();

        _verifyVoucher(
            jobId,
            cumulativeAmount,
            job.client,
            optParams,
            voucherSig
        );

        uint256 delta = cumulativeAmount - job.settledAmount;
        bytes memory data = abi.encode(msg.sender, delta, optParams);
        _beforeHook(job.hook, jobId, this.settle.selector, data);

        job.settledAmount = cumulativeAmount;
        address payee;
        if (job.disburser != address(0)) {
            // Platform path: disburser receives the delta and handles any
            // fee split via the IDisburser callback.
            payee = job.disburser;
            if (delta > 0) {
                IERC20(job.paymentToken).safeTransfer(payee, delta);
                _notifyDisburser(job, jobId, delta, optParams);
            }
        } else {
            // Direct P2P path: no platform fees, full delta to provider.
            payee = job.provider;
            if (delta > 0) {
                IERC20(job.paymentToken).safeTransfer(payee, delta);
            }
        }

        emit PaymentReleased(jobId, payee, delta);
        emit Settled(jobId, cumulativeAmount, delta);

        _afterHook(job.hook, jobId, this.settle.selector, data);
    }
}
