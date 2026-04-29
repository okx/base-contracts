# Partial Settlement Design

## Context

`AgenticCommerce` currently escrows a job budget and releases the full amount on
`complete`, or refunds the full amount on `reject` and `claimRefund`. The
partial settlement flow must let the provider draw client-authorized cumulative
amounts before final completion while preserving escrow accounting.

## Approved Approach

Add voucher-based partial settlement to the existing `Job` model instead of
introducing a separate order model. Each job records a monotonically increasing
`settledAmount`. The provider calls `settle` with a cumulative amount and a
client EIP-712 voucher that binds the job ID, cumulative amount, and `optParams`.

Settlements are allowed only while the job is active (`Funded` or `Submitted`)
and before expiry. Each settlement computes the delta from the previous
settlement, charges platform and evaluator fees on that delta, and pays the net
to the provider.

## Accounting

The escrow invariant is:

```text
remaining escrow = budget - settledAmount
```

`settle` updates `settledAmount` by the cumulative amount released. `complete`
releases only the unsettled remainder with the same fee split. `reject` and
`claimRefund` refund only the unsettled remainder to the client.

## Events And Hooks

`settle` emits a `Settled(jobId, cumulativeAmount, delta)` event and reuses the
existing fee/payment events for actual token transfers. Hooks receive
`abi.encode(msg.sender, delta, optParams)` with `this.settle.selector`.

## Rejected Alternatives

- Requiring `Submitted` before settlement would make the lifecycle stricter but
  would not match the intended active-job settlement flow.
- Closing the job automatically once fully settled would simplify accounting but
  would collapse partial settlement into completion and remove evaluator finality.
