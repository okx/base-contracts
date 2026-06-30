// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// ─────────────────────────────────────────────────────────────────────────────
// ERC-8183 — settlement transition test plan (DROP-IN, NOT YET COMPILED)
//
// Targets the converged model in docs/erc8183-r1-state-redesign.md:
//   • "claim pending" is the orthogonal `pendingClaimHash != 0` flag — NO new JobStatus.
//   • 5 verbs: submit · settle · release · reject · claimRefund.
//   • settle is ISOLATED: pure cursor op, not gated by a pending claim; auto-voids an
//     overtaken claim.
//   • reject(jobId, claimHash, reason, optParams):
//       claimHash != 0 → CANCEL that exact claim (status must be Funded; revert on hash
//                        mismatch — the front-run guard; caller ∈ {provider,client,evaluator});
//                        job stays Funded ("moves on").
//       claimHash == 0 → TERMINATE: Open → client|provider; Funded/Submitted → evaluator only;
//                        voids any pending claim + refunds remainder → Rejected.
//   • claimRefund: permissionless post-expiry; BLOCKED by a pending claim (resolve first) → Expired.
//
// Lives under docs/specs/ (outside foundry's `test` path) so the spec branch stays green; it
// asserts the PROPOSED behaviour (e.g. settle-not-gated, reject front-run guard) which differs
// from the current collapse branch. `git mv` into test/ as step one of the implementation.
//
// ── Transition matrix encoded ────────────────────────────────────────────────
//  state[flag] \ verb │ submit             │ settle (client)        │ release (eval only)  │ reject(hash) (any party) │ reject(0)                    │ claimRefund (anyone)
//  ───────────────────┼────────────────────┼────────────────────────┼──────────────────────┼──────────────────────────┼──────────────────────────────┼─────────────────────
//  Open(b>0)          │ revert WrongStatus │ revert WrongStatus     │ revert               │ revert WrongStatus       │ client|prov → Rejected       │ post-exp → Expired
//  Funded[no flag]    │ <bud→set flag      │ advance / drain→Compl  │ revert NoPendingClaim│ revert NoPendingClaim    │ evaluator → Rejected+refund  │ post-exp → Expired
//                     │ =bud→Submitted     │                        │                      │ (no claim to match)      │ (client/prov → Unauthorized) │
//  Funded[flag]       │ =bud→supersede→Subm│ advance; AUTO-VOID if  │ match→approve;       │ match→cancel→Funded;     │ evaluator → void+refund→Rej  │ post-exp → revert PendingClaim
//                     │ <bud→revert Pending│ overtaken; drain→Compl │ drain→Compl else Fund│ MISMATCH→revert (TOCTOU) │ (client/prov → Unauthorized) │ (resolve first)
//  Submitted          │ revert WrongStatus │ revert WrongStatus     │ =budget→Completed    │ revert WrongStatus       │ evaluator → Rejected+refund  │ post-grace → Expired
//  Completed/Rejected/Expired → all revert WrongStatus (terminal/absorbing)
// ─────────────────────────────────────────────────────────────────────────────

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {ERC8183} from "../contracts/ERC8183.sol";
import {IDisburser} from "../contracts/IDisburser.sol";
import {MockUSDC} from "../contracts/mocks/MockUSDC.sol";

/// @notice Payout receiver that records the job status it observes DURING onDisbursement,
///         to prove a draining settle terminalizes (Completed) BEFORE the payout callback.
contract CompletionObserverDisburser is IDisburser {
    ERC8183 public core;
    uint8 public observedStatus;
    bool public called;

    constructor(ERC8183 _core) {
        core = _core;
    }

    function onDisbursement(uint256 jobId, bytes4, address, uint256, bytes calldata) external override {
        observedStatus = uint8(core.getJob(jobId).status);
        called = true;
    }

    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IDisburser).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}

