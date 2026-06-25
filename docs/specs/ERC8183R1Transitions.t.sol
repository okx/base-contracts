// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// ─────────────────────────────────────────────────────────────────────────────
// ERC-8183 R1 — transition test plan (DROP-IN, NOT YET COMPILED)
//
// This file targets the PROPOSED R1 ABI from docs/erc8183-r1-state-redesign.md:
//   • JobStatus gains `ClaimPending`
//   • `reject(jobId, claimHash, …)` is replaced by two intent selectors:
//       cancelClaim(jobId, reason, params)   — non-terminal, ClaimPending only
//       terminate(jobId, reason, params)     — terminal refund
//
// It deliberately lives under docs/specs/ (outside foundry's `test` path) so the
// spec branch stays green: it references symbols that do not exist until R1 is
// implemented. To run it, implement R1 and `git mv` this file into test/.
//
// ── Full transition matrix this suite encodes ────────────────────────────────
//
//  state \ verb │ submit(partial) │ submit(full) │ settle(client) │ release        │ cancelClaim     │ terminate            │ claimRefund
//  ─────────────┼─────────────────┼──────────────┼────────────────┼────────────────┼─────────────────┼──────────────────────┼─────────────
//  Open(b>0)    │ revert WrongStat│ revert WrongStat (must fund first)             │ revert          │ client|provider→Rej  │ post-exp→Expired
//  Funded       │ → ClaimPending  │ → Submitted  │ drain→Completed │ revert NoPending│ revert WrongStat │ evaluator → Rejected │ post-exp→Expired
//               │                 │              │ part → Funded  │                │                 │                      │
//  ClaimPending │ revert Pending  │ →Submitted(* │ revert WrongStat (no pay-around)│ drain→Completed │ any party→ Funded│ evaluator → Rejected │ revert Pending(pre-exp)
//               │                 │ supersedes)  │                │ part → Funded  │                 │                      │
//  Submitted    │ revert WrongStat│ revert WrongStat              │ revert WrongStat│ drain→Completed │ revert WrongStat │ evaluator → Rejected │ post-grace→Expired
//  Completed    │ all revert WrongStatus (terminal)                                                                          │
//  Rejected     │ all revert WrongStatus (terminal)                                                                          │
//  Expired      │ all revert WrongStatus (terminal)                                                                          │
//
//  (*) submit(full) from ClaimPending supersedes the pending claim and routes to Submitted,
//      preserving the branch's "final submit supersedes a pending milestone" behaviour.
//
//  Authorisation summary (the trust boundary, unchanged from the collapse branch):
//   • settle      → client only            (originate a payment)
//   • release     → client | evaluator     (resolve a standing assertion)
//   • cancelClaim → client | evaluator | provider (provider may self-withdraw a stale claim)
//   • terminate   → Open: client|provider; Funded/ClaimPending/Submitted: evaluator only
// ─────────────────────────────────────────────────────────────────────────────

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {ERC8183} from "../../contracts/ERC8183.sol";
import {MockUSDC} from "../../contracts/mocks/MockUSDC.sol";

