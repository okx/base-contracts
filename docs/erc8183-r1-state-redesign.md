# ERC-8183 — Settlement State-Transition Spec (converged)

**Status:** IMPLEMENTED on this branch (`experiment/collapse-flag-model`). The contract changes
(isolated `settle`, `submit` blocked while a claim pends, `reject(claimHash)` with the front-run
guard, `claimRefund` voids stale claims) are live in `contracts/ERC8183.sol`; the transition
suite is `test/ERC8183R1Transitions.t.sol`. Full suite: 105 passing.
**Builds on:** `experiment/collapse-settlement-flow` (the 8→5 verb collapse). This spec keeps
that collapsed 5-verb surface and specifies how the *pending-claim* sub-state transitions,
who is authorized, and how DoS / front-running is prevented.

> **Supersedes the earlier "promote ClaimPending to a JobStatus" draft.** A five-angle review
> (DoS red-team, state-machine formalism, authorization/trust, prior-art survey, EVM/upgrade
> pragmatics) converged on a different model: keep "a claim is pending" as an **orthogonal flag**,
> not a new enum state. The reasons are recorded in §2.

---

## 1. The 5-verb surface (unchanged)

```
submit · settle · release · reject · claimRefund
```

| Verb | Caller | Role |
|---|---|---|
| `submit(jobId, cumulativeAmount, deliverable, optParams)` | provider | `== budget` → final delivery (Submitted); `< budget` → files a pending milestone claim |
| `settle(jobId, cumulativeAmount, deliverable, optParams)` | client | **isolated** direct payment; pure cursor op (see §4) |
| `release(jobId, cumulativeAmount, deliverable, optParams)` | client \| evaluator | resolve a standing assertion (approve a claim, or complete a Submitted delivery) |
| `reject(jobId, claimHash, reason, optParams)` | scoped (see §5) | `claimHash != 0` cancels that exact claim (job continues); `claimHash == 0` terminates the job |
| `claimRefund(jobId)` | anyone | post-expiry backstop; voids any stale claim + refunds remainder |

---

## 2. State model: orthogonal flag, NOT a new status

`JobStatus` stays at its existing **6** members:

```solidity
enum JobStatus { Open, Funded, Submitted, Completed, Rejected, Expired }   // unchanged
```

"A milestone claim is pending" is carried by the existing `pendingClaimHash[jobId] != 0`
mapping — an **orthogonal boolean dimension riding on `Funded`**, plus the monotonic
`settledAmount` cursor. We deliberately do **not** add a `ClaimPending` enum member.

Why flag, not status (the two decisive findings):

1. **Orthogonality (state-machine formalism).** Once `settle` is isolated (§4), the funding
   phase and the claim bit evolve *independently* — `settle` advances the cursor regardless of
   whether a claim pends. Independent dimensions are an orthogonal region (a *product*), not a
   flattened sibling state. Promoting it to the enum would force `status` and `pendingClaimHash`
   to be kept in sync (a drift-prone biconditional invariant); the flag *is* the only
   representation, so nothing can drift.
2. **Upgrade safety (EVM pragmatics).** This is a live upgradeable proxy whose `Job` struct is
   "append-only" for layout safety. Inserting `ClaimPending` mid-enum renumbers the persisted
   `status` byte of every live job ≥ `Submitted` (corruption); even appending it forces a
   migration of in-flight `Funded + pendingClaimHash` jobs. The flag costs **zero** layout
   change and is already correct on-chain.

The footgun fix and the clean lifecycle do **not** require an enum change — they come from the
`reject` shape (§5) and disciplined events, which sit on top of the existing flag.

### Invariants

```
pendingClaimHash != 0   ⟹  status == Funded            (a claim only pends on Funded)
status == Completed      ⟹  settledAmount == budget      (drained to provider)
status ∈ {Rejected,Expired} ⟹ remainder refunded to client
settledAmount             monotonic (never decreases)    (cross-path double-pay defense)
every exit from Funded clears pendingClaimHash before/at the status change (no claim survives into a terminal state)
```

---

## 3. State diagram

