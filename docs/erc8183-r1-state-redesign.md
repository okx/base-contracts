# ERC-8183 R1 — State-Machine Redesign (spec)

**Status:** design proposal, not implemented. This branch carries the spec and a drop-in
transition test plan only.
**Builds on:** `experiment/collapse-settlement-flow` (the 8→5 verb collapse). R1 keeps that
collapsed surface but attacks the problem from the *state* side instead of the *verb* side.

---

## 1. Why touch the state machine at all

The verb collapse merged the public functions but left the **lifecycle spread across three
overlapping representations**:

| Dimension | Encoded in | Distinct values |
|---|---|---|
| Lifecycle phase | `JobStatus` enum | 6 (`Open, Funded, Submitted, Completed, Rejected, Expired`) |
| "Is a milestone claim pending?" | `pendingClaimHash[jobId] != 0` | 2 — **implicit**, not a named state |
| Economic progress | `settledAmount` vs `budget` | `0` / partial / drained |

The state the contract actually operates on is the **product** of these, yet only the first is
a named, enumerable state. Every rough edge in the collapsed branch traces back to that gap:

| Rough edge (in `experiment/collapse-settlement-flow`) | Root cause |
|---|---|
| `release` is "state-dispatched" (complete vs approve) | it must read `status × pendingClaimHash` to know its own effect |
| `reject(jobId, claimHash, …)` overload — `claimHash == 0` silently means "terminate the whole job" | "cancel the claim" vs "terminate the job" is a distinction the **state** doesn't carry, so it's pushed into a calldata sentinel |
| `_terminalizeOnDrain` projection + the old "paid-but-open" zombie | terminal status is **assigned**, not **derived** from the cursor |
| `PendingClaimExists` re-checked in `submit` / `settle` / `reject` / `claimRefund` | four functions independently re-derive the same implicit "a claim is pending" sub-state |
| `claimRefund`'s 3-way branch (`Submitted` / `hasPendingClaim` / else) | same implicit sub-state, re-derived again |

**R1's thesis:** promote the implicit "a claim is pending" sub-state into a first-class
`JobStatus`. Once the state machine carries the distinction, the dispatch ambiguity and the
`reject` footgun stop being things you *guard against* and become things that are *structurally
impossible* (invalid transitions).

> R1 is the smallest state change that removes the footgun. The more ambitious normalization
> (model the assertion as a tagged union and *derive* terminal status from the cursor) is
> sketched in §7 as R2; it is out of scope for this spec.

---

## 2. The new state set

```solidity
enum JobStatus {
    Open,          // created, budget may be 0, not yet funded
    Funded,        // escrow locked, no standing assertion
    ClaimPending,  // NEW — a milestone claim is filed and awaiting release/cancel
    Submitted,     // final delivery asserted; awaiting terminal release/reject
    Completed,     // terminal: escrow fully released to provider
    Rejected,      // terminal: job terminated by arbiter, remainder refunded
    Expired        // terminal: job timed out, remainder refunded
}
```

One state added: **`ClaimPending`**. It is exactly the old `Funded && pendingClaimHash != 0`
condition, lifted out of the side mapping and into the enum. `pendingClaimHash` is still stored
(we need the hash to match an approval against the exact claim), but it is **no longer the thing
branched on** — `status` is. The mapping becomes pure data, not control flow.

### Invariant tying state to the ledger

```
status ∈ {Funded, ClaimPending, Submitted}  ⟹  settledAmount < budget   (escrow still has funds)
status == Completed                          ⟹  settledAmount == budget   (drained to provider)
status ∈ {Rejected, Expired}                 ⟹  remainder (budget-settledAmount) refunded to client
pendingClaimHash != 0                         ⟺  status == ClaimPending     (biconditional — the key win)
```

The last line is the point: the side mapping and the status can never disagree, because they
are now two views of one fact.

---

## 3. State diagram