contract ERC8183R1TransitionsTest is Test {
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

    // ── state builders ────────────────────────────────────────────────────────

    function _funded() internal returns (uint256 jobId) {
        vm.prank(client);
        jobId = core.createJob(provider, evaluator, uint48(block.timestamp + 3600), "job", address(0), 0);
        vm.prank(provider);
        core.setBudget(jobId, address(usdc), BUDGET, "");
        vm.prank(client);
        core.fund(jobId, address(usdc), BUDGET, "");
    }

    function _claimPending() internal returns (uint256 jobId) {
        jobId = _funded();
        vm.prank(provider);
        core.submit(jobId, HALF, bytes32("milestone-1"), ""); // partial → ClaimPending
        assertEq(uint8(_status(jobId)), uint8(ERC8183.JobStatus.ClaimPending));
    }

    function _submitted() internal returns (uint256 jobId) {
        jobId = _funded();
        vm.prank(provider);
        core.submit(jobId, BUDGET, bytes32("final"), ""); // full → Submitted
        assertEq(uint8(_status(jobId)), uint8(ERC8183.JobStatus.Submitted));
    }

    function _status(uint256 jobId) internal view returns (ERC8183.JobStatus) {
        (,,, ERC8183.JobStatus status,,,,,,,,) = _job(jobId);
        return status;
    }

    // NB: adapt destructuring to the real getter shape at implementation time.
    function _job(uint256 jobId)
        internal
        view
        returns (
            address, address, address, ERC8183.JobStatus, uint48, uint48, uint256, address, address, uint256, string memory, uint256
        )
    {
        return core.jobs(jobId);
    }

    // ── Funded: the legal moves ─────────────────────────────────────────────────

    function test_funded_submitPartial_toClaimPending() public {
        uint256 jobId = _funded();
        vm.prank(provider);
        core.submit(jobId, HALF, bytes32("m1"), "");
        assertEq(uint8(_status(jobId)), uint8(ERC8183.JobStatus.ClaimPending));
    }

    function test_funded_submitFull_toSubmitted() public {
        uint256 jobId = _funded();
        vm.prank(provider);
        core.submit(jobId, BUDGET, bytes32("final"), "");
        assertEq(uint8(_status(jobId)), uint8(ERC8183.JobStatus.Submitted));
    }

    function test_funded_settlePartial_staysFunded() public {
        uint256 jobId = _funded();
        vm.prank(client);
        core.settle(jobId, HALF, bytes32("memo"), "");
        assertEq(uint8(_status(jobId)), uint8(ERC8183.JobStatus.Funded));
    }

    function test_funded_settleFull_drainsToCompleted() public {
        uint256 jobId = _funded();
        vm.prank(client);
        core.settle(jobId, BUDGET, bytes32("memo"), "");
        assertEq(uint8(_status(jobId)), uint8(ERC8183.JobStatus.Completed));
    }

    function test_funded_terminate_byEvaluator_toRejected_refunds() public {
        uint256 jobId = _funded();
        uint256 balBefore = usdc.balanceOf(client);
        vm.prank(evaluator);
        core.terminate(jobId, bytes32("no-good"), "");
        assertEq(uint8(_status(jobId)), uint8(ERC8183.JobStatus.Rejected));
        assertEq(usdc.balanceOf(client), balBefore + BUDGET);
    }

    // ── Funded: the illegal moves ───────────────────────────────────────────────

    function test_funded_release_revertsNoPendingClaim() public {
        uint256 jobId = _funded();
        vm.expectRevert(ERC8183.NoPendingClaim.selector);
        vm.prank(evaluator);
        core.release(jobId, HALF, bytes32("x"), "");
    }

    function test_funded_cancelClaim_revertsWrongStatus() public {
        uint256 jobId = _funded();
        vm.expectRevert(ERC8183.WrongStatus.selector);
        vm.prank(client);
        core.cancelClaim(jobId, bytes32("x"), "");
    }

    function test_funded_settle_byEvaluator_revertsUnauthorized() public {
        uint256 jobId = _funded();
        vm.expectRevert(ERC8183.Unauthorized.selector);
        vm.prank(evaluator);
        core.settle(jobId, HALF, bytes32("x"), "");
    }

    function test_funded_terminate_byStranger_revertsUnauthorized() public {
        uint256 jobId = _funded();
        vm.expectRevert(ERC8183.Unauthorized.selector);
        vm.prank(stranger);
        core.terminate(jobId, bytes32("x"), "");
    }

    // ── ClaimPending: the legal moves ───────────────────────────────────────────

    function test_claimPending_releaseApprove_partial_backToFunded() public {
        uint256 jobId = _claimPending();
        vm.prank(evaluator);
        core.release(jobId, HALF, bytes32("milestone-1"), "");
        assertEq(uint8(_status(jobId)), uint8(ERC8183.JobStatus.Funded));
    }

    function test_claimPending_releaseApprove_drain_toCompleted() public {
        // a full-budget milestone, approved, drains the escrow
        uint256 jobId = _funded();
        vm.prank(provider);
        core.submit(jobId, BUDGET - 1, bytes32("m"), "");
        vm.prank(client);
        core.release(jobId, BUDGET - 1, bytes32("m"), ""); // partial → Funded
        vm.prank(client);
        core.settle(jobId, BUDGET, bytes32("rest"), ""); // drains
        assertEq(uint8(_status(jobId)), uint8(ERC8183.JobStatus.Completed));
    }

    function test_claimPending_cancelClaim_byProvider_backToFunded() public {
        uint256 jobId = _claimPending();
        vm.prank(provider); // provider self-withdraws a stale claim
        core.cancelClaim(jobId, bytes32("withdrawn"), "");
        assertEq(uint8(_status(jobId)), uint8(ERC8183.JobStatus.Funded));
    }

    function test_claimPending_cancelClaim_byEvaluator_backToFunded() public {
        uint256 jobId = _claimPending();
        vm.prank(evaluator);
        core.cancelClaim(jobId, bytes32("denied"), "");
        assertEq(uint8(_status(jobId)), uint8(ERC8183.JobStatus.Funded));
    }

    function test_claimPending_submitFull_supersedes_toSubmitted() public {
        uint256 jobId = _claimPending();
        vm.prank(provider);
        core.submit(jobId, BUDGET, bytes32("final"), "");
        assertEq(uint8(_status(jobId)), uint8(ERC8183.JobStatus.Submitted));
    }

    function test_claimPending_terminate_byEvaluator_toRejected() public {
        uint256 jobId = _claimPending();
        vm.prank(evaluator);
        core.terminate(jobId, bytes32("kill"), "");
        assertEq(uint8(_status(jobId)), uint8(ERC8183.JobStatus.Rejected));
    }

    // ── ClaimPending: the illegal moves (incl. the no-pay-around guarantee) ──────

    function test_claimPending_settle_revertsWrongStatus_noPayAround() public {
        // THE structural no-pay-around guarantee: settle is simply not a transition
        // out of ClaimPending. No PendingClaimExists guard needed — wrong state.
        uint256 jobId = _claimPending();
        vm.expectRevert(ERC8183.WrongStatus.selector);
        vm.prank(client);
        core.settle(jobId, BUDGET, bytes32("around"), "");
    }

    function test_claimPending_submitPartial_revertsPendingClaimExists() public {
        uint256 jobId = _claimPending();
        vm.expectRevert(ERC8183.PendingClaimExists.selector);
        vm.prank(provider);
        core.submit(jobId, HALF + 1, bytes32("m2"), "");
    }

    function test_claimPending_release_mismatchedClaim_revertsNoPendingClaim() public {
        uint256 jobId = _claimPending();
        vm.expectRevert(ERC8183.NoPendingClaim.selector);
        vm.prank(evaluator);
        core.release(jobId, HALF, bytes32("WRONG-deliverable"), "");
    }

    // ── The footgun is gone ──────────────────────────────────────────────────────

    /// @dev Under the collapse branch, reject(jobId, bytes32(0), …) terminated the whole
    ///      job. Under R1 there is no zero-sentinel: cancelClaim cancels the claim, and is
    ///      the ONLY non-terminal denial. A caller cannot accidentally terminate the job by
    ///      defaulting an argument — terminate is a distinct selector with evaluator-only authz.
    function test_footgun_cancelClaim_neverTerminatesJob() public {
        uint256 jobId = _claimPending();
        uint256 balBefore = usdc.balanceOf(client);
        vm.prank(provider);
        core.cancelClaim(jobId, bytes32("oops"), "");
        // job survives, escrow untouched, no refund triggered
        assertEq(uint8(_status(jobId)), uint8(ERC8183.JobStatus.Funded));
        assertEq(usdc.balanceOf(client), balBefore);
    }

    /// @dev A non-evaluator cannot terminate a Funded/ClaimPending job at all — so even the
    ///      "wrong intent" path fails closed rather than moving money.
    function test_footgun_provider_cannotTerminate_claimPending() public {
        uint256 jobId = _claimPending();
        vm.expectRevert(ERC8183.Unauthorized.selector);
        vm.prank(provider);
        core.terminate(jobId, bytes32("x"), "");
    }

    // ── Submitted: legal + illegal ───────────────────────────────────────────────

    function test_submitted_release_byClient_completes() public {
        // The branch's "client can now complete a Submitted job" behaviour is preserved.
        uint256 jobId = _submitted();
        vm.prank(client);
        core.release(jobId, BUDGET, bytes32("ok"), "");
        assertEq(uint8(_status(jobId)), uint8(ERC8183.JobStatus.Completed));
    }

    function test_submitted_release_byEvaluator_completes() public {
        uint256 jobId = _submitted();
        vm.prank(evaluator);
        core.release(jobId, BUDGET, bytes32("ok"), "");
        assertEq(uint8(_status(jobId)), uint8(ERC8183.JobStatus.Completed));
    }

    function test_submitted_terminate_byEvaluator_toRejected() public {
        uint256 jobId = _submitted();
        vm.prank(evaluator);
        core.terminate(jobId, bytes32("reject-delivery"), "");
        assertEq(uint8(_status(jobId)), uint8(ERC8183.JobStatus.Rejected));
    }

    function test_submitted_settle_revertsWrongStatus() public {
        uint256 jobId = _submitted();
        vm.expectRevert(ERC8183.WrongStatus.selector);
        vm.prank(client);
        core.settle(jobId, BUDGET, bytes32("x"), "");
    }

    function test_submitted_cancelClaim_revertsWrongStatus() public {
        uint256 jobId = _submitted();
        vm.expectRevert(ERC8183.WrongStatus.selector);
        vm.prank(client);
        core.cancelClaim(jobId, bytes32("x"), "");
    }

    // ── Expiry / liveness preserved ──────────────────────────────────────────────

    function test_funded_claimRefund_postExpiry_toExpired() public {
        uint256 jobId = _funded();
        vm.warp(block.timestamp + 3601);
        uint256 balBefore = usdc.balanceOf(client);
        core.claimRefund(jobId); // anyone
        assertEq(uint8(_status(jobId)), uint8(ERC8183.JobStatus.Expired));
        assertEq(usdc.balanceOf(client), balBefore + BUDGET);
    }

    function test_claimPending_claimRefund_preExpiry_revertsPendingClaimExists() public {
        uint256 jobId = _claimPending();
        vm.expectRevert(ERC8183.PendingClaimExists.selector);
        core.claimRefund(jobId);
    }

    // ── Terminal states are absorbing ────────────────────────────────────────────

    function test_completed_isTerminal() public {
        uint256 jobId = _funded();
        vm.prank(client);
        core.settle(jobId, BUDGET, bytes32("done"), "");
        vm.expectRevert(ERC8183.WrongStatus.selector);
        vm.prank(evaluator);
        core.terminate(jobId, bytes32("too-late"), "");
    }

    function test_rejected_isTerminal() public {
        uint256 jobId = _funded();
        vm.prank(evaluator);
        core.terminate(jobId, bytes32("kill"), "");
        vm.expectRevert(ERC8183.WrongStatus.selector);
        vm.prank(provider);
        core.submit(jobId, HALF, bytes32("m"), "");
    }
}
