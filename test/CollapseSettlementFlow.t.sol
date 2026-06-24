// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {ERC8183} from "../contracts/ERC8183.sol";
import {IERC8183Hook} from "../contracts/IERC8183Hook.sol";
import {MockUSDC} from "../contracts/mocks/MockUSDC.sol";

/// @notice Hook that decodes the settlement payload to prove `delta` is now embedded
///         alongside `cumulativeAmount`.
contract DeltaRecordingHook is IERC8183Hook {
    uint256 public lastCumulative;
    uint256 public lastDelta;
    bytes4 public lastSelector;

    function beforeAction(uint256, bytes4, bytes calldata) external override {}

    function afterAction(uint256, bytes4 selector, bytes calldata data) external override {
        // submit / settle / release payload:
        // (address actor, uint256 cumulativeAmount, uint256 delta, bytes32 deliverable, bytes optParams)
        if (
            selector == ERC8183.release.selector || selector == ERC8183.settle.selector
                || selector == ERC8183.submit.selector
        ) {
            (, uint256 cumulative, uint256 delta,,) = abi.decode(data, (address, uint256, uint256, bytes32, bytes));
            lastCumulative = cumulative;
            lastDelta = delta;
            lastSelector = selector;
        }
    }

    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IERC8183Hook).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}