```
                          fund
        ┌────────┐  (budget>0)   ┌──────────┐
        │  Open  │ ────────────► │  Funded  │ ◄───────────────┐
        └───┬────┘               └────┬─────┘                 │
            │                         │                       │ release(approve)  /
            │ reject (client|provider)│                       │ reject(cancel)    → back to Funded
            │ — Open-scope, no escrow │                       │ (when claim does NOT drain)
            ▼                         │                       │
        ┌────────┐                   │ submit(partial)        │
        │Rejected│◄──┐               ├──────────────────► ┌───┴────────┐
        └────────┘   │               │                    │ClaimPending│
                     │ reject (job)  │                    └───┬────────┘
                     │ EVALUATOR     │ submit(full,         │
                     │               │   supersedes any     │ release(approve) → drains → Completed
        ┌──────────┐ │   pending claim)                     │ reject(cancel)   → Funded
        │ Submitted│─┘               │                      │ terminate (EVALUATOR) → Rejected
        └────┬─────┘                 ▼
             │            ┌──────────────┐
   release   │            │   Completed  │  ◄── settle (CLIENT) drains, from Funded
 (EVALUATOR| │            └──────────────┘      release drains, from ClaimPending/Submitted
  CLIENT)    │
   → Completed
             │
             └── terminate (EVALUATOR) → Rejected
                 claimRefund (anyone, post-grace) → Expired

   Any of {Open(budget>0), Funded, ClaimPending, Submitted} ── claimRefund (post-expiry) ──► Expired
```

### What changed vs the collapsed branch

1. **`ClaimPending` is reachable only from `Funded` via `submit(partial)`**, and returns to
   `Funded` on a non-draining `release`/`reject`, or advances to `Completed` on a draining
   `release`.
2. **`settle` is no longer a legal transition from `ClaimPending`.** "No pay-around a standing
   claim" is now enforced by the *absence of a transition*, not by a `PendingClaimExists` revert
   inside `settle`.
3. **`reject` splits by intent (see §4):** a non-terminal **cancel** (only meaningful in
   `ClaimPending`) and a terminal **`terminate`** (evaluator, from `Funded`/`ClaimPending`/
   `Submitted`). The `claimHash` calldata sentinel is gone.

---

## 4. The verb surface under R1