```
                       fund (budget>0)
        ┌──────┐  ───────────────────►  ┌────────────────────────────┐
        │ Open │                         │           Funded           │ ◄──────────┐
        └──┬───┘                         │  (pendingClaimHash = flag) │            │
           │ reject(0) [client|provider] └───┬───────────────┬────────┘            │
           ▼   (no escrow)                   │               │                     │
        ┌────────┐                           │ submit(<bud)  │ submit(=bud)        │ reject(hash)
        │Rejected│ ◄──────────┐              │ [provider]    │ [provider]          │ [prov|client|eval]
        └────────┘            │              │ set flag      │ (must have NO       │ cancel claim
              ▲               │              ▼   no flag→set │  pending claim;     │ → clears flag
   reject(0) [evaluator]      │          Funded[flag]        │  else revert)       │ (job moves on)
   void claim + refund        │              │   ▲           ▼                     │
   ───────────────────────────┘              │   └───────────┐                     │
                                             │   settle/release (resolve)          │
   Funded[flag] ── settle [client] ──► advance cursor; drain→Completed (voids claim); partial overtake LEAVES claim (lazy)
   Funded[flag] ── release(match) [client|eval] ──► approve; clear flag; drain→Completed else →Funded
   Funded[flag] ── reject(hash) [prov|client|eval] ──► clear flag → Funded ───────────┘
   Funded[flag] ── reject(0) [evaluator] ──► void claim + refund → Rejected
   Submitted ── release(=budget) [client|eval] ──► Completed
   Submitted ── reject(0) [evaluator] ──► refund → Rejected
   {Open(b>0),Funded[±flag],Submitted} ── claimRefund (anyone, post-expiry) ──► void any claim + refund → Expired
```

---

## 4. `settle` is isolated (decided)

`settle` is the client's direct-payment fast-path and operates **purely on the monotonic
cursor** — it does **not** read the pending-claim flag and is never gated by it.

- `settle(Y)` pays `delta = Y − settledAmount`, sets `settledAmount = Y`.
- **Drain rule:** if `Y == budget`, the job completes (`→ Completed`) and voids any pending claim
  first (a completed job carries no claim).
- **Overtake (lazy cleanup):** a *partial* settle that passes a claim's amount leaves the claim
  in place. It is now un-approvable (`release` reverts `NoNewSettlement` since
  `claim.cumulative ≤ settledAmount`) and is cleared lazily on the next `reject`/`terminate`/
  `claimRefund`. We deliberately do **not** store the claim amount just to auto-void here —
  keeping `settle` storage-free and fully uncoupled from the claim. A lingering claim blocks only
  the provider's own next `submit` (self-inflicted; they cancel it).

**Safety (why coexistence is sound):** both `settle` and an approved `release` only ever pay
`delta` above the monotonic `settledAmount`, and `release` of a claim requires
`claim.cumulative > settledAmount`. So for any interleaving, total paid `= max(settle target,
claim target)` — no double-payment. This is the branch's existing monotonic-`settledAmount`
defense, unchanged. Isolating `settle` also **eliminates the main DoS vector**: a provider can
no longer hold a pending claim open to block the client from paying down the escrow.

---

## 5. `reject` — one verb, `claimHash` selects intent, status validates

```solidity
reject(uint256 jobId, bytes32 claimHash, bytes32 reason, bytes optParams)
```

### claimHash != 0  → CANCEL that exact claim (non-terminal; job moves on)

```
guard: status == Funded                                   (status check; a claim only pends on Funded)
guard: pendingClaimHash[jobId] == claimHash               (FRONT-RUN GUARD — revert NoPendingClaim on mismatch)
auth : caller ∈ {provider, client, evaluator}             (cancel strands nothing → safe for all three)
effect: delete pendingClaimHash; emit ClaimRejected; status stays Funded
```

The job **moves on**: after the claim is cleared the provider may re-`submit` a corrected claim
or a final delivery, the client may `settle`, etc.

### claimHash == 0  → TERMINATE the job (terminal refund)

```
status == Open                → auth: caller ∈ {client, provider} → Rejected (no escrow locked, no refund)
status ∈ {Funded, Submitted}  → auth: caller == evaluator only     → void any pending claim; refund remainder to client → Rejected
status terminal               → revert WrongStatus                  (status check)
```

### Why this is front-run-safe (the TOCTOU scenario, closed)

Cancel-intent carries a **non-zero** `claimHash`. If the targeted claim is rescinded, approved,
or superseded before the tx lands, `pendingClaimHash != claimHash` → **revert**. A cancel can
therefore *never* silently degrade into a terminate. The **only** way to terminate is to pass
`claimHash == 0` explicitly — termination is an opt-in intent, not a fall-through.

