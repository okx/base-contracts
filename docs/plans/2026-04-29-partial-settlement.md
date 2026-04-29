# Partial Settlement Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add voucher-authorized partial settlement to `AgenticCommerce` with platform and evaluator fees charged on each settlement delta.

**Architecture:** Extend the existing `Job` escrow model with `settledAmount` and a `settle` entrypoint. Settlement verifies an EIP-712 client voucher, releases only the new delta, and reuses the existing fee split. Final completion and refund paths operate only on unsettled escrow.

**Tech Stack:** Solidity 0.8.28, Hardhat, Ethers v6, OpenZeppelin `EIP712`, `SignatureChecker`, and `SafeERC20`.

---

### Task 1: Settlement Tests

**Files:**
- Modify: `test/AgenticCommerce.test.js`

**Step 1: Write the failing tests**

Add tests that:

- Fund a job, sign a voucher for a cumulative amount, call `settle`, and assert platform/evaluator/provider balances.
- Call `settle` twice with increasing cumulative amounts and assert only the delta is paid on the second call.
- Assert stale cumulative amounts revert.
- Assert invalid signatures revert.
- Assert `complete`, `reject`, and `claimRefund` only touch the unsettled remainder.

**Step 2: Run tests to verify failure**

Run: `npm test`

Expected: compile failure or test failure because the contract references unmapped order fields and lacks final accounting.

### Task 2: Contract Mapping

**Files:**
- Modify: `contracts/AgenticCommerce.sol`

**Step 1: Add state and errors/events**

Add `settledAmount` to `Job`, initialize it to zero in `createJob`, and add settlement-specific errors/events needed by tests:

```solidity
error NoNewSettlement();
error ExceedsBudget();
event Settled(uint256 indexed jobId, uint256 cumulativeAmount, uint256 delta);
```

**Step 2: Fix voucher shape**

Use `uint256 jobId` in the voucher type:

```solidity
keccak256("Voucher(uint256 jobId,uint256 cumulativeAmount,bytes optParams)")
```

**Step 3: Implement `settle`**

Map the pasted order-settlement intent to jobs:

```solidity
function settle(
    uint256 jobId,
    uint256 cumulativeAmount,
    bytes calldata voucherSig,
    bytes calldata optParams
) external nonReentrant
```

Require:

- Valid job ID.
- Caller is provider.
- Status is `Funded` or `Submitted`.
- Current timestamp is before `expiredAt`.
- `settledAmount < cumulativeAmount <= budget`.
- Voucher is signed by client.

Then:

- Compute `delta`.
- Call before hook.
- Update `settledAmount`.
- Pay fees and provider net on `delta`.
- Emit `Settled`.
- Call after hook.

### Task 3: Shared Payout Accounting

**Files:**
- Modify: `contracts/AgenticCommerce.sol`

**Step 1: Extract a payout helper**

Create `_releasePayment(Job storage job, uint256 jobId, uint256 amount)` that charges fees on `amount`, emits fee events, transfers provider net, and emits `PaymentReleased`.

**Step 2: Update finalizers**

Use `job.budget - job.settledAmount` in:

- `complete`
- `reject`
- `claimRefund`

### Task 4: Verification

**Files:**
- Modify: `contracts/AgenticCommerce.sol`
- Modify: `test/AgenticCommerce.test.js`

**Step 1: Run all tests**

Run: `npm test`

Expected: all tests pass.

**Step 2: Review diff**

Run: `git diff -- contracts/AgenticCommerce.sol test/AgenticCommerce.test.js docs/plans/2026-04-29-partial-settlement-design.md docs/plans/2026-04-29-partial-settlement.md`

Expected: only intended partial settlement, accounting, test, and docs changes are present.