R1 keeps the collapsed verbs but **replaces the overloaded `reject` with two intent-named
selectors**, because the residual ambiguity ("cancel the claim" vs "terminate the job while a
claim pends") is the one distinction the state machine alone cannot carry — both are reachable
from `ClaimPending`.

| Verb | Caller | Legal from | Effect |
|---|---|---|---|
| `submit(jobId, cumulativeAmount, deliverable, params)` | provider | `Open`(budget 0) / `Funded` | `== budget` → `Submitted`; `< budget` → `ClaimPending` |
| `settle(jobId, cumulativeAmount, deliverable, params)` | **client** | `Funded` | advance cursor; drain → `Completed` (else stays `Funded`) |
| `release(jobId, cumulativeAmount, deliverable, params)` | client \| evaluator | `ClaimPending` / `Submitted` | resolve the standing assertion; drain → `Completed`, else (`ClaimPending` partial) → `Funded` |
| `cancelClaim(jobId, reason, params)` | client \| evaluator \| provider | `ClaimPending` | cancel the pending claim → `Funded` (no `claimHash` arg — there is exactly one pending claim) |
| `terminate(jobId, reason, params)` | Open: client\|provider · Funded/ClaimPending/Submitted: **evaluator** | `Open` / `Funded` / `ClaimPending` / `Submitted` | terminal refund of remainder → `Rejected` |
| `claimRefund(jobId)` | anyone | post-expiry (Submitted post-grace) | refund remainder → `Expired` |

Net surface: **6 verbs** (`submit, settle, release, cancelClaim, terminate, claimRefund`) — one
more than the branch's 5, but the extra selector *buys* the elimination of the footgun, removes
`release`'s magic-combination dispatch, and lets every `PendingClaimExists` guard disappear.

### Why `cancelClaim` needs no `claimHash`

There is **at most one** pending claim per job (the old `pendingClaimHash` is a single slot, and
`submit(partial)` reverts if one already exists). In `ClaimPending` there is therefore exactly
one thing to cancel. The argument that made the branch's `reject` dangerous — a hash that
defaults to zero and silently re-targets the whole job — has no reason to exist here.

---

## 5. The footgun, gone

Branch behaviour:

```solidity
reject(jobId, bytes32(0), reason, "");   // caller MEANT "cancel my claim"
                                          // ACTUALLY terminates the job + refunds the client
```

R1 behaviour:

```solidity
cancelClaim(jobId, reason, "");   // cancels the claim. Reverts (WrongStatus) if not ClaimPending.
terminate(jobId, reason, "");     // terminates the job. Distinct selector, distinct authz.
```

The two money-different outcomes are now **two selectors** that cannot be confused by a defaulted
argument. A relayer signing the wrong intent fails closed (wrong selector → wrong typehash →
signature won't verify; or wrong state → `WrongStatus` revert), instead of silently nuking the
job.

---

## 6. Storage layout & upgrade safety

This contract is `Initializable` / upgradeable, and the `Job` struct comments explicitly say
"new fields appended to preserve storage layout." R1 must respect that.

- **`JobStatus` is a `uint8`-backed enum stored in `Job.status`.** Adding `ClaimPending` *in the
  middle* of the enum (between `Funded` and `Submitted`) **renumbers** `Submitted`/`Completed`/
  `Rejected`/`Expired`. For a fresh deployment that is fine. For an **upgrade over live jobs it is
  not** — every persisted `status` value ≥ old `Submitted` would shift meaning.
  - **Safe option (recommended): append `ClaimPending` at the end of the enum** (value `6`) and
    *do not* rely on enum ordering for logic. Logic keys off named variants, so position is
    irrelevant to correctness; only the human-facing diagram groups it logically.
  - If a clean redeploy (no live jobs to migrate) is on the table, the in-order form in §2 reads
    better and is acceptable.
- **No new storage slots required.** `ClaimPending` reuses the existing `status` byte;
  `pendingClaimHash` already exists. R1 *removes* control-flow dependence on the mapping but keeps
  the slot, so layout is unchanged.
- **A migration that touches existing jobs is unnecessary** if `ClaimPending` is appended: any job
  that was `Funded` with a non-zero `pendingClaimHash` under the old contract is read under R1 by
  the biconditional in §2 — code paths should treat `Funded + pendingClaimHash != 0` as
  `ClaimPending` during a transition window, or a one-time normalization pass can flip those jobs'
  status. This is the one real migration question and must be decided before implementation.

---

## 7. Out of scope: R2 (recorded for completeness)

A more aggressive normalization, **not** specified here:

- Replace `JobStatus` with an orthogonal `Phase {Draft, Active, Closed}` plus an explicit
  `Assertion {kind: None|Milestone|Final, hash}` sub-struct.
- **Derive** the terminal outcome from the cursor instead of storing `Completed`/`Rejected`:
  `settledAmount == budget` ⇒ paid out; closed with `settledAmount < budget` ⇒ refunded. This
  deletes `_terminalizeOnDrain` entirely and makes the "paid-but-open" zombie unrepresentable.
- Collapse `Rejected` + `Expired` (same economic outcome — terminated, remainder refunded;
  different trigger) into one terminal state carrying a `trigger`/`reason`.

R2 is the larger storage-layout change and is best considered only if R1's interface is going to
the standards body anyway.

---

## 8. Test plan

See `docs/specs/ERC8183R1Transitions.t.sol` — a drop-in Foundry suite that encodes the full
transition matrix (every `state × verb × caller` → outcome or revert), written against the
**proposed** R1 ABI. It lives under `docs/specs/` (outside the compiled `test/` tree) so this
spec branch stays green; moving it to `test/` is the first step of an R1 implementation. The
matrix it encodes is reproduced as a table at the top of that file.
