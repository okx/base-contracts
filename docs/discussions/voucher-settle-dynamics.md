# Fee Policy for `settle`

## Context

`settle` lets the provider draw client-authorized partial payments while a job remains active. The client signs an EIP-712 voucher for a cumulative gross amount, and the provider calls:

```solidity
settle(jobId, cumulativeAmount, voucherSig, optParams)
```

The current implementation treats `cumulativeAmount` as the gross amount released so far. On each settlement, the contract computes:

```text
delta = cumulativeAmount - settledAmount
```

Then it charges both platform and evaluator fees on `delta`, pays the provider the net amount, and records:

```text
settledAmount = cumulativeAmount
```

This document discusses whether that fee treatment is the right direction.

## Core Question

How should platform and evaluator fees be handled when funds are partially settled before final evaluation?

The answer affects:

- how much the provider can draw before final completion
- whether evaluator compensation is reserved before evaluation happens
- whether `settledAmount` should mean gross released amount or provider-net amount
- how much escrow remains for `complete`, `reject`, and `claimRefund`
- how simple the invariant remains for integrators

## Option 1: Reserve All Fees Upfront

Reserve evaluator and platform fees from the total job budget, then enforce:

```text
provider disbursements <= budget - reservedPlatformFee - reservedEvaluatorFee
```

Partial settlements pay only from the provider-available portion of the budget. Final completion distributes the reserved fees.

Benefits:

- Ensures platform and evaluator fees remain available even if the provider receives all allowed partial payouts.
- Makes final completion fee payment predictable.
- Avoids paying evaluator fees before evaluation work is done.

Tradeoffs:

- More accounting complexity.
- Requires deciding whether reserved fees are based on the original budget or only the ultimately accepted amount.
- If a job is rejected or expires after partial settlement, the handling of reserved fees must be specified.
- Client vouchers may need to authorize provider-net settlement rather than gross settlement.

Open questions:

- Are reserved evaluator fees refunded to the client if the job is rejected or expires?
- Does the platform fee vest as settlements happen, at completion, or only on successful completion?
- Should `settledAmount` track gross settled amount, provider-net amount, or both?

## Option 2: Charge Platform and Evaluator Fees Pro Rata

Charge both platform and evaluator fees on every settlement delta. This is the current implementation.

For each settlement:

```text
platformFee = delta * platformFeeBP / 10000
evaluatorFee = delta * evaluatorFeeBP / 10000
providerNet = delta - platformFee - evaluatorFee
```

Benefits:

- Simple accounting invariant: `remaining escrow = budget - settledAmount`.
- Fees are collected in proportion to actual released value.
- Full settlement and final completion use the same fee split.
- No separate reserved-fee accounting is needed.

Tradeoffs:

- Evaluator can be paid before final evaluation.
- If the evaluator later rejects the job, previous evaluator fees have already been paid.
- The meaning of evaluator fee shifts from "paid for final approval" to "paid for ongoing evaluation availability or protocol participation."

Open questions:

- Is it acceptable for evaluator fees to vest before final evaluation?
- Should the evaluator have any duty before completion if they are paid during partial settlement?
- Should the UI explain that settlement fees are charged immediately?

## Option 3: Charge Platform Fee Pro Rata, Defer Evaluator Fee

Charge the platform fee on each settlement delta, but reserve or defer the evaluator fee until final completion.

Rationale:

- The platform may provide infrastructure continuously.
- The evaluator may not have performed final evaluation work at partial settlement time.

Benefits:

- Platform fees track actual payment activity.
- Evaluator is paid closer to the point where evaluator work happens.
- Provider receives more liquidity during partial settlement than in Option 2.

Tradeoffs:

- Requires separate evaluator-fee accounting or reservation.
- Final completion becomes more complex because it must account for already-settled gross amounts and deferred evaluator fees.
- Rejection/expiry behavior must decide whether deferred evaluator fees are paid, refunded, or skipped.

Open questions:

- Is the evaluator fee calculated on total budget, accepted amount, or unsettled remainder?
- If the provider receives most of the budget through settlements, where does the final evaluator fee come from?
- Should settlement vouchers cap provider draws to preserve evaluator-fee escrow?

## Other Possible Directions

The three options above are not exhaustive. Other variants include:

- no fees on partial settlement; all fees charged only on final completion
- platform fee on partial settlement, evaluator fee only if the evaluator explicitly signs or attests each settlement
- configurable fee mode per deployment
- configurable fee mode per job

## Current Leaning

The current implementation follows Option 2 because it keeps the core invariant simple:

```text
remaining escrow = budget - settledAmount
```

If evaluator fees should only be paid after evaluation, Option 3 is a better semantic fit, but it needs more explicit accounting rules.

If the priority is guaranteeing all fee pools before provider payouts, Option 1 is the strictest model, but it also makes settlement vouchers and refund behavior more complex.
