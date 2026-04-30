# Singleton + Neutral Base Design

## Context

`AgenticCommerce` today is a deployable platform: an admin role controls
platform fee, evaluator fee, treasury address, and a hook whitelist. Every
deployment ships its own opinions, which fragments the standard — integrators
with different fee preferences fork the contract.

This proposal turns ERC-8183 into a **credibly-neutral singleton**: one
canonical deployment per chain, with all fee and policy concerns pushed into
wrappers. The singleton becomes pure rails (state machine + escrow + payout);
platforms differentiate above the line.

## Design Decisions

| # | Decision | Choice |
|---|---|---|
| 1 | Singleton flavor | **Composable / multi-tenant.** One canonical contract; admin scope = upgrade authorization only. |
| 2 | Where fees live | **Out of core.** Singleton has no fee math. Settlement transfers to a `disburser` address that handles routing. |
| 3 | Disburser timing | **Default-to-provider, mutable until `fund`.** Zero-platform jobs work unchanged; platform jobs override. |
| 4 | Hook system | **Keep, drop the whitelist.** Per-job opt-in; counterparties self-protect by inspecting the hook before engaging. |

## Value Proposition

| Lever | Effect |
|---|---|
| Schelling-point address | One canonical contract per chain — like ENS, Seaport, Permit2. Apps integrate without choosing between forks. |
| Credible neutrality | No party can change fees, freeze hooks, or seize escrow. Upgrade is the only admin lever, scopable to multisig → timelock → renounce. |
| Clear extension seam | "Add a fee?" → set a disburser. "Add logic?" → wrap or hook. Two idioms, zero permissions. |
| Audit-once-forever | One canonical bytecode covers every integration. |
| Composability | Disburser can be 0xSplits, LlamaPay, a Safe, ERC-8004 splitter — inherits primitives for free. |

The cost: the canonical contract earns no fees. That's the feature — it's why
builders can trust it.

## Data Model Changes

```diff
 struct Job {
     ... existing fields ...
+    address disburser;        // 0 → resolves to provider at fund
 }

- uint256 platformFeeBP;
- address platformTreasury;
- uint256 evaluatorFeeBP;
- mapping(address => bool) whitelistedHooks;
- bytes32 ADMIN_ROLE;
```

`DEFAULT_ADMIN_ROLE` retained — scoped exclusively to `_authorizeUpgrade`.

## Function Signature Changes

| Function | Change |
|---|---|
| `createJob` | Add `address disburser` parameter |
| `setDisburser(jobId, disburser)` | New — client-only, Open-only |
| `fund` | Resolves `disburser = provider` if unset; disburser locks here |
| `complete` | Single transfer to `job.disburser` (was three: provider / treasury / evaluator) |
| `settle` | Same collapse — delta transfers to `job.disburser` |
| `reject` / `claimRefund` | Unchanged — refunds always to `job.client` |
| `setPlatformFee` / `setEvaluatorFee` / `setHookWhitelist` | Removed |
| Hook attachment | No whitelist check; ERC-165 interface check retained |

## Boundary of Enforcement

The singleton enforces only **universal invariants** — rules that protect every
job regardless of use case:

- `provider != evaluator` (only address-level collusion check possible)
- `evaluator != address(0)` (required for finality)
- `expiredAt >= now + 5 min`
- Per-transition authorization (client / provider / evaluator)
- Conservation: `Σ payouts ≤ budget`
- `claimRefund` always available after expiry, non-hookable
- ERC-165 hook-shape check

It deliberately does **not** enforce pattern-specific rules (e.g.
`client == evaluator`, `disburser != evaluator`) — those would break legitimate
non-platform use cases. Wrappers enforce their own invariants in their own
code.

## Wrapper Enforcement Model

Wrappers gain three orthogonal levers to enforce policy without singleton
modification:

1. **Role occupation** — be `client` / `evaluator` / `disburser` to gate
   role-auth'd functions.
2. **Hook attachment** — set wrapper as `job.hook`; revert in `beforeAction` to
   veto transitions called directly on the singleton.
3. **ERC-1271 voucher signing** — wrapper-as-contract-client signs `settle`
   vouchers; provider can't pull settlements without the wrapper's blessing.

Stacking all three covers every transition except `claimRefund` after
expiry — by design unblockable, the universal escrow safety hatch.

### Three rules every wrapper must follow

1. **Occupy the roles whose authorization you need to control.**
2. **Attach yourself as `hook`** if any role you don't occupy can call the
   singleton directly (typically `provider`'s `submit`).
3. **Maintain your own job registry; reject callbacks for unknown jobs** —
   anyone can list your contract as a role on a job they create; without a
   registry your wrapper is puppetable.

### What wrappers cannot block — and why that's correct

| Cannot block | Why it must remain unblockable |
|---|---|
| `claimRefund` after expiry | Universal escrow safety. Wrappers blocking refunds would defeat the singleton's neutrality. |
| Client `reject` while Open | Pre-fund cancellation is the client's unilateral right. No escrow at risk. |
| Upgrade by `DEFAULT_ADMIN_ROLE` | Protocol-level concern; mitigated by transferring to multisig → timelock → renounce. |

These exceptions preserve the singleton's role: **wrappers control policy,
singleton controls custody**. A bad wrapper can grief its own users but can
never trap funds.

## Worked Example: OptimisticOrchestrator (OO)

Maps directly onto this design — OO is `client + evaluator + hook` for its own
jobs, sets `disburser` to its split contract, and runs an optimistic-window
state machine entirely off the singleton. The two protocol-level asks from the
HackMD proposal (partial settlement, per-job receiver) become core primitives
here: `settle` already shipped, `disburser` is this design.

## Migration

| Option | Description |
|---|---|
| **A** | Amend ERC-8183 in place (still Draft). Single canonical spec; current draft integrators must re-integrate. |
| **B** | Ship as ERC-8183 v2 — separate EIP superseding v1. |

Recommend **A**. The EIP is still Draft (mutable by design), and splitting
causes the fragmentation we're trying to avoid.

Deployed contract: deploy fresh as the canonical singleton. Existing
deployments are pre-mainnet; storage migration not worth the complexity.

## Testing

- Re-run all current tests with `disburser == provider` — observable behavior
  must match today's no-fee path
- New tests: `disburser != provider` paths (split contract, EOA, wrapper)
- Negative tests: `setDisburser` rejected after fund, address(0) resolution at
  fund time
- Integration test: mock OptimisticOrchestrator end-to-end
- Hook tests: drop whitelist branches; add "any-hook-attaches" cases

## Open Questions

1. **Disburser revert-on-receive** locks escrow until expiry. Recommend no
   fallback — accept as opt-in client risk.
2. **Upgrade authority concentration.** Initial deploy with multisig; document
   path to timelock → DAO → eventual renounce.
3. **No on-chain platform discovery primitive.** Indexers attribute revenue by
   disburser address; a registry is out of scope for the core.

## Next Step

Once aligned, break implementation into a sub-task plan via the
writing-plans skill.