contract ERC8183TransitionsTest is Test {
    uint256 constant BUDGET = 20_000_000; // 20 USDC
    uint256 constant HALF = 10_000_000; // 10 USDC

    ERC8183 core;
    MockUSDC usdc;

    address deployer = makeAddr("deployer");
    address client = makeAddr("client");
    address provider = makeAddr("provider");
    address evaluator = makeAddr("evaluator");
    address stranger = makeAddr("stranger");

    function setUp() public {
        vm.startPrank(deployer);
        usdc = new MockUSDC();
        ERC8183 impl = new ERC8183();
        core = ERC8183(address(new ERC1967Proxy(address(impl), abi.encodeCall(ERC8183.initialize, (deployer, deployer)))));
        core.setPaymentTokenAllowed(address(usdc), true);
        vm.stopPrank();

        usdc.mint(client, BUDGET);
        vm.prank(client);
        usdc.approve(address(core), BUDGET);
    }

    // ── helpers ─────────────────────────────────────────────────────────────────

    function _funded() internal returns (uint256 jobId) {
        vm.prank(client);
        jobId = core.createJob(provider, evaluator, uint48(block.timestamp + 3600), "job", address(0), 0);
        vm.prank(provider);
        core.setBudget(jobId, address(usdc), BUDGET, "");
        vm.prank(client);
        core.fund(jobId, address(usdc), BUDGET, "");
    }

    /// @dev files a partial milestone claim of HALF; returns the claim hash for reject/release.
    function _claimPending() internal returns (uint256 jobId, bytes32 claimHash) {
        jobId = _funded();
        vm.prank(provider);
        core.submit(jobId, HALF, bytes32("m1"), "");
        claimHash = core.pendingClaimHash(jobId);
        assertTrue(claimHash != bytes32(0), "claim should be pending");
        assertEq(uint8(_status(jobId)), uint8(ERC8183.JobStatus.Funded), "claim pends on Funded");
    }

    function _submitted() internal returns (uint256 jobId) {
        jobId = _funded();
        vm.prank(provider);
        core.submit(jobId, BUDGET, bytes32("final"), "");
        assertEq(uint8(_status(jobId)), uint8(ERC8183.JobStatus.Submitted));
    }

    function _status(uint256 jobId) internal view returns (ERC8183.JobStatus) {
        return core.getJob(jobId).status;
    }

    // ── reject(hash): CANCEL a claim, job moves on ───────────────────────────────

    function test_rejectHash_byProvider_cancels_movesOn() public {
        (uint256 jobId, bytes32 h) = _claimPending();
        vm.prank(provider);
        core.reject(jobId, h, bytes32("withdraw"), "");
        assertEq(uint8(_status(jobId)), uint8(ERC8183.JobStatus.Funded));
        assertEq(core.pendingClaimHash(jobId), bytes32(0));
    }

    function test_rejectHash_byClient_cancels_movesOn() public {
        (uint256 jobId, bytes32 h) = _claimPending();
        vm.prank(client);
        core.reject(jobId, h, bytes32("deny"), "");
        assertEq(uint8(_status(jobId)), uint8(ERC8183.JobStatus.Funded));
    }

    function test_rejectHash_byEvaluator_cancels_movesOn() public {
        (uint256 jobId, bytes32 h) = _claimPending();
        vm.prank(evaluator);
        core.reject(jobId, h, bytes32("arbiter-deny"), "");
        assertEq(uint8(_status(jobId)), uint8(ERC8183.JobStatus.Funded));
    }

    /// @dev after cancel the provider may re-submit — proves the job genuinely moved on.
    function test_rejectHash_thenResubmit_succeeds() public {
        (uint256 jobId, bytes32 h) = _claimPending();
        vm.prank(provider);
        core.reject(jobId, h, bytes32("withdraw"), "");
        vm.prank(provider);
        core.submit(jobId, HALF + 1, bytes32("m1-corrected"), "");
        assertTrue(core.pendingClaimHash(jobId) != bytes32(0));
    }

    // ── reject(hash): THE FRONT-RUN / TOCTOU GUARD ───────────────────────────────

    /// @dev Caller intends to cancel claim `h`, but it was rescinded first. The non-zero
    ///      claimHash + exact-match guard makes this REVERT — it must NOT fall through to
    ///      terminating the job. This is the scenario the design exists to prevent.
    function test_rejectHash_staleClaim_reverts_doesNotTerminate() public {
        (uint256 jobId, bytes32 h) = _claimPending();

        // provider front-runs: cancels the claim before the client's cancel lands
        vm.prank(provider);
        core.reject(jobId, h, bytes32("rescinded"), "");
        assertEq(core.pendingClaimHash(jobId), bytes32(0));

        // client's stale cancel now executes against "no pending claim" → must revert, NOT terminate
        vm.expectRevert(ERC8183.NoPendingClaim.selector);
        vm.prank(client);
        core.reject(jobId, h, bytes32("late-cancel"), "");

        // the job survived — it was NOT closed
        assertEq(uint8(_status(jobId)), uint8(ERC8183.JobStatus.Funded));
    }

    /// @dev A claimHash that never matched also reverts (cannot be coerced into a terminate).
    function test_rejectHash_wrongHash_reverts() public {
        (uint256 jobId,) = _claimPending();
        vm.expectRevert(ERC8183.NoPendingClaim.selector);
        vm.prank(client);
        core.reject(jobId, keccak256("not-the-claim"), bytes32("x"), "");
        assertEq(uint8(_status(jobId)), uint8(ERC8183.JobStatus.Funded));
    }

    /// @dev reject(hash) is only valid on Funded; on Submitted it reverts on status.
    function test_rejectHash_onSubmitted_revertsWrongStatus() public {
        uint256 jobId = _submitted();
        vm.expectRevert(ERC8183.WrongStatus.selector);
        vm.prank(client);
        core.reject(jobId, keccak256("anything"), bytes32("x"), "");
    }

    // ── reject(0): TERMINATE, status + auth gated ────────────────────────────────

    function test_reject0_byEvaluator_onFunded_terminates_refunds() public {
        uint256 jobId = _funded();
        uint256 bal = usdc.balanceOf(client);
        vm.prank(evaluator);
        core.reject(jobId, bytes32(0), bytes32("kill"), "");
        assertEq(uint8(_status(jobId)), uint8(ERC8183.JobStatus.Rejected));
        assertEq(usdc.balanceOf(client), bal + BUDGET);
    }

    /// @dev evaluator reject(0) terminates even with a claim pending (voids it) — no DoS wedge.
    function test_reject0_byEvaluator_withPendingClaim_voidsAndTerminates() public {
        (uint256 jobId,) = _claimPending();
        vm.prank(evaluator);
        core.reject(jobId, bytes32(0), bytes32("kill"), "");
        assertEq(uint8(_status(jobId)), uint8(ERC8183.JobStatus.Rejected));
        assertEq(core.pendingClaimHash(jobId), bytes32(0));
    }

    /// @dev THE RESIDUAL, bounded: client/provider passing 0 on Funded cannot terminate.
    function test_reject0_byClient_onFunded_revertsUnauthorized() public {
        uint256 jobId = _funded();
        vm.expectRevert(ERC8183.Unauthorized.selector);
        vm.prank(client);
        core.reject(jobId, bytes32(0), bytes32("x"), "");
    }

    function test_reject0_byProvider_onFunded_revertsUnauthorized() public {
        uint256 jobId = _funded();
        vm.expectRevert(ERC8183.Unauthorized.selector);
        vm.prank(provider);
        core.reject(jobId, bytes32(0), bytes32("x"), "");
    }

    function test_reject0_onSubmitted_byEvaluator_terminates() public {
        uint256 jobId = _submitted();
        vm.prank(evaluator);
        core.reject(jobId, bytes32(0), bytes32("reject-delivery"), "");
        assertEq(uint8(_status(jobId)), uint8(ERC8183.JobStatus.Rejected));
    }

    // ── settle ISOLATED: not gated by a pending claim ────────────────────────────

    function test_settle_notBlockedByPendingClaim() public {
        (uint256 jobId,) = _claimPending();
        // client settles BELOW the claim amount: claim survives, cursor advances
        vm.prank(client);
        core.settle(jobId, HALF - 1, bytes32("memo"), "");
        assertEq(uint8(_status(jobId)), uint8(ERC8183.JobStatus.Funded));
        assertTrue(core.pendingClaimHash(jobId) != bytes32(0), "sub-claim settle leaves claim pending");
    }

    /// @dev A non-draining settle that overtakes a claim leaves it pending (lazy cleanup):
    ///      it becomes un-approvable (release reverts) and is cleared via reject/terminate/expiry.
    function test_settle_overtakesClaim_leavesStale_lazyCleanup() public {
        (uint256 jobId, bytes32 h) = _claimPending(); // claim at HALF, deliverable "m1"
        vm.prank(client);
        core.settle(jobId, HALF + 1, bytes32("memo"), ""); // overtakes the claim (partial, < budget)

        assertTrue(core.pendingClaimHash(jobId) != bytes32(0), "claim lingers (lazy cleanup)");
        assertEq(uint8(_status(jobId)), uint8(ERC8183.JobStatus.Funded));

        // the overtaken claim is now un-approvable
        vm.expectRevert(ERC8183.NoNewSettlement.selector);
        vm.prank(evaluator);
        core.release(jobId, HALF, bytes32("m1"), "");

        // and is cleared via reject(hash)
        vm.prank(provider);
        core.reject(jobId, h, bytes32("cleanup"), "");
        assertEq(core.pendingClaimHash(jobId), bytes32(0));
    }

    function test_settle_drainsWhilePending_completes_voidsClaim() public {
        (uint256 jobId,) = _claimPending();
        vm.prank(client);
        core.settle(jobId, BUDGET, bytes32("pay-all"), "");
        assertEq(uint8(_status(jobId)), uint8(ERC8183.JobStatus.Completed));
        assertEq(core.pendingClaimHash(jobId), bytes32(0));
    }

    function test_settle_byEvaluator_revertsUnauthorized() public {
        uint256 jobId = _funded();
        vm.expectRevert(ERC8183.Unauthorized.selector);
        vm.prank(evaluator);
        core.settle(jobId, HALF, bytes32("x"), "");
    }

    // ── release: resolve a standing assertion ────────────────────────────────────

    function test_release_matchingClaim_partial_backToFunded() public {
        (uint256 jobId, bytes32 h) = _claimPending();
        h; // hash is over (cumulativeAmount, deliverable, optParamsHash)
        vm.prank(evaluator);
        core.release(jobId, HALF, bytes32("m1"), "");
        assertEq(uint8(_status(jobId)), uint8(ERC8183.JobStatus.Funded));
        assertEq(core.pendingClaimHash(jobId), bytes32(0));
    }

    function test_release_mismatch_reverts() public {
        (uint256 jobId,) = _claimPending();
        vm.expectRevert(ERC8183.NoPendingClaim.selector);
        vm.prank(evaluator);
        core.release(jobId, HALF, bytes32("WRONG"), "");
    }

    function test_release_onFundedNoClaim_revertsNoPendingClaim() public {
        uint256 jobId = _funded();
        // The authorized caller (evaluator) still reverts NoPendingClaim when there is no
        // standing assertion to resolve — release never originates a payment.
        vm.expectRevert(ERC8183.NoPendingClaim.selector);
        vm.prank(evaluator);
        core.release(jobId, HALF, bytes32("x"), "");
    }

    /// @dev Milestone approval is EVALUATOR-ONLY: the client cannot approve a pending claim
    ///      via release (it must `settle` to pay directly). Mirrors the Submitted-completion
    ///      rule — release is wholly an evaluator verb. Reverts before the claim is inspected.
    function test_release_milestone_byClient_revertsUnauthorized() public {
        (uint256 jobId,) = _claimPending(); // claim at HALF, deliverable "m1"
        vm.expectRevert(ERC8183.Unauthorized.selector);
        vm.prank(client);
        core.release(jobId, HALF, bytes32("m1"), "");
    }

    /// @dev The evaluator approves the same pending milestone claim — the happy path.
    function test_release_milestone_byEvaluator_approves() public {
        (uint256 jobId,) = _claimPending();
        vm.prank(evaluator);
        core.release(jobId, HALF, bytes32("m1"), "");
        assertEq(core.pendingClaimHash(jobId), bytes32(0), "claim cleared on approve");
        assertEq(core.getJob(jobId).settledAmount, HALF, "cursor advanced to claim");
        assertEq(uint8(_status(jobId)), uint8(ERC8183.JobStatus.Funded), "stays Funded (partial)");
    }

    function test_release_submitted_partialAmount_revertsMustReleaseFullBudget() public {
        uint256 jobId = _submitted();
        vm.expectRevert(ERC8183.MustReleaseFullBudget.selector);
        vm.prank(evaluator);
        core.release(jobId, HALF, bytes32("partial"), ""); // under-specifies the final release
    }

    function test_release_submitted_byEvaluator_completes() public {
        uint256 jobId = _submitted();
        vm.prank(evaluator);
        core.release(jobId, BUDGET, bytes32("ok"), "");
        assertEq(uint8(_status(jobId)), uint8(ERC8183.JobStatus.Completed));
    }

    /// @dev Final-delivery completion is evaluator-only: the client may NOT finalize a Submitted job.
    function test_release_submitted_byClient_revertsUnauthorized() public {
        uint256 jobId = _submitted();
        vm.expectRevert(ERC8183.Unauthorized.selector);
        vm.prank(client);
        core.release(jobId, BUDGET, bytes32("ok"), "");
    }

    // ── claimRefund: permissionless post-expiry refund, BLOCKED by a pending claim ────

    function test_claimRefund_postExpiry_blockedByPendingClaim_thenResolves() public {
        (uint256 jobId, bytes32 h) = _claimPending();
        vm.warp(block.timestamp + 3601);

        // A pending claim blocks the permissionless refund — it would erase the provider's
        // standing assertion, so it must be resolved/cancelled first.
        vm.expectRevert(ERC8183.PendingClaimExists.selector);
        vm.prank(stranger);
        core.claimRefund(jobId);

        // Any party cancels the claim by hash; then anyone may refund the full budget.
        vm.prank(provider);
        core.reject(jobId, h, bytes32("withdraw"), "");
        uint256 bal = usdc.balanceOf(client);
        vm.prank(stranger); // anyone
        core.claimRefund(jobId);
        assertEq(uint8(_status(jobId)), uint8(ERC8183.JobStatus.Expired));
        assertEq(core.pendingClaimHash(jobId), bytes32(0));
        assertEq(usdc.balanceOf(client), bal + BUDGET);
    }

    // ── submit: a FINAL submit supersedes a pending milestone claim ──────────────

    function test_submit_final_supersedesPendingClaim() public {
        (uint256 jobId,) = _claimPending(); // milestone claim pending at HALF
        // cumulativeAmount == budget → final delivery; voids the pending claim and moves to Submitted.
        vm.prank(provider);
        core.submit(jobId, BUDGET, bytes32("final"), "");
        assertEq(uint8(_status(jobId)), uint8(ERC8183.JobStatus.Submitted));
        assertEq(core.pendingClaimHash(jobId), bytes32(0), "pending claim superseded");
    }

    // ── submit: a MILESTONE submit still reverts while a claim is pending ─────────

    function test_submit_milestone_whilePending_reverts() public {
        (uint256 jobId,) = _claimPending();
        vm.expectRevert(ERC8183.PendingClaimExists.selector);
        vm.prank(provider);
        core.submit(jobId, HALF + 1, bytes32("m2"), "");
    }

    // ── drain terminalizes BEFORE the payout callback (review fix) ───────────────

    /// @dev A draining settle must set Completed before invoking the disburser callback, so
    ///      the callback never observes a fully-paid-but-Funded job. Locks the P2 review fix.
    function test_settle_drain_disburserObservesCompleted() public {
        CompletionObserverDisburser disburser = new CompletionObserverDisburser(core);
        vm.prank(client);
        uint256 jobId = core.createJob(provider, evaluator, uint48(block.timestamp + 3600), "job", address(0), 0);
        vm.prank(provider);
        core.setPayoutReceiver(jobId, address(disburser));
        vm.prank(provider);
        core.setBudget(jobId, address(usdc), BUDGET, "");
        vm.prank(client);
        core.fund(jobId, address(usdc), BUDGET, "");

        vm.prank(client);
        core.settle(jobId, BUDGET, bytes32("pay-all"), ""); // drains -> Completed

        assertTrue(disburser.called(), "disburser callback fired");
        assertEq(disburser.observedStatus(), uint8(ERC8183.JobStatus.Completed), "callback saw Completed, not Funded");
        assertEq(uint8(_status(jobId)), uint8(ERC8183.JobStatus.Completed));
    }

    // ── terminal states are absorbing ────────────────────────────────────────────

    function test_completed_isTerminal() public {
        uint256 jobId = _funded();
        vm.prank(client);
        core.settle(jobId, BUDGET, bytes32("done"), "");
        vm.expectRevert(ERC8183.WrongStatus.selector);
        vm.prank(evaluator);
        core.reject(jobId, bytes32(0), bytes32("too-late"), "");
    }

    function test_rejected_isTerminal() public {
        uint256 jobId = _funded();
        vm.prank(evaluator);
        core.reject(jobId, bytes32(0), bytes32("kill"), "");
        vm.expectRevert(ERC8183.WrongStatus.selector);
        vm.prank(provider);
        core.submit(jobId, HALF, bytes32("m"), "");
    }
}