/// @notice Demonstrates the collapsed settlement flow:
///         - any settlement that drains the escrow auto-completes the job (Completed),
///         - settle (client-only) is an isolated path but still terminalizes on drain,
///         - a drain supersedes any unrelated pending claim,
///         - the settlement hook payload now carries `delta`,
///         - zero-budget jobs still use submit -> complete (no accidental auto-terminal).
contract CollapseSettlementFlowTest is Test {
    uint256 constant TWENTY_USDC = 20_000_000;
    uint256 constant TEN_USDC = 10_000_000;

    ERC8183 core;
    MockUSDC usdc;

    address deployer = makeAddr("deployer");
    address client = makeAddr("client");
    address provider = makeAddr("provider");
    address evaluator = makeAddr("evaluator");

    event Settled(uint256 indexed jobId, uint256 cumulativeAmount, uint256 delta);
    event ClaimSettled(
        uint256 indexed jobId, address indexed settler, uint256 cumulativeAmount, uint256 delta, bytes32 deliverable
    );
    event ClaimApproved(
        uint256 indexed jobId, address indexed approver, uint256 cumulativeAmount, uint256 delta, bytes32 deliverable
    );
    event ClaimRejected(uint256 indexed jobId, address indexed rejector, bytes32 reason);
    event JobCompleted(uint256 indexed jobId, address indexed evaluator, bytes32 reason);
    event PaymentReleased(uint256 indexed jobId, address indexed recipient, uint256 amount);

    function setUp() public {
        vm.startPrank(deployer);
        usdc = new MockUSDC();
        ERC8183 impl = new ERC8183();
        bytes memory initData = abi.encodeCall(ERC8183.initialize, (deployer, deployer));
        core = ERC8183(address(new ERC1967Proxy(address(impl), initData)));
        core.setPaymentTokenAllowed(address(usdc), true);
        vm.stopPrank();

        usdc.mint(client, TWENTY_USDC);
        vm.prank(client);
        usdc.approve(address(core), TWENTY_USDC);
    }

    function _futureExpiry() internal view returns (uint48) {
        return uint48(block.timestamp + 3600);
    }

    function _createFundedJob(uint256 amount, address hook) internal returns (uint256 jobId) {
        vm.prank(client);
        jobId = core.createJob(provider, evaluator, _futureExpiry(), "flow job", hook, 0);
        vm.prank(provider);
        core.setBudget(jobId, address(usdc), amount, "");
        vm.prank(client);
        core.fund(jobId, address(usdc), amount, "");
    }

    // ── Auto-terminal: settle (client-only, isolated path) drains → Completed ──────

    function test_flow_SettleClaimToBudgetAutoCompletes() public {
        uint256 jobId = _createFundedJob(TWENTY_USDC, address(0));

        vm.expectEmit(true, true, true, true, address(core));
        emit Settled(jobId, TWENTY_USDC, TWENTY_USDC);
        vm.expectEmit(true, true, true, true, address(core));
        emit ClaimSettled(jobId, client, TWENTY_USDC, TWENTY_USDC, bytes32("final"));
        vm.expectEmit(true, true, true, true, address(core));
        emit JobCompleted(jobId, client, bytes32("settled-in-full"));

        vm.prank(client);
        core.settle(jobId, TWENTY_USDC, bytes32("final"), "");

        assertEq(uint8(core.getJob(jobId).status), uint8(ERC8183.JobStatus.Completed), "auto-completed");
        assertEq(core.getJob(jobId).settledAmount, TWENTY_USDC);
        assertEq(usdc.balanceOf(provider), TWENTY_USDC);
        assertEq(usdc.balanceOf(address(core)), 0);
    }

    function test_flow_PartialSettleStaysFunded() public {
        uint256 jobId = _createFundedJob(TWENTY_USDC, address(0));

        vm.prank(client);
        core.settle(jobId, TEN_USDC, bytes32("milestone"), "");

        assertEq(uint8(core.getJob(jobId).status), uint8(ERC8183.JobStatus.Funded), "still funded; not drained");
        assertEq(core.getJob(jobId).settledAmount, TEN_USDC);
    }

    // ── Final delivery: generic submit(budget) → Submitted → complete ─────────────

    function test_flow_FinalSubmitCompletesViaEvaluator() public {
        uint256 jobId = _createFundedJob(TWENTY_USDC, address(0));

        // Generic submit with cumulativeAmount == budget is the final-delivery path.
        vm.prank(provider);
        core.submit(jobId, TWENTY_USDC, bytes32("deliverable"), "");
        assertEq(uint8(core.getJob(jobId).status), uint8(ERC8183.JobStatus.Submitted), "final submit -> Submitted");

        vm.expectEmit(true, true, true, true, address(core));
        emit JobCompleted(jobId, evaluator, bytes32("ok"));
        vm.prank(evaluator);
        core.release(jobId, TWENTY_USDC, bytes32("ok"), "");

        assertEq(uint8(core.getJob(jobId).status), uint8(ERC8183.JobStatus.Completed));
        assertEq(usdc.balanceOf(provider), TWENTY_USDC);
    }

    // ── Milestone path: generic submit(partial) files an approvable claim ─────────

    function test_flow_MilestoneSubmitStaysFundedThenApprove() public {
        uint256 jobId = _createFundedJob(TWENTY_USDC, address(0));

        vm.prank(provider);
        core.submit(jobId, TEN_USDC, bytes32("milestone"), "");
        assertTrue(core.pendingClaimHash(jobId) != bytes32(0), "partial submit files a pending claim");
        assertEq(uint8(core.getJob(jobId).status), uint8(ERC8183.JobStatus.Funded), "still Funded");

        vm.prank(evaluator);
        core.release(jobId, TEN_USDC, bytes32("milestone"), "");
        assertEq(uint8(core.getJob(jobId).status), uint8(ERC8183.JobStatus.Funded), "partial approve does not terminalize");
        assertEq(core.getJob(jobId).settledAmount, TEN_USDC);
    }

    // ── Drain supersedes an unrelated pending claim ───────────────────────────────

    function test_flow_ClearPendingClaimThenDrain() public {
        uint256 jobId = _createFundedJob(TWENTY_USDC, address(0));

        // Provider has an open milestone claim for 10 ...
        vm.prank(provider);
        core.submit(jobId, TEN_USDC, bytes32("milestone"), "");
        bytes32 claimHash = core.pendingClaimHash(jobId);
        assertTrue(claimHash != bytes32(0), "claim pending");

        // ... the client cannot settle around it: settle reverts while a claim stands.
        vm.expectRevert(ERC8183.PendingClaimExists.selector);
        vm.prank(client);
        core.settle(jobId, TWENTY_USDC, bytes32("final"), "");

        // Clear the claim (claim-scoped reject), then settle the full budget -> Completed.
        vm.prank(client);
        core.reject(jobId, claimHash, bytes32("withdrawn"), "");

        vm.expectEmit(true, true, true, true, address(core));
        emit JobCompleted(jobId, client, bytes32("settled-in-full"));
        vm.prank(client);
        core.settle(jobId, TWENTY_USDC, bytes32("final"), "");

        assertEq(uint8(core.getJob(jobId).status), uint8(ERC8183.JobStatus.Completed));
        assertEq(core.pendingClaimHash(jobId), bytes32(0));
    }

    // ── Hook payload now carries delta ────────────────────────────────────────────

    function test_flow_HookPayloadCarriesDelta() public {
        DeltaRecordingHook hook = new DeltaRecordingHook();
        vm.prank(deployer);
        core.setHookWhitelist(address(hook), true);

        uint256 jobId = _createFundedJob(TWENTY_USDC, address(hook));

        // First settle 10 (delta == cumulative == 10).
        vm.prank(client);
        core.settle(jobId, TEN_USDC, bytes32("m1"), "");
        assertEq(hook.lastCumulative(), TEN_USDC);
        assertEq(hook.lastDelta(), TEN_USDC);

        // Then settle up to 20: cumulative 20, but delta is only the 10 increment.
        vm.prank(client);
        core.settle(jobId, TWENTY_USDC, bytes32("m2"), "");
        assertEq(hook.lastCumulative(), TWENTY_USDC, "cumulative is the running total");
        assertEq(hook.lastDelta(), TEN_USDC, "delta is the per-settlement increment");
    }

    // ── Zero-budget jobs still complete via submit -> release ─────────────────────

    function test_flow_ZeroBudgetCompletesViaRelease() public {
        vm.prank(client);
        uint256 jobId = core.createJob(provider, evaluator, _futureExpiry(), "zero budget", address(0), 0);
        vm.prank(provider);
        core.setBudget(jobId, address(usdc), 0, "");
        vm.prank(client);
        core.fund(jobId, address(usdc), 0, "");

        // Funded with zero escrow: not auto-terminalized (no settlement can fire).
        assertEq(uint8(core.getJob(jobId).status), uint8(ERC8183.JobStatus.Funded));

        vm.prank(provider);
        core.submit(jobId, 0, bytes32("done"), "");
        vm.prank(evaluator);
        core.release(jobId, 0, bytes32("ok"), "");

        assertEq(uint8(core.getJob(jobId).status), uint8(ERC8183.JobStatus.Completed));
    }

    // ── Loophole guard: the evaluator may not originate a payment ─────────────────

    /// @dev The evaluator may resolve a provider assertion via `release`, but must NOT be
    ///      able to drain a bare Funded job to the provider — only the client may settle
    ///      directly (the client funded it). Closes the evaluator-originates-payment hole.
    function test_security_EvaluatorCannotSettleBareFundedJob() public {
        uint256 jobId = _createFundedJob(TWENTY_USDC, address(0));

        vm.expectRevert(ERC8183.Unauthorized.selector);
        vm.prank(evaluator);
        core.settle(jobId, TEN_USDC, bytes32("x"), "");
    }

    /// @dev `release` only resolves a STANDING assertion; with no pending claim (and not
    ///      Submitted) there is nothing to approve, so it reverts — even for the client.
    function test_security_ReleaseRevertsWithNoStandingClaim() public {
        uint256 jobId = _createFundedJob(TWENTY_USDC, address(0));

        vm.expectRevert(ERC8183.NoPendingClaim.selector);
        vm.prank(evaluator);
        core.release(jobId, TEN_USDC, bytes32("x"), "");

        vm.expectRevert(ERC8183.NoPendingClaim.selector);
        vm.prank(client);
        core.release(jobId, TEN_USDC, bytes32("x"), "");
    }
}