This also removes the DoS wedge: `reject(0)` by the evaluator terminates **regardless** of a
pending claim (it voids the claim on the way out), so a provider cannot re-file fresh-hash claims
to block termination.

### Residual to mitigate in the signing/relayer UX (documented, accepted)

A caller who *means* to cancel but supplies `claimHash == 0` (uninitialized variable / bad
relayer default) issues a terminate. Bounded by the status+auth checks:
- provider/client passing `0` on **Funded** → not authorized to terminate → **reverts** (safe).
- Only the **evaluator**, only on **Funded/Submitted**, can accidentally terminate via a stray
  zero — i.e. a trusted arbiter fat-fingering the sentinel.

Mitigation (not a code change): signers/relayers must **never default `claimHash` to zero** for a
cancel; treat zero as a deliberate "terminate" toggle requiring explicit confirmation. This is the
inherent trade of a single-selector sentinel design, chosen deliberately to preserve the 5-verb
surface.

---

## 6. `claimRefund` — permissionless anti-stale backstop

Post-expiry (Submitted: post-grace), **anyone** may call `claimRefund`. It **voids any pending
claim** and refunds the remainder to the client → `Expired`. It is the one non-hookable exit, so
no reverting `hook` can permanently strand escrow.

Liveness across abandonment (no funds ever permanently stranded):
- **provider abandons** (claim filed, vanishes): client `settle`s around it (isolated) or
  evaluator `release`s/`reject(0)`s; post-expiry anyone `claimRefund`s.
- **client abandons**: evaluator `release`s (pay provider) or `reject(0)`s (refund); post-expiry
  `claimRefund`.
- **evaluator abandons**: client/provider can still cancel a claim and the client can `settle`;
  the remainder is recovered post-expiry by the permissionless `claimRefund`.

A pending claim blocks **nothing a counterparty needs** — only the provider's own next `submit`
(self-inflicted). That is what defeats intentional staling.

---

## 7. Authorization summary

| Action | provider | client | evaluator | anyone |
|---|---|---|---|---|
| `submit` (file claim / deliver) | ✅ | — | — | — |
| `settle` (originate payment) | — | ✅ | — | — |
| `release` (resolve standing assertion) | — | ✅ | ✅ | — |
| `reject(hash)` (cancel a claim) | ✅ | ✅ | ✅ | — |
| `reject(0)` on Open (terminate, no escrow) | ✅ | ✅ | — | — |
| `reject(0)` on Funded/Submitted (terminate + refund) | — | — | ✅ | — |
| `claimRefund` (post-expiry) | ✅ | ✅ | ✅ | ✅ |

Principle: originate = client; resolve = client or evaluator; **reverse/refund = evaluator only**;
cancel-a-claim = anyone party (safe, strands nothing); the permissionless backstop = anyone.

---

## 8. Implementation notes (flag model)

- **No storage-layout change**: `pendingClaimHash` and `settledAmount` already exist; `JobStatus`
  is untouched. No migration of in-flight jobs.
- **Meta-tx (EIP-712):** `reject` keeps a single `RejectAuthorization` typehash now including
  `claimHash`. A signed `reject` is deterministic per (signer, claimHash): a stale-state cancel
  fails closed (hash mismatch); a `claimHash==0` terminate is gated by auth+status at execution.
- **Effects before interactions**: clear the flag / advance `settledAmount` / set terminal status
  *before* any token transfer, disburser callback, or `_afterHook`. The `settle` auto-void deletes
  the flag in the effects block, before payout — no new reentrancy surface.
- **Events**: keep a clean monotonic claim lifecycle — `ClaimSubmitted → (ClaimApproved | ClaimRejected | ClaimSettled)`;
  `settle` overtake and terminal teardown both emit `ClaimRejected` so indexers see the claim close.

---

## 9. Test plan

See `docs/specs/ERC8183R1Transitions.t.sol` — a drop-in Foundry suite encoding the full
`state × verb × caller` matrix against this model, including the **TOCTOU/front-run test**
(a non-zero-`claimHash` cancel against a vanished claim reverts and does NOT terminate) and the
status-validation reverts. It lives under `docs/specs/` (outside the compiled `test/` tree) so
this spec branch stays green; `git mv` it into `test/` as the first step of an implementation.
