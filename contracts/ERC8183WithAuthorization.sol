// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import "./ERC8183.sol";

/// @title ERC8183WithAuthorization
/// @notice Adds EIP-712 signed authorization entrypoints to ERC8183.
contract ERC8183WithAuthorization is ERC8183 {
    bytes32 public constant CREATE_JOB_AUTHORIZATION_TYPEHASH = keccak256(
        "CreateJobAuthorization(address signer,address provider,address evaluator,uint48 expiredAt,bytes32 descriptionHash,address hook,uint256 providerAgentId,uint72 nonce,uint256 deadline)"
    );
    bytes32 public constant SET_PAYOUT_RECEIVER_AUTHORIZATION_TYPEHASH = keccak256(
        "SetPayoutReceiverAuthorization(address signer,uint256 jobId,address payoutReceiver,uint72 nonce,uint256 deadline)"
    );
    bytes32 public constant SET_PROVIDER_AUTHORIZATION_TYPEHASH = keccak256(
        "SetProviderAuthorization(address signer,uint256 jobId,address provider,uint256 agentId,uint72 nonce,uint256 deadline)"
    );
    bytes32 public constant SET_BUDGET_AUTHORIZATION_TYPEHASH = keccak256(
        "SetBudgetAuthorization(address signer,uint256 jobId,address token,uint256 amount,bytes32 optParamsHash,uint72 nonce,uint256 deadline)"
    );
    bytes32 public constant FUND_AUTHORIZATION_TYPEHASH = keccak256(
        "FundAuthorization(address signer,uint256 jobId,address expectedToken,uint256 expectedBudget,bytes32 optParamsHash,uint72 nonce,uint256 deadline)"
    );
    bytes32 public constant SUBMIT_AUTHORIZATION_TYPEHASH = keccak256(
        "SubmitAuthorization(address signer,uint256 jobId,uint256 cumulativeAmount,bytes32 deliverable,bytes32 optParamsHash,uint72 nonce,uint256 deadline)"
    );
    bytes32 public constant SETTLE_AUTHORIZATION_TYPEHASH = keccak256(
        "SettleAuthorization(address signer,uint256 jobId,uint256 cumulativeAmount,bytes32 deliverable,bytes32 optParamsHash,uint72 nonce,uint256 deadline)"
    );
    bytes32 public constant RELEASE_AUTHORIZATION_TYPEHASH = keccak256(
        "ReleaseAuthorization(address signer,uint256 jobId,uint48 submittedAt,uint256 cumulativeAmount,bytes32 deliverable,bytes32 optParamsHash,uint72 nonce,uint256 deadline)"
    );
    bytes32 public constant REJECT_AUTHORIZATION_TYPEHASH = keccak256(
        "RejectAuthorization(address signer,uint256 jobId,uint48 submittedAt,bytes32 claimHash,bytes32 reason,bytes32 optParamsHash,uint72 nonce,uint256 deadline)"
    );

    /// @notice Tracks used packed nonces: uint160(signer) in the upper 160 bits, 24 zero padding bits, then uint72 nonce.
    mapping(bytes32 => bool) public authorizationNonceUsed;
    /// @dev Storage gap for future ERC8183WithAuthorization state variable additions without colliding with derived contracts.
    uint256[50] private __authorizationGap;

    struct Authorization {
        address signer;
        uint72 nonce;
        uint256 deadline;
        bytes sig;
    }

    struct CreateJobAuthorizationParams {
        address provider;
        address evaluator;
        uint48 expiredAt;
        string description;
        address hook;
        uint256 providerAgentId;
    }

    event AuthorizationUsed(address indexed signer, bytes32 indexed nonce);
    event AuthorizationCanceled(address indexed signer, bytes32 indexed nonce);

    error AuthorizationExpired();
    error AuthorizationNonceUsed();
    error InvalidAuthorizationSignature();

    function initialize(address treasury_, address admin_) public override initializer {
        __ERC8183_init(treasury_, admin_, EIP712_NAME, EIP712_VERSION);
    }

    /// @notice Admin-only initializer for EIP-712 storage when adding authorization support to an existing ERC8183 proxy.
    /// @dev Sets the ERC8183/1 domain; do not call on proxies using another domain unless invalidating outstanding
    ///      signatures is intended.
    function initializeAuthorizationV2() public reinitializer(2) onlyRole(DEFAULT_ADMIN_ROLE) {
        __EIP712_init(EIP712_NAME, EIP712_VERSION);
    }

    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    /// @notice Burns one of msg.sender's authorization nonces so a signed authorization cannot be relayed later.
    /// @dev This is intentionally not relayed: only the signer can nullify their own outstanding authorization.
    ///      It is deliberately callable while paused so signers can revoke outstanding signatures during incidents.
    function cancelAuthorization(uint72 nonce) external nonReentrant {
        bytes32 packedNonce = _packAuthorizationNonce(msg.sender, nonce);
        if (authorizationNonceUsed[packedNonce]) revert AuthorizationNonceUsed();
        authorizationNonceUsed[packedNonce] = true;
        emit AuthorizationCanceled(msg.sender, packedNonce);
    }

    function createJobWithAuthorization(
        CreateJobAuthorizationParams calldata params,
        Authorization calldata auth
    ) external whenNotPaused nonReentrant returns (uint256) {
        _verifyAuthorization(
            auth.signer,
            auth.nonce,
            auth.deadline,
            keccak256(
                abi.encode(
                    CREATE_JOB_AUTHORIZATION_TYPEHASH,
                    auth.signer,
                    params.provider,
                    params.evaluator,
                    params.expiredAt,
                    keccak256(bytes(params.description)),
                    params.hook,
                    params.providerAgentId,
                    auth.nonce,
                    auth.deadline
                )
            ),
            auth.sig
        );
        return _createJob(
            auth.signer,
            params.provider,
            params.evaluator,
            params.expiredAt,
            params.description,
            params.hook,
            params.providerAgentId
        );
    }

    function setPayoutReceiverWithAuthorization(
        uint256 jobId,
        address payoutReceiver,
        Authorization calldata auth
    ) external whenNotPaused nonReentrant {
        _verifyAuthorization(
            auth.signer,
            auth.nonce,
            auth.deadline,
            keccak256(
                abi.encode(
                    SET_PAYOUT_RECEIVER_AUTHORIZATION_TYPEHASH,
                    auth.signer,
                    jobId,
                    payoutReceiver,
                    auth.nonce,
                    auth.deadline
                )
            ),
            auth.sig
        );
        _setPayoutReceiver(auth.signer, jobId, payoutReceiver);
    }

    function setProviderWithAuthorization(
        uint256 jobId,
        address provider_,
        uint256 agentId,
        Authorization calldata auth
    ) external whenNotPaused nonReentrant {
        _verifyAuthorization(
            auth.signer,
            auth.nonce,
            auth.deadline,
            keccak256(
                abi.encode(SET_PROVIDER_AUTHORIZATION_TYPEHASH, auth.signer, jobId, provider_, agentId, auth.nonce, auth.deadline)
            ),
            auth.sig
        );
        _setProvider(auth.signer, jobId, provider_, agentId);
    }

    function setBudgetWithAuthorization(
        uint256 jobId,
        address token,
        uint256 amount,
        bytes calldata optParams,
        Authorization calldata auth
    ) external whenNotPaused nonReentrant {
        _verifyAuthorization(
            auth.signer,
            auth.nonce,
            auth.deadline,
            keccak256(
                abi.encode(
                    SET_BUDGET_AUTHORIZATION_TYPEHASH,
                    auth.signer,
                    jobId,
                    token,
                    amount,
                    keccak256(optParams),
                    auth.nonce,
                    auth.deadline
                )
            ),
            auth.sig
        );
        _setBudget(auth.signer, jobId, token, amount, optParams);
    }

    function fundWithAuthorization(
        uint256 jobId,
        address expectedToken,
        uint256 expectedBudget,
        bytes calldata optParams,
        Authorization calldata auth
    ) external whenNotPaused nonReentrant {
        _verifyAuthorization(
            auth.signer,
            auth.nonce,
            auth.deadline,
            keccak256(
                abi.encode(
                    FUND_AUTHORIZATION_TYPEHASH,
                    auth.signer,
                    jobId,
                    expectedToken,
                    expectedBudget,
                    keccak256(optParams),
                    auth.nonce,
                    auth.deadline
                )
            ),
            auth.sig
        );
        _fund(auth.signer, jobId, expectedToken, expectedBudget, optParams);
    }

    function submitWithAuthorization(
        uint256 jobId,
        uint256 cumulativeAmount,
        bytes32 deliverable,
        bytes calldata optParams,
        Authorization calldata auth
    ) external whenNotPaused nonReentrant {
        _verifyAuthorization(
            auth.signer,
            auth.nonce,
            auth.deadline,
            keccak256(
                abi.encode(
                    SUBMIT_AUTHORIZATION_TYPEHASH,
                    auth.signer,
                    jobId,
                    cumulativeAmount,
                    deliverable,
                    keccak256(optParams),
                    auth.nonce,
                    auth.deadline
                )
            ),
            auth.sig
        );
        _submit(auth.signer, jobId, cumulativeAmount, deliverable, optParams);
    }

    function releaseWithAuthorization(
        uint256 jobId,
        uint256 cumulativeAmount,
        bytes32 deliverable,
        bytes calldata optParams,
        Authorization calldata auth
    ) external whenNotPaused nonReentrant {
        uint48 submittedAt = jobs[jobId].submittedAt;
        _verifyAuthorization(
            auth.signer,
            auth.nonce,
            auth.deadline,
            keccak256(
                abi.encode(
                    RELEASE_AUTHORIZATION_TYPEHASH,
                    auth.signer,
                    jobId,
                    submittedAt,
                    cumulativeAmount,
                    deliverable,
                    keccak256(optParams),
                    auth.nonce,
                    auth.deadline
                )
            ),
            auth.sig
        );
        _release(auth.signer, jobId, cumulativeAmount, deliverable, optParams);
    }

    function settleWithAuthorization(
        uint256 jobId,
        uint256 cumulativeAmount,
        bytes32 deliverable,
        bytes calldata optParams,
        Authorization calldata auth
    ) external whenNotPaused nonReentrant {
        _verifyAuthorization(
            auth.signer,
            auth.nonce,
            auth.deadline,
            keccak256(
                abi.encode(
                    SETTLE_AUTHORIZATION_TYPEHASH,
                    auth.signer,
                    jobId,
                    cumulativeAmount,
                    deliverable,
                    keccak256(optParams),
                    auth.nonce,
                    auth.deadline
                )
            ),
            auth.sig
        );
        _settle(auth.signer, jobId, cumulativeAmount, deliverable, optParams);
    }

    function rejectWithAuthorization(
        uint256 jobId,
        bytes32 claimHash,
        bytes32 reason,
        bytes calldata optParams,
        Authorization calldata auth
    ) external whenNotPaused nonReentrant {
        uint48 submittedAt = jobs[jobId].submittedAt;
        _verifyAuthorization(
            auth.signer,
            auth.nonce,
            auth.deadline,
            keccak256(
                abi.encode(
                    REJECT_AUTHORIZATION_TYPEHASH,
                    auth.signer,
                    jobId,
                    submittedAt,
                    claimHash,
                    reason,
                    keccak256(optParams),
                    auth.nonce,
                    auth.deadline
                )
            ),
            auth.sig
        );
        _reject(auth.signer, jobId, claimHash, reason, optParams);
    }

    function _verifyAuthorization(
        address signer,
        uint72 nonce,
        uint256 deadline,
        bytes32 structHash,
        bytes calldata sig
    ) internal {
        if (block.timestamp > deadline) revert AuthorizationExpired();
        bytes32 packedNonce = _packAuthorizationNonce(signer, nonce);
        if (authorizationNonceUsed[packedNonce]) revert AuthorizationNonceUsed();
        authorizationNonceUsed[packedNonce] = true;
        bytes32 digest = _hashTypedDataV4(structHash);
        if (!SignatureChecker.isValidSignatureNowCalldata(signer, digest, sig)) revert InvalidAuthorizationSignature();
        emit AuthorizationUsed(signer, packedNonce);
    }

    function _packAuthorizationNonce(address signer, uint72 nonce) internal pure returns (bytes32) {
        return bytes32((uint256(uint160(signer)) << 96) | uint256(nonce));
    }
}
