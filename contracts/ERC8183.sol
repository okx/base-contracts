// SPDX-License-Identifier: MIT
// ERC-8183: Agentic Commerce Protocol — Reference Implementation
pragma solidity ^0.8.28;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import "./IERC8183Hook.sol";
import "./IDisburser.sol";
import "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";

/**
 * @title ERC8183
 * @dev Reference implementation of ERC-8183: Agentic Commerce Protocol.
 *      Implements a job escrow state machine with optional hook extension points.
 *      Core state machine: Open -> Funded -> Submitted -> Completed | Rejected | Expired.
 *
 *      Hooks (IERC8183Hook):
 *        before* — called BEFORE state change, CAN revert to gate the transition.
 *        after*  — called AFTER state change for bookkeeping/side effects.
 *
 *      When hook == address(0), the contract operates as a standalone job escrow.
 */
contract ERC8183 is Initializable, AccessControlUpgradeable, PausableUpgradeable, ReentrancyGuardTransient, UUPSUpgradeable, EIP712Upgradeable {
    using SafeERC20 for IERC20;

    /// @notice Job lifecycle states
    enum JobStatus {
        Open,
        Funded,
        Submitted,
        Completed,
        Rejected,
        Expired
    }

    /// @notice Core job data, with new fields appended to preserve storage layout
    /// @param client           Job creator who funds the escrow
    /// @param status           Current lifecycle state
    /// @param provider         Service provider who delivers work
    /// @param expiredAt        Unix timestamp after which the job can be expired
    /// @param evaluator        Third-party attestor
    /// @param submittedAt      Unix timestamp when provider submitted work
    /// @param budget           Escrowed payment amount in paymentToken units
    /// @param hook             Hook contract for before/after callbacks (address(0) = no hook)
    /// @param paymentToken     ERC-20 token used for job payment
    /// @param providerAgentId  Optional ERC-8004 agent identity for provider
    /// @param description      Human-readable job description
    /// @param settledAmount    Cumulative gross amount released via claim settlements
    /// @param payoutReceiver   Provider-side payout receiver (address(0) = pay provider directly)
    struct Job {
        address client;             // 20 ──┐ slot 1
        JobStatus status;           // 1  ──┘
        address provider;           // 20 ──┐ slot 2
        uint48 expiredAt;           // 6  ──┘
        address evaluator;          // 20 ──┐ slot 3
        uint48 submittedAt;         // 6  ──┘ 
        uint256 budget;             // 32 ──  slot 4
        address hook;               // 20 ──  slot 5
        address paymentToken;       // 20 ──  slot 6
        uint256 providerAgentId;    // 32 ──  slot 7
        string description;         //        slot 8+
        uint256 settledAmount;      // 32 ──  slot 9
        address payoutReceiver;     // 20 ──  slot 10
    }

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    string internal constant EIP712_NAME = "ERC8183";
    string internal constant EIP712_VERSION = "1";

    /// @notice Grace period after expiry during which only the evaluator can finalize a Submitted job.
    ///         Prevents third-party censorship of providers who submitted work before expiry.
    uint256 public constant EVALUATION_GRACE_PERIOD = 1 hours;

    /// @notice Platform fee in basis points (10000 = 100%)
    uint256 public platformFeeBP; // 10000 = 100%
    /// @notice Address that receives platform fees
    address public platformTreasury;
    /// @notice Evaluator fee in basis points (10000 = 100%)
    uint256 public evaluatorFeeBP;

    /// @notice Job ID -> Job data
    mapping(uint256 => Job) public jobs;
    /// @notice Monotonically increasing job ID counter
    uint256 public jobCounter;
    /// @notice Hook address -> whether it is whitelisted for use
    mapping(address => bool) public whitelistedHooks;
    /// @notice ERC-20 token -> whether it is allowed as a payment token
    /// @dev    Allowlist enforces that only tokens with vetted ERC-20 semantics
    ///         (no fee-on-transfer, no rebase, no transfer hooks, no pause/blacklist
    ///         that would lock escrowed funds) can be used for job budgets.
    mapping(address => bool) public allowedPaymentTokens;
    /// @notice Job ID -> hash binding the pending nonzero-deliverable claim.
    mapping(uint256 => bytes32) public pendingClaimHash;
    /// @notice Job ID -> claim hash -> whether the claim hash has already been submitted.
    mapping(uint256 => mapping(bytes32 => bool)) public submittedClaimHash;
    /// @dev Storage gap for future ERC8183 state variable additions without colliding with derived contracts.
    uint256[50] private __gap;

    /// @notice Emitted when a new job is created
    event JobCreated(
        uint256 indexed jobId,
        address indexed client,
        address indexed provider,
        address evaluator,
        uint48 expiredAt,
        address hook
    );
    /// @notice Emitted when a provider is assigned to a job
    event ProviderSet(
        uint256 indexed jobId, 
        address indexed provider, 
        uint256 agentId
    );
    /// @notice Emitted when the payout receiver for a job is set or updated
    event PayoutReceiverSet(
        uint256 indexed jobId,
        address indexed payoutReceiver
    );
    /// @notice Emitted when onDisbursement is invoked for a receiver that advertises IDisburser
    event Disbursed(
        uint256 indexed jobId,
        address indexed receiver,
        bytes4 selector,
        uint256 amount
    );
    /// @notice Emitted when the provider sets or updates the job budget
    event BudgetSet(
        uint256 indexed jobId, 
        address indexed token, 
        uint256 amount
    );
    /// @notice Emitted when the client funds the job escrow
    event JobFunded(
        uint256 indexed jobId,
        address indexed client,
        uint256 amount
    );
    /// @notice Emitted when the provider submits a deliverable
    event JobSubmitted(
        uint256 indexed jobId,
        address indexed provider,
        bytes32 deliverable
    );
    /// @notice Emitted when a job is completed (escrow fully released to the provider)
    event JobCompleted(
        uint256 indexed jobId,
        address indexed evaluator,
        bytes32 reason
    );
    /// @notice Emitted when a job is rejected
    event JobRejected(
        uint256 indexed jobId,
        address indexed rejector,
        bytes32 reason
    );
    /// @notice Emitted when a job expires and transitions to Expired status
    event JobExpired(
        uint256 indexed jobId
    );
    /// @notice Emitted when the provider's net payment is released
    event PaymentReleased(
        uint256 indexed jobId,
        address indexed recipient,
        uint256 amount
    );
    /// @notice Emitted when the platform fee gets distributed
    event PlatformFeePaid(
        uint256 indexed jobId,
        address indexed platformTreasury,
        uint256 amount
    );
    /// @notice Emitted when the evaluator fee is distributed
    event EvaluatorFeePaid(
        uint256 indexed jobId,
        address indexed evaluator,
        uint256 amount
    );
    /// @notice Emitted when escrowed funds are returned to the client
    event Refunded(
        uint256 indexed jobId,
        address indexed client,
        uint256 amount
    );
    /// @notice Emitted on each successful partial settlement
    event Settled(
        uint256 indexed jobId,
        uint256 cumulativeAmount,
        uint256 delta
    );
    /// @notice Emitted when a provider submits a claim against a funded job
    event ClaimSubmitted(
        uint256 indexed jobId,
        address indexed provider,
        uint256 cumulativeAmount,
        uint256 delta,
        bytes32 deliverable,
        bytes optParams // Emitted so the exact claim preimage can be propagated to observers.
    );
    /// @notice Emitted when a client settles a claim directly
    /// @dev `deliverable` is the client's settlement attestation, not a verified
    ///      provider claim hash.
    event ClaimSettled(
        uint256 indexed jobId,
        address indexed settler,
        uint256 cumulativeAmount,
        uint256 delta,
        bytes32 deliverable
    );
    /// @notice Emitted when a pending claim is approved by the evaluator (`release`)
    event ClaimApproved(
        uint256 indexed jobId,
        address indexed approver,
        uint256 cumulativeAmount,
        uint256 delta,
        bytes32 deliverable
    );
    /// @notice Emitted when a pending claim is rejected, withdrawn, or superseded
    event ClaimRejected(
        uint256 indexed jobId,
        address indexed rejector,
        bytes32 reason
    );
    /// @notice Emitted when a hook's whitelist status changes
    event HookWhitelistUpdated(
        address indexed hook,
        bool status
    );
    /// @notice Emitted when a payment token's allowlist status changes
    event PaymentTokenAllowlistUpdated(
        address indexed token,
        bool status
    );
    /// @notice Emitted when admin detaches a hook from a specific job
    event HookDetached(
        uint256 indexed jobId, 
        address indexed hook
    );
    /// @notice Emitted when the platform fee or treasury is updated
    event PlatformFeeUpdated(
        uint256 feeBP, 
        address indexed treasury
    );
    /// @notice Emitted when the evaluator fee is updated
    event EvaluatorFeeUpdated(
        uint256 feeBP
    );
    /// @notice Emitted when admin performs an emergency withdrawal while paused
    event EmergencyWithdraw(
        address indexed token, 
        address indexed to, 
        uint256 amount
    );

    /// @notice Thrown when the job ID does not exist
    error InvalidJob();
    /// @notice Thrown when the hook does not support interface IERC8183Hook
    error InvalidHook();
    /// @notice Thrown when the payout receiver would strand funds in this escrow
    error InvalidReceiver();
    /// @notice Thrown when the job is not in a valid status for the requested action
    error WrongStatus();
    /// @notice Thrown when the caller is not authorized for the requested action
    error Unauthorized();
    /// @notice Thrown when a required address parameter is address(0)
    error ZeroAddress();
    /// @notice Thrown when the job expiry is too soon (must be > 5 minutes from now)
    error ExpiryTooShort();
    /// @notice Thrown when funding a job that has no provider assigned
    error ProviderNotSet();
    /// @notice Thrown when combined platform + evaluator fees exceed 100%
    error FeesTooHigh();
    /// @notice Thrown when a non-whitelisted hook is used in job creation
    error HookNotWhitelisted();
    /// @notice Thrown when the client's expectedBudget does not match the stored budget
    error BudgetMismatch();
    /// @notice Thrown when the client's expected payment token does not match the stored payment token
    error PaymentTokenMismatch();
    /// @notice Thrown when the evaluator and provider are the same address
    error ProviderCannotBeEvaluator();
    /// @notice Thrown when the client and provider are the same address
    error ClientCannotBeProvider();
    /// @notice Thrown when a Submitted job is within the post-expiry evaluator grace period
    error GracePeriodActive();
    /// @notice Thrown when the payment token is not on the allowlist
    error PaymentTokenNotAllowed();
    /// @notice Thrown when funded amount received differs from expected (fee-on-transfer / rebasing tokens)
    error UnexpectedFundedAmount();
    /// @notice Thrown when a claim does not advance the cumulative amount
    error NoNewSettlement();
    /// @notice Thrown when cumulative settlement would exceed the job budget
    error ExceedsBudget();
    /// @notice Thrown when releasing a Submitted (final-delivery) job with anything other than
    ///         the full budget — the final release must drain the whole escrow to the provider.
    error MustReleaseFullBudget();
    /// @notice Thrown when submitting a nonzero-deliverable claim hash that was already submitted
    error ClaimAlreadySubmitted();
    /// @notice Thrown when submitting a provider claim without a deliverable
    error EmptyDeliverable();
    /// @notice Thrown when submitting a provider claim or refunding while another claim is pending
    error PendingClaimExists();
    /// @notice Thrown when release (approve) or reject(claimHash) is called with no matching pending claim
    error NoPendingClaim();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the proxy with treasury and admin
    function initialize(address treasury_, address admin_) public virtual initializer {
        __ERC8183_init(treasury_, admin_, EIP712_NAME, EIP712_VERSION);
    }

    function __ERC8183_init(
        address treasury_,
        address admin_,
        string memory eip712Name_,
        string memory eip712Version_
    ) internal onlyInitializing {
        if (treasury_ == address(0) || admin_ == address(0)) revert ZeroAddress();
        __AccessControl_init();
        __Pausable_init();
        __EIP712_init(eip712Name_, eip712Version_);
        platformTreasury = treasury_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(ADMIN_ROLE, admin_);
        whitelistedHooks[address(0)] = true;
    }

    /// @notice Authorize contract upgrades, restricted to DEFAULT_ADMIN_ROLE
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    // ──────────────────── Admin ────────────────────

    /// @notice Pauses all user-facing lifecycle functions
    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }

    /// @notice Unpauses all user-facing lifecycle functions
    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }

    /// @notice Emergency withdraw while the contract is paused
    ///         Pass token = address(0) for native ETH, otherwise ERC-20.
    /// @param token ERC-20 token address, or address(0) for native ETH
    /// @param to Recipient address
    /// @param amount Amount to withdraw
    function emergencyWithdraw(address token, address to, uint256 amount) external onlyRole(ADMIN_ROLE) whenPaused {
        if (to == address(0)) revert ZeroAddress();
        if (token == address(0)) {
            (bool success,) = payable(to).call{value: amount}("");
            require(success, "Transfer failed");
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
        emit EmergencyWithdraw(token, to, amount);
    }

    /// @notice Updates the platform fee and treasury address
    /// @param feeBP_ New platform fee in basis points
    /// @param treasury_ New treasury address
    function setPlatformFee(
        uint256 feeBP_,
        address treasury_
    ) external onlyRole(ADMIN_ROLE) {
        if (treasury_ == address(0)) revert ZeroAddress();
        if (feeBP_ + evaluatorFeeBP > 10000) revert FeesTooHigh();
        platformFeeBP = feeBP_;
        platformTreasury = treasury_;
        emit PlatformFeeUpdated(feeBP_, treasury_);
    }

    /// @notice Updates the evaluator fee
    /// @param feeBP_ New evaluator fee in basis points
    function setEvaluatorFee(uint256 feeBP_) external onlyRole(ADMIN_ROLE) {
        if (feeBP_ + platformFeeBP > 10000) revert FeesTooHigh();
        evaluatorFeeBP = feeBP_;
        emit EvaluatorFeeUpdated(feeBP_);
    }

    /// @notice Whitelist or remove a hook contract
    /// @dev    Whitelisted addresses serve two roles:
    ///         1. They can be set as the hook on new jobs (checked in createJob).
    ///         2. Hook implementations may choose to trust whitelisted addresses
    ///            as cross-hook callers. This enables routers that fan out to
    ///            sub-hooks, but it also means every whitelisted address can gain
    ///            cross-invocation power if hooks opt into that trust model. Only
    ///            whitelist contracts you fully trust and have audited.
    /// @param hook The hook contract address
    /// @param status True to whitelist, false to remove
    function setHookWhitelist(
        address hook,
        bool status
    ) external onlyRole(ADMIN_ROLE) {
        if (hook == address(0)) revert ZeroAddress();
        whitelistedHooks[hook] = status;
        emit HookWhitelistUpdated(hook, status);
    }

    /// @notice Allow or revoke an ERC-20 token as a valid payment token.
    /// @dev    Tokens with non-standard semantics — fee-on-transfer, rebasing,
    ///         ERC-777/ERC-1363 transfer hooks, pausable/blacklist behavior — break
    ///         the escrow accounting in this contract. Only allow tokens you have
    ///         verified to behave as plain ERC-20 transfers.
    /// @param token  The ERC-20 token address
    /// @param status True to allow, false to revoke
    function setPaymentTokenAllowed(
        address token,
        bool status
    ) external onlyRole(ADMIN_ROLE) {
        if (token == address(0)) revert ZeroAddress();
        allowedPaymentTokens[token] = status;
        emit PaymentTokenAllowlistUpdated(token, status);
    }

    /// @notice Detach hooks from specific jobs. Admin emergency tool for
    ///         dewhitelisted hooks still attached to in-flight jobs.
    ///         Once detached, the job behaves like vanilla ERC-8183 (no gating, no bookkeeping).
    /// @param jobIds Array of job IDs to detach hooks from
    function batchDetachHook(uint256[] calldata jobIds) external onlyRole(ADMIN_ROLE) {
        for (uint256 i = 0; i < jobIds.length; i++) {
            uint256 jobId = jobIds[i];
            if (jobId == 0 || jobId > jobCounter) revert InvalidJob();
            Job storage job = jobs[jobId];
            address oldHook = job.hook;
            if (oldHook == address(0)) continue;
            job.hook = address(0);
            emit HookDetached(jobId, oldHook);
        }
    }

    // ──────────────────── Hook Helpers ────────────────────

    /// @dev Calls beforeAction on the hook if one is attached. No-op when hook == address(0).
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

    /// @dev Calls afterAction on the hook if one is attached. No-op when hook == address(0).
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

    /// @dev Only receivers with deployed code can receive the optional callback.
    ///      EOAs and contracts that do not advertise IDisburser are plain recipients.
    function _isDisburser(address receiver) internal view returns (bool) {
        return receiver.code.length > 0 && ERC165Checker.supportsInterface(
            receiver,
            type(IDisburser).interfaceId
        );
    }

    function _payout(
        uint256 jobId,
        Job storage job,
        uint256 net,
        bytes4 selector,
        bytes calldata optParams
    ) internal {
        address recipient = job.payoutReceiver == address(0) ? job.provider : job.payoutReceiver;
        if (net > 0) {
            IERC20(job.paymentToken).safeTransfer(recipient, net);
            emit PaymentReleased(jobId, recipient, net);

            if (_isDisburser(recipient)) {
                IDisburser(recipient).onDisbursement(
                    jobId,
                    selector,
                    job.paymentToken,
                    net,
                    optParams
                );
                emit Disbursed(jobId, recipient, selector, net);
            }
        }
    }

    function _validatePayoutReceiver(address payoutReceiver, address paymentToken) internal view {
        if (payoutReceiver == address(this)) revert InvalidReceiver();
        if (payoutReceiver != address(0) && payoutReceiver == paymentToken) revert InvalidReceiver();
    }

    // ──────────────────── Job Lifecycle ────────────────────

    /// @notice Creates a new job. Client is msg.sender.
    /// @param provider Service provider (can be address(0) to assign later via setProvider)
    /// @param evaluator Third-party attestor (cannot be address(0))
    /// @param expiredAt Unix timestamp when the job expires (must be > 5 min from now)
    /// @param description Human-readable job description
    /// @param hook Hook contract address (address(0) = no hook, must be whitelisted)
    /// @param providerAgentId Optional ERC-8004 agent identity for provider
    /// @return The new job ID
    function createJob(
        address provider,
        address evaluator,
        uint48 expiredAt,
        string calldata description,
        address hook,
        uint256 providerAgentId
    ) external whenNotPaused nonReentrant returns (uint256) {
        return _createJob(msg.sender, provider, evaluator, expiredAt, description, hook, providerAgentId);
    }

    function _createJob(
        address client,
        address provider,
        address evaluator,
        uint48 expiredAt,
        string calldata description,
        address hook,
        uint256 providerAgentId
    ) internal returns (uint256) {
        if (client == address(0)) revert ZeroAddress();
        if (expiredAt <= block.timestamp + 5 minutes) revert ExpiryTooShort();
        if (client == provider) revert ClientCannotBeProvider();
        if (evaluator == address(0)) revert ZeroAddress();
        if (evaluator == provider) revert ProviderCannotBeEvaluator();
        if (!whitelistedHooks[hook]) revert HookNotWhitelisted();
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
            client: client,
            status: JobStatus.Open,
            provider: provider,
            expiredAt: expiredAt,
            evaluator: evaluator,
            submittedAt: 0,
            budget: 0,
            hook: hook,
            paymentToken: address(0),
            providerAgentId: provider != address(0) ? providerAgentId : 0,
            description: description,
            settledAmount: 0,
            payoutReceiver: address(0)
        });

        emit JobCreated(
            jobId,
            client,
            provider,
            evaluator,
            expiredAt,
            hook
        );
        return jobId;
    }

    /// @notice Provider updates the payout receiver while the job is still Open.
    ///         Locked once the job is funded.
    /// @param jobId The job to update
    /// @param payoutReceiver New payout receiver (address(0) = pay provider directly)
    function setPayoutReceiver(uint256 jobId, address payoutReceiver) external whenNotPaused nonReentrant {
        _setPayoutReceiver(msg.sender, jobId, payoutReceiver);
    }

    function _setPayoutReceiver(address actor, uint256 jobId, address payoutReceiver) internal {
        Job storage job = jobs[jobId];
        if (jobId == 0 || jobId > jobCounter) revert InvalidJob();
        if (job.status != JobStatus.Open) revert WrongStatus();
        if (block.timestamp >= job.expiredAt) revert WrongStatus();
        if (actor != job.provider) revert Unauthorized();
        _validatePayoutReceiver(payoutReceiver, job.paymentToken);
        job.payoutReceiver = payoutReceiver;
        emit PayoutReceiverSet(jobId, payoutReceiver);
    }

    /// @notice Assigns a provider to an Open job that has no provider yet. Client only.
    /// @param jobId The job to assign a provider to
    /// @param provider_ The provider address
    function setProvider(uint256 jobId, address provider_, uint256 agentId) external whenNotPaused nonReentrant {
        _setProvider(msg.sender, jobId, provider_, agentId);
    }

    function _setProvider(address actor, uint256 jobId, address provider_, uint256 agentId) internal {
        Job storage job = jobs[jobId];
        if (jobId == 0 || jobId > jobCounter) revert InvalidJob();
        if (job.status != JobStatus.Open) revert WrongStatus();
        if (block.timestamp >= job.expiredAt) revert WrongStatus();
        if (actor != job.client) revert Unauthorized();
        if (job.provider != address(0)) revert WrongStatus();
        if (provider_ == address(0)) revert ZeroAddress();
        if (provider_ == job.client) revert ClientCannotBeProvider();
        if (provider_ == job.evaluator) revert ProviderCannotBeEvaluator();
        job.provider = provider_;
        job.providerAgentId = agentId;
        emit ProviderSet(jobId, provider_, agentId);
    }

    /// @notice Provider sets or updates the job budget. Can be called multiple times while Open and not expired.
    /// @param jobId The job to set the budget for
    /// @param token ERC-20 token used for job payment
    /// @param amount Budget amount in paymentToken units
    /// @param optParams Hook-specific parameters (passed to before/after hooks)
    function setBudget(
        uint256 jobId,
        address token,
        uint256 amount,
        bytes calldata optParams
    ) external whenNotPaused nonReentrant {
        _setBudget(msg.sender, jobId, token, amount, optParams);
    }

    function _setBudget(
        address actor,
        uint256 jobId,
        address token,
        uint256 amount,
        bytes calldata optParams
    ) internal {
        Job storage job = jobs[jobId];
        if (jobId == 0 || jobId > jobCounter) revert InvalidJob();
        if (job.status != JobStatus.Open) revert WrongStatus();
        if (block.timestamp >= job.expiredAt) revert WrongStatus();
        if (actor != job.provider) revert Unauthorized();
        if (token == address(0)) revert ZeroAddress();
        if (!allowedPaymentTokens[token]) revert PaymentTokenNotAllowed();
        _validatePayoutReceiver(job.payoutReceiver, token);

        bytes memory data = abi.encode(actor, token, amount, optParams);
        _beforeHook(job.hook, jobId, this.setBudget.selector, data);

        job.paymentToken = token;
        job.budget = amount;
        emit BudgetSet(jobId, token, amount);

        _afterHook(job.hook, jobId, this.setBudget.selector, data);
    }

    /// @notice Client funds the job escrow. Transitions Open -> Funded.
    /// @param jobId The job to fund
    /// @param expectedToken Must match the stored payment token (prevents token-swap front-running)
    /// @param expectedBudget Must match the stored budget (prevents front-running)
    /// @param optParams Hook-specific parameters (passed to before/after hooks)
    function fund(
        uint256 jobId,
        address expectedToken,
        uint256 expectedBudget,
        bytes calldata optParams
    ) external whenNotPaused nonReentrant {
        _fund(msg.sender, jobId, expectedToken, expectedBudget, optParams);
    }

    function _fund(
        address actor,
        uint256 jobId,
        address expectedToken,
        uint256 expectedBudget,
        bytes calldata optParams
    ) internal {
        Job storage job = jobs[jobId];
        if (jobId == 0 || jobId > jobCounter) revert InvalidJob();
        if (job.status != JobStatus.Open) revert WrongStatus();
        if (actor != job.client) revert Unauthorized();
        if (job.provider == address(0)) revert ProviderNotSet();
        if (block.timestamp >= job.expiredAt) revert WrongStatus();
        if (job.paymentToken != expectedToken) revert PaymentTokenMismatch();
        if (job.budget != expectedBudget) revert BudgetMismatch();

        bytes memory data = abi.encode(actor, optParams);
        _beforeHook(job.hook, jobId, this.fund.selector, data);

        job.status = JobStatus.Funded;
        if (job.budget > 0) {
            IERC20 token = IERC20(job.paymentToken);
            // Snapshot balance and assert delta == budget after transfer to reject
            // fee-on-transfer and rebasing tokens that would leave escrow short.
            uint256 balanceBefore = token.balanceOf(address(this));
            token.safeTransferFrom(actor, address(this), job.budget);
            uint256 received = token.balanceOf(address(this)) - balanceBefore;
            if (received != job.budget) revert UnexpectedFundedAmount();
        }
        emit JobFunded(jobId, actor, job.budget);

        _afterHook(job.hook, jobId, this.fund.selector, data);
    }

    /// @notice Provider submits work against a job — the single generic provider entry
    ///         point. The cumulative amount asserted determines the path:
    ///         - cumulativeAmount == budget is a FINAL delivery: the job moves to
    ///           Submitted for terminal evaluation (release / reject), and any pending
    ///           milestone claim is SUPERSEDED (voided). A zero-budget job
    ///           (cumulativeAmount == 0) takes this path.
    ///         - cumulativeAmount < budget files a MILESTONE claim: reverts if a claim is
    ///           already pending (resolve it first). The evaluator approves it (`release`)
    ///           or any party cancels via `reject` with the claim hash. The job stays
    ///           Funded so further settlement can continue.
    /// @param jobId The job to submit against
    /// @param cumulativeAmount Cumulative amount asserted as due (must be <= budget)
    /// @param deliverable Hash or reference to the deliverable
    /// @param optParams Hook-specific parameters (passed to before/after hooks)
    function submit(
        uint256 jobId,
        uint256 cumulativeAmount,
        bytes32 deliverable,
        bytes calldata optParams
    ) external whenNotPaused nonReentrant {
        _submit(msg.sender, jobId, cumulativeAmount, deliverable, optParams);
    }

    function _submit(
        address actor,
        uint256 jobId,
        uint256 cumulativeAmount,
        bytes32 deliverable,
        bytes calldata optParams
    ) internal {
        Job storage job = jobs[jobId];
        if (jobId == 0 || jobId > jobCounter) revert InvalidJob();
        if (actor != job.provider) revert Unauthorized();
        if (
            job.status != JobStatus.Funded &&
            (job.status != JobStatus.Open || job.budget > 0) // Allow Open job with 0 budget to be submitted
        ) revert WrongStatus();
        if (job.expiredAt != 0 && block.timestamp >= job.expiredAt) revert WrongStatus();
        if (cumulativeAmount > job.budget) revert ExceedsBudget();

        if (cumulativeAmount == job.budget) {
            // FINAL delivery: assert the full escrow for terminal evaluation. A final submit
            // SUPERSEDES any pending milestone claim — the provider is moving to the normal
            // completion path for the entire remaining escrow, so a partial claim is moot.
            // (No double-pay risk: the monotonic settledAmount cursor governs all payouts.)
            uint256 delta = cumulativeAmount - job.settledAmount;
            bytes memory data = abi.encode(actor, cumulativeAmount, delta, deliverable, optParams);
            if (pendingClaimHash[jobId] != bytes32(0)) {
                delete pendingClaimHash[jobId];
                emit ClaimRejected(jobId, actor, bytes32("superseded-by-submit"));
            }
            _beforeHook(job.hook, jobId, this.submit.selector, data);

            job.status = JobStatus.Submitted;
            // forge-lint: disable-next-line(unsafe-typecast)
            job.submittedAt = uint48(block.timestamp);
            emit JobSubmitted(jobId, actor, deliverable);

            _afterHook(job.hook, jobId, this.submit.selector, data);
        } else {
            // MILESTONE claim: a pending settlement for part of the budget. Only ONE
            // outstanding provider claim at a time — resolve (release) or cancel (reject
            // with its hash) the pending one before filing another.
            if (job.status != JobStatus.Funded) revert WrongStatus();
            if (deliverable == bytes32(0)) revert EmptyDeliverable();
            if (pendingClaimHash[jobId] != bytes32(0)) revert PendingClaimExists();
            if (cumulativeAmount <= job.settledAmount) revert NoNewSettlement();

            uint256 delta = cumulativeAmount - job.settledAmount;
            bytes memory data = abi.encode(actor, cumulativeAmount, delta, deliverable, optParams);
            _beforeHook(job.hook, jobId, this.submit.selector, data);

            bytes32 claimHash = _claimHash(cumulativeAmount, deliverable, keccak256(optParams));
            if (submittedClaimHash[jobId][claimHash]) revert ClaimAlreadySubmitted();
            submittedClaimHash[jobId][claimHash] = true;
            pendingClaimHash[jobId] = claimHash;

            emit ClaimSubmitted(jobId, actor, cumulativeAmount, delta, deliverable, optParams);
            _afterHook(job.hook, jobId, this.submit.selector, data);
        }
    }

    /// @notice Client settles escrow directly to the provider — the fast path. CLIENT
    ///         ONLY: the evaluator may resolve a provider assertion via `release`, but
    ///         may never originate a payment on a bare Funded job (the client funded it,
    ///         only the client may voluntarily pay out without a provider assertion).
    ///         ISOLATED from the claim flow: a pending milestone claim does NOT block
    ///         settle — the monotonic settledAmount cursor prevents any double-payment.
    ///         A settle that drains the escrow completes the job and voids any pending
    ///         claim; a partial settle that overtakes a pending claim leaves it in place
    ///         (it becomes un-approvable and is cleared lazily via reject/terminate/expiry).
    /// @param jobId The job to settle against
    /// @param cumulativeAmount Cumulative amount to settle to (must be <= budget)
    /// @param deliverable Client's settlement attestation / memo
    /// @param optParams Hook-specific parameters (passed to before/after hooks)
    function settle(
        uint256 jobId,
        uint256 cumulativeAmount,
        bytes32 deliverable,
        bytes calldata optParams
    ) external whenNotPaused nonReentrant {
        _settle(msg.sender, jobId, cumulativeAmount, deliverable, optParams);
    }

    function _settle(
        address actor,
        uint256 jobId,
        uint256 cumulativeAmount,
        bytes32 deliverable,
        bytes calldata optParams
    ) internal {
        Job storage job = jobs[jobId];
        if (jobId == 0 || jobId > jobCounter) revert InvalidJob();
        if (actor != job.client) revert Unauthorized();
        if (job.status != JobStatus.Funded) revert WrongStatus();
        // NOTE: settle is intentionally NOT gated on pendingClaimHash — it is isolated from
        // the claim flow. Monotonic settledAmount is the double-payment defense.
        if (block.timestamp >= job.expiredAt) revert WrongStatus();
        if (cumulativeAmount <= job.settledAmount) revert NoNewSettlement();
        if (cumulativeAmount > job.budget) revert ExceedsBudget();

        uint256 delta = cumulativeAmount - job.settledAmount;
        bytes memory data = abi.encode(actor, cumulativeAmount, delta, deliverable, optParams);
        _beforeHook(job.hook, jobId, this.settle.selector, data);

        // A completed job carries no pending claim: if this settle drains the escrow, void
        // any pending claim BEFORE the payout (effects-before-interactions).
        if (cumulativeAmount == job.budget && pendingClaimHash[jobId] != bytes32(0)) {
            delete pendingClaimHash[jobId];
            emit ClaimRejected(jobId, actor, bytes32("superseded-by-settle"));
        }

        bool drained = _applySettlement(jobId, job, cumulativeAmount, delta, this.settle.selector, optParams);
        emit ClaimSettled(jobId, actor, cumulativeAmount, delta, deliverable);
        if (drained) _terminalizeOnDrain(jobId, job, actor);

        _afterHook(job.hook, jobId, this.settle.selector, data);
    }

    /// @notice Releases escrow toward the provider by resolving a STANDING provider
    ///         assertion — completing a final delivery (Submitted) or approving a pending
    ///         claim. EVALUATOR-ONLY: a neutral arbiter resolves every standing assertion.
    ///         A direct payment with no standing assertion is `settle` (client-only), not
    ///         `release` — the client originates payment, the evaluator resolves it.
    ///         - Submitted (final delivery): pays the full remaining escrow and completes
    ///           the job; `cumulativeAmount` must equal the budget.
    ///         - Funded with a pending claim: must match that exact claim, approving it.
    ///         Draining the escrow (settledAmount == budget) completes the job.
    ///         `deliverable` doubles as the release memo / attestation.
    /// @param jobId The job to release against
    /// @param cumulativeAmount Cumulative amount to settle to (must be <= budget)
    /// @param deliverable Settlement attestation / memo; must match a pending claim if one exists
    /// @param optParams Hook-specific parameters (passed to before/after hooks)
    function release(
        uint256 jobId,
        uint256 cumulativeAmount,
        bytes32 deliverable,
        bytes calldata optParams
    ) external whenNotPaused nonReentrant {
        _release(msg.sender, jobId, cumulativeAmount, deliverable, optParams);
    }

    function _release(
        address actor,
        uint256 jobId,
        uint256 cumulativeAmount,
        bytes32 deliverable,
        bytes calldata optParams
    ) internal {
        Job storage job = jobs[jobId];
        if (jobId == 0 || jobId > jobCounter) revert InvalidJob();
        // release is EVALUATOR-ONLY: the neutral arbiter resolves every standing provider
        // assertion — approving a pending milestone claim (Funded branch) or completing a
        // Submitted final delivery. The client never resolves an assertion; it originates
        // payment via `settle` (client-only). Trust model: originate = client, resolve =
        // evaluator, reverse/refund = evaluator.
        if (actor != job.evaluator) revert Unauthorized();

        if (job.status == JobStatus.Submitted) {
            // Final-delivery completion: release the full remaining escrow to the provider;
            // must specify the full budget (both over- and under-specifying revert).
            if (cumulativeAmount != job.budget) revert MustReleaseFullBudget();
            bytes memory finalReleaseData =
                abi.encode(actor, cumulativeAmount, job.budget - job.settledAmount, deliverable, optParams);
            _beforeHook(job.hook, jobId, this.release.selector, finalReleaseData);
            _finalize(actor, jobId, job, true, true, deliverable, this.release.selector, optParams);
            _afterHook(job.hook, jobId, this.release.selector, finalReleaseData);
            return;
        }

        if (job.status != JobStatus.Funded) revert WrongStatus();

        // APPROVE path: release acts ONLY on a standing provider assertion. With no
        // pending claim there is nothing to approve — a direct payment is `settle`
        // (client-only). This is the trust boundary: the evaluator may resolve a
        // provider's assertion but may never originate a payment on a bare Funded job.
        // Not expiry-gated — a filed claim must remain resolvable after expiry.
        bytes32 pending = pendingClaimHash[jobId];
        if (pending == bytes32(0)) revert NoPendingClaim();
        if (pending != _claimHash(cumulativeAmount, deliverable, keccak256(optParams))) revert NoPendingClaim();
        if (cumulativeAmount <= job.settledAmount) revert NoNewSettlement();
        if (cumulativeAmount > job.budget) revert ExceedsBudget();

        uint256 delta = cumulativeAmount - job.settledAmount;
        bytes memory releaseData = abi.encode(actor, cumulativeAmount, delta, deliverable, optParams);
        _beforeHook(job.hook, jobId, this.release.selector, releaseData);

        delete pendingClaimHash[jobId];
        bool drained = _applySettlement(jobId, job, cumulativeAmount, delta, this.release.selector, optParams);
        emit ClaimApproved(jobId, actor, cumulativeAmount, delta, deliverable);
        if (drained) _terminalizeOnDrain(jobId, job, actor);

        _afterHook(job.hook, jobId, this.release.selector, releaseData);
    }

    /// @notice Rejects either a single pending claim (non-terminal) or the whole job
    ///         (terminal refund), selected by `claimHash`. (Absorbs the former rejectClaim.)
    /// @dev    - claimHash != 0: cancels that pending claim only; job stays Funded.
    ///           Callable by client, evaluator, or provider (self-withdrawal).
    ///         - claimHash == 0: terminal job rejection. Open: client or provider;
    ///           Funded/Submitted: evaluator only. Refunds the unsettled remainder.
    /// @param jobId The job to reject against
    /// @param claimHash The pending claim to cancel, or bytes32(0) to reject the job
    /// @param reason Rejection reason
    /// @param optParams Hook-specific parameters (passed to before/after hooks)
    function reject(
        uint256 jobId,
        bytes32 claimHash,
        bytes32 reason,
        bytes calldata optParams
    ) external whenNotPaused nonReentrant {
        _reject(msg.sender, jobId, claimHash, reason, optParams);
    }

    function _reject(
        address actor,
        uint256 jobId,
        bytes32 claimHash,
        bytes32 reason,
        bytes calldata optParams
    ) internal {
        Job storage job = jobs[jobId];
        if (jobId == 0 || jobId > jobCounter) revert InvalidJob();

        if (claimHash != bytes32(0)) {
            // Claim-scoped cancel: non-terminal withdrawal/denial of a pending claim.
            if (job.status != JobStatus.Funded) revert WrongStatus();
            bytes32 stored = pendingClaimHash[jobId];
            if (stored == bytes32(0) || stored != claimHash) revert NoPendingClaim();
            // The provider may self-cancel a stale claim to unblock a corrected one.
            if (actor != job.client && actor != job.evaluator && actor != job.provider) revert Unauthorized();

            bytes memory claimRejectData = abi.encode(actor, claimHash, reason, optParams);
            _beforeHook(job.hook, jobId, this.reject.selector, claimRejectData);
            delete pendingClaimHash[jobId];
            emit ClaimRejected(jobId, actor, reason);
            _afterHook(job.hook, jobId, this.reject.selector, claimRejectData);
            return;
        }

        // Job-scoped terminal rejection.
        if (job.status == JobStatus.Open) {
            if (actor != job.client && actor != job.provider) revert Unauthorized();
        } else if (
            job.status == JobStatus.Funded || job.status == JobStatus.Submitted
        ) {
            if (actor != job.evaluator) revert Unauthorized();
        } else {
            revert WrongStatus();
        }

        bytes memory jobRejectData = abi.encode(actor, bytes32(0), reason, optParams);
        if (pendingClaimHash[jobId] != bytes32(0)) {
            // Terminal job rejection also rejects any pending milestone claim, so
            // hooks and indexers observe a closed claim lifecycle.
            delete pendingClaimHash[jobId];
            emit ClaimRejected(jobId, actor, reason);
        }
        bool refundEligible = (job.status == JobStatus.Funded || job.status == JobStatus.Submitted);
        _beforeHook(job.hook, jobId, this.reject.selector, jobRejectData);

        // reject is the toClient direction of the shared terminal release: it refunds the
        // unsettled remainder (when escrow was locked) and moves the job to Rejected.
        _finalize(actor, jobId, job, false, refundEligible, reason, this.reject.selector, optParams);

        _afterHook(job.hook, jobId, this.reject.selector, jobRejectData);
    }

    /// @notice Claims a refund for an expired job. Anyone can call. Transitions
    ///         Open/Funded/Submitted -> Expired after the expiry time (Submitted: after the
    ///         evaluation grace period). A pending milestone claim BLOCKS the refund
    ///         (`PendingClaimExists`): it must first be resolved (`release`) or cancelled
    ///         (`reject` with its hash), because a refund moves escrow away from the provider
    ///         and would erase a standing assertion. Not hookable, so no reverting hook can
    ///         strand the escrow. (A Submitted job carries no pending claim — a final submit
    ///         supersedes it — so the block only applies on Open/Funded.)
    /// @param jobId The expired job to claim refund for
    function claimRefund(uint256 jobId) external whenNotPaused nonReentrant {
        Job storage job = jobs[jobId];
        if (jobId == 0 || jobId > jobCounter) revert InvalidJob();
        if (job.status != JobStatus.Open && job.status != JobStatus.Funded && job.status != JobStatus.Submitted)
            revert WrongStatus();
        bool hasPendingClaim = pendingClaimHash[jobId] != bytes32(0);
        if (job.status == JobStatus.Submitted) {
            if (block.timestamp < job.expiredAt + EVALUATION_GRACE_PERIOD) revert GracePeriodActive();
        } else if (hasPendingClaim) {
            // Refund moves escrow away from the provider and would erase a standing claim;
            // gate it until the claim is resolved (release) or cancelled (reject hash).
            revert PendingClaimExists();
        } else {
            if (block.timestamp < job.expiredAt) revert WrongStatus();
        }

        JobStatus prev = job.status;
        job.status = JobStatus.Expired;

        uint256 refundAmount = job.budget - job.settledAmount;
        if (refundAmount > 0 && (prev == JobStatus.Funded || prev == JobStatus.Submitted)) {
            IERC20(job.paymentToken).safeTransfer(job.client, refundAmount);
            emit Refunded(jobId, job.client, refundAmount);
        }

        emit JobExpired(jobId);
    }

    function _distributeSettlement(
        uint256 jobId,
        Job storage job,
        uint256 delta,
        bytes4 selector,
        bytes calldata optParams
    ) internal {
        uint256 platformFee = (delta * platformFeeBP) / 10000;
        uint256 evalFee = (delta * evaluatorFeeBP) / 10000;
        uint256 net = delta - platformFee - evalFee;

        IERC20 token = IERC20(job.paymentToken);
        if (platformFee > 0) {
            token.safeTransfer(platformTreasury, platformFee);
            emit PlatformFeePaid(jobId, platformTreasury, platformFee);
        }
        if (evalFee > 0) {
            token.safeTransfer(job.evaluator, evalFee);
            emit EvaluatorFeePaid(jobId, job.evaluator, evalFee);
        }
        _payout(jobId, job, net, selector, optParams);
    }

    /// @dev Shared settlement engine for the direct path (`settle`) and the attested
    ///      path (`release` approving a pending claim). Advances the ledger, distributes
    ///      the delta, and reports whether the escrow is now fully drained. When the
    ///      settlement drains the escrow it sets the job to Completed BEFORE the payout, so
    ///      a disburser callback (onDisbursement) observing getJob() during the transfer
    ///      sees the final Completed status — never a fully-paid-but-Funded job. Callers
    ///      still emit their path-specific event and, if drained, call _terminalizeOnDrain
    ///      for the JobCompleted event.
    function _applySettlement(
        uint256 jobId,
        Job storage job,
        uint256 cumulativeAmount,
        uint256 delta,
        bytes4 selector,
        bytes calldata optParams
    ) internal returns (bool drained) {
        job.settledAmount = cumulativeAmount;
        drained = cumulativeAmount == job.budget;
        // Terminalize before the payout/callback (effects before interactions, and a
        // consistent lifecycle at the externally-observable disburser integration point).
        if (drained) job.status = JobStatus.Completed;
        _distributeSettlement(jobId, job, delta, selector, optParams);
        emit Settled(jobId, cumulativeAmount, delta);
    }

    /// @dev Universal terminal projection: when a settlement drains the escrow the job is
    ///      economically closed. The Completed status is set inside _applySettlement (before
    ///      the payout, so callbacks see it); this emits the JobCompleted lifecycle event.
    ///      The status write here is an idempotent backstop. `actor` is whoever drained the
    ///      escrow; a client `settle` carries no evaluator attestation, hence the sentinel
    ///      reason. Invariant: callers reach here with no pending claim — `settle` clears any
    ///      claim when draining, and `release`'s approve path deletes the claim before draining.
    function _terminalizeOnDrain(uint256 jobId, Job storage job, address actor) internal {
        job.status = JobStatus.Completed;
        emit JobCompleted(jobId, actor, bytes32("settled-in-full"));
    }

    /// @dev Shared terminal-release engine. `complete` and `reject` are mirror twins:
    ///      both release the unsettled remainder and move the job to a terminal state,
    ///      differing only in direction — to the provider (Completed, fees applied) or
    ///      back to the client (Rejected, a plain refund). `refundEligible` is false for
    ///      an Open-job rejection, where no escrow was ever locked.
    function _finalize(
        address actor,
        uint256 jobId,
        Job storage job,
        bool toProvider,
        bool refundEligible,
        bytes32 reason,
        bytes4 selector,
        bytes calldata optParams
    ) internal {
        uint256 remainder = job.budget - job.settledAmount;
        if (toProvider) {
            job.status = JobStatus.Completed;
            if (remainder > 0) {
                // Advance the cursor to budget so a Completed job reports settledAmount == budget
                // (the provider has now received the full escrow). Effects before the payout.
                job.settledAmount = job.budget;
                emit Settled(jobId, job.budget, remainder);
                _distributeSettlement(jobId, job, remainder, selector, optParams);
            }
            emit JobCompleted(jobId, actor, reason);
        } else {
            job.status = JobStatus.Rejected;
            if (refundEligible && remainder > 0) {
                IERC20(job.paymentToken).safeTransfer(job.client, remainder);
                emit Refunded(jobId, job.client, remainder);
            }
            emit JobRejected(jobId, actor, reason);
        }
    }

    function _claimHash(
        uint256 cumulativeAmount,
        bytes32 deliverable,
        bytes32 optParamsHash
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(cumulativeAmount, deliverable, optParamsHash));
    }

    // ──────────────────── View ────────────────────

    function getJob(uint256 jobId) external view returns (Job memory) {
        return jobs[jobId];
    }
}
