# Collapsing the ERC-8183 Settlement Surface — Feasibility & Trade-off Evaluation

**Status:** prototype complete, evaluation memo for external review
**Question posed:** *Is it possible to merge the job-lifecycle settlement functions into a smaller, unified surface without losing the protocol's security and liveness guarantees?*
**Answer up front:** **Yes.** We built a working prototype that reduces the settlement/terminal surface from **8 functions to 5**, keeps every existing happy-path behaviour, and is covered by a green test suite (82 tests, including adversarial security tests). The merge is sound, but it carries a small set of deliberate, bounded trade-offs and is an *interface-level* change to the standard — not a silent refactor. This memo explains the approach we took and the trade-offs to weigh.

---

## 1. Background: what the surface looks like today

ERC-8183 models a **job escrow**. A client funds a budget; a provider delivers; a neutral **evaluator** arbitrates. Funds in escrow flow to the provider as work is accepted, and any unaccepted remainder eventually returns to the client.

Today that lifecycle is driven by **eight** functions, in three rough groups:

| Group | Function | Who | Purpose |
|---|---|---|---|
| Provider asserts | `submit` | provider | declare final delivery → job awaits evaluation |
| | `submitClaim` | provider | file a partial **milestone claim** for part of the budget |
| Pay toward provider | `complete` | evaluator | release the full remaining escrow; finish the job |
| | `settleClaim` | client | unilaterally pay the provider a (partial or full) amount |
| | `approveClaim` | client/evaluator | approve a provider's pending milestone claim |
| Reverse / cancel | `reject` | evaluator (or client/provider pre-fund) | terminate the job, refund remainder to client |
| | `rejectClaim` | any party | cancel a pending milestone claim (job continues) |
| Expiry | `claimRefund` | anyone | after expiry, refund the unsettled remainder |

This works, but several of these functions are **near-duplicates that differ only in who calls them or whether a prior claim exists**. The motivation for the merge is a smaller, more auditable surface and a single, consistent settlement model.

---

## 2. The organizing principle we used

Rather than merge functions opportunistically, we anchored everything on one mental model that makes the right merges obvious and the wrong ones impossible.

**The escrow is a one-way cursor on `[0, budget]`.**

```
   0 ───────────────●──────────────── budget
   client's       settledAmount        provider's
   refund floor    (only moves right)    full payment
```

- `settledAmount` is **monotonic** — it only advances toward the provider. (This is already the protocol's defense against double-payment.)
- **Completion** = the cursor reaches `budget`. The escrow is empty; the job is economically closed.
- **Rejection / refund** = *freeze* the cursor and return everything to its right to the client. This is **not** a cursor move — it is a *termination*.

From this, three rules fall out that drove the whole design:

1. **Status should follow the ledger.** If a settlement empties the escrow, the job *is* complete — the contract should say so automatically, rather than leaving a "fully paid but still open" zombie state that the old design could reach.
2. **Merge only where a true degenerate identity exists.** "Complete the job" is literally "approve a settlement for the full remaining amount." That identity lets them merge. By contrast, "reject the job" (refund everything) and "cancel one claim" (touch nothing) move the cursor in *opposite ways* — there is no identity, so they must stay distinguishable.
3. **The cursor has no reverse gear.** Paying the provider is *settlement* (incremental, many entry points). Returning to the client is *termination* (all-or-the-rest, one arbiter decision). This asymmetry is why there is no mirror "refund-claim/approve-refund" machinery — and it is a feature, not a gap.

---

## 3. The resulting surface: 5 verbs

The prototype collapses the eight functions into **five**, each a distinct *intent*:

| Verb | Who may call | What it does |
|---|---|---|
| **`submit`** | provider | Files a claim. A **partial** amount parks a pending milestone claim (job stays Funded). The **full** budget routes the job into a *Submitted* state for terminal evaluation. (Absorbs `submitClaim`.) |
| **`settle`** | **client only** | Direct fast-path payment to the provider with no prior provider assertion. Draining the escrow completes the job. (Was `settleClaim`.) |
| **`release`** | client **or** evaluator | Resolves a *standing provider assertion* — completes a Submitted delivery, **or** approves a pending milestone claim (must match it exactly). Draining the escrow completes the job. (Absorbs `complete` + `approveClaim`.) |
| **`reject`** | scoped (see below) | One selector, two scopes: with a **claim identifier**, cancels that one pending claim (job continues); with no identifier, terminates the job and refunds the remainder. (Absorbs `rejectClaim`.) |
| **`claimRefund`** | anyone | Unchanged. Post-expiry refund of the unsettled remainder. |

Internally, `settle` and `release` share one settlement engine and one "did this drain the escrow? → complete" projection, so there is a single code path for advancing the ledger regardless of entry point.

### The trust boundary (the security-critical part)

The single most important property is **who may move the cursor, and in which direction**:

```
                    ┌──────── pay toward PROVIDER ────────┐   ┌─ reverse to CLIENT ─┐
   originate a payment (no assertion)   ──►  settle        │   │   reject (job)      │
                                              CLIENT only  │   │   EVALUATOR only    │
   resolve a provider assertion        ──►  release        │   └─────────────────────┘
   (complete a delivery / approve a claim)   client|evaluator
```

- **Only the client may *originate* a payment** (`settle`) — it is the client's escrow; voluntarily over-paying harms no one but the client.
- **Client or evaluator may *resolve* a standing provider assertion** (`release`) — there must already be a delivery or a filed claim to act on.
- **Only the evaluator may *reverse*** (`reject` the job, refunding the client) — the one direction that must never be unilateral for the paying party.

This boundary is what makes the escrow trustworthy: a provider is guaranteed payment recourse (the evaluator can force release), and a client cannot claw back after work is done. The prototype enforces this **at the selector level** — `settle` is client-gated, and `release` reverts if there is no standing assertion — so the evaluator can *never originate* a payment on a bare funded job.

---

## 4. How we approached the build

We worked on an isolated branch off the current meta-transactions/claims line and proceeded in **small, individually-verified stages**, running the full test suite after each so behaviour changes were always visible:

1. **Auto-terminalize on drain.** Made any settlement that empties the escrow move the job to *Completed*, and enriched the extension-hook payload with the per-settlement amount. (Removes the zombie "paid-but-open" state.)
2. **Unify the terminal release.** Recognized completion and rejection as mirror operations (release the remainder in opposite directions) and routed them through one internal engine.
3. **Generalize the provider entry.** Made a single `submit` handle both milestone claims and final delivery, routing on whether the asserted amount equals the budget.
4. **Unify the counterparty entry.** Merged `complete` + `approveClaim` + `settleClaim` into one `release`, and `reject` + `rejectClaim` into one scoped `reject`.
5. **Re-separate `settle` for the trust boundary.** Step 4 accidentally let the evaluator originate payments; we peeled `settle` back out as a client-only verb to close that hole, and added explicit adversarial tests to lock it.

**Verification:** the suite ends at **82 tests, 0 failures**, including two security tests asserting that the evaluator cannot originate a payment and that `release` refuses to act without a standing assertion. The happy-path flows (fund → deliver → complete; milestone claims; refunds; expiry) are behaviourally unchanged; the deliberate changes are enumerated below.

Liveness was preserved without touching the refund logic: because final delivery still routes through the *Submitted* state, the existing post-expiry grace-and-refund guarantee (escrow can never be stranded) carries over unchanged.

---

## 5. Trade-offs

### What you gain

- **Smaller, more auditable surface** — 8 functions → 5, fewer selectors and signed-message types to review, one internal settlement path instead of three.
- **Status tracks economic reality** — no "fully paid but still Open" state; indexers and downstream reputation systems see a job close exactly when its escrow empties.
- **Sharper, explicit role boundaries** — originate (client) / resolve (either) / reverse (evaluator) is stated at the selector level rather than implied across several functions.
- **A cleaner conceptual model** — the cursor invariant is one sentence and makes the whole machine reviewable.

### What you give up (deliberate semantic changes)

These are the items external partners should weigh most carefully:

1. **No "paying around" a standing claim.** Once a provider has a pending milestone claim, the counterparty must either honour it (`release`) or cancel it (`reject` with the claim id) before making an unrelated direct payment. This serializes claim handling — clean for sequential milestones, but it removes flexibility for **overlapping or streaming claims**.
   > **⚠️ Superseded on this branch (`experiment/collapse-flag-model`).** This trade-off describes the original collapse design. The flag-model implemented here makes `settle` **isolated** — it is *not* blocked by a pending claim (the monotonic `settledAmount` cursor is the double-pay defense). See `docs/erc8183-r1-state-redesign.md` §4 for the authoritative behavior; this memo otherwise still reflects the original 8→5 collapse.
2. **A Submitted job can now be completed by the client paying in full**, not only by the evaluator. (The evaluator retains the exclusive power that actually matters: reversing/refunding.) This relaxes the previous "only the evaluator marks a job complete" wording into "anyone who pays in full completes it; only the evaluator may reject it." Economically the client could already pay out fully, so no new spending power is granted — but it is an observable change to the standard's stated guarantee.
3. **`reject` is scoped by a calldata argument** (claim id present → cancel one claim; absent → terminate job). This is one selector doing two things. We mitigated the ambiguity by deriving behaviour from an explicit identifier rather than a boolean flag, but a missing argument escalates "cancel a milestone" into "refund the whole job." A separate function is a stronger guardrail for an irreversible, money-moving operation; we judged the scoped form acceptable, but it is a real footgun to document for integrators.
4. **`release` is state-dispatched** — one verb whose effect (complete vs approve) depends on job state. Intent stays legible because dispatch is on *contract state*, never on a caller-supplied mode, but reviewers must understand the state machine to read a `release` call.

### Costs and risks of adopting it

- **It is an interface change, not an internal refactor.** Function selectors and the signed-authorization (meta-transaction) message types change. Every integrator — wallets, relayers, indexers, off-chain signers — must migrate. This is the dominant cost.
- **Standards process.** Because ERC-8183 is a shared specification, the three semantic changes above (client-can-complete, no-pay-around-pending, the enriched hook payload) are proposals to the standard, to be discussed with the broader community — not changes a single implementer can make unilaterally.
- **Audit re-scope.** The settlement core is rewritten; prior audit coverage of the individual functions does not transfer. A fresh review of the unified engine and the trust boundary is required.

### What is *not* compromised (invariants preserved)

- **No fund stranding** — the post-expiry grace/refund guarantee is intact (final delivery still uses the Submitted state).
- **The client↔evaluator trust boundary** — enforced at the selector level and test-locked.
- **Monotonic `settledAmount`** — the cross-path double-payment defense is unchanged.
- **Zero-budget / attestation-only jobs** — still supported, handled naturally by the full-amount path.

---

## 6. Downstream integration impact (how the merge affects other contracts)

A downstream contract connects to the escrow in two directions, and the merge affects them very differently.

**1. Functions the downstream *calls* (e.g. it calls `settleClaim`, `complete`).**
The merge renames/reshapes these (`settleClaim` → `settle`, `complete` → `release`, `reject` gains a scope argument). So those call sites must be updated. The upside: this breaks **loudly** — the downstream won't compile until it's fixed — so the work is easy to find and mechanical to apply.

**2. Callbacks the escrow makes *into* the downstream (extension hooks, the payout callback).**
These only break if the downstream was inspecting **which function fired**. Most aren't:
- a payout callback typically just moves the received funds and ignores which function triggered it;
- an extension hook typically watches only a couple of *stable* lifecycle points (e.g. submission and expiry refund) — which the merge does **not** rename.

So in the common case, callbacks keep working unchanged.

**The one case to audit:** a downstream that branches on a *now-merged* function name *inside* its callback. That code keeps compiling but silently takes the wrong path — the only **silent** failure mode. It's uncommon (you have to opt into reading the function identifier), but because it's silent, it's the thing worth checking for.

> **Bottom line:** merging the functions mostly breaks the **calls a downstream makes** — loudly, and easily fixed. It **rarely touches the callbacks it receives**, and only when the callback was checking which function fired.

We validated this against a representative downstream integrator: its **calls** into the escrow need the mechanical rename/reshape, while its **callbacks need no changes at all** (its payout callback ignores the trigger, and its hook watches only the unchanged lifecycle points).

**Portable rule for downstream authors:** in a callback, key off the **result** — the job's resulting state and the emitted events — rather than off the function name. Events keep their meaning through a merge even when function names collapse, so a callback written this way is immune to changes like this one.

---

## 7. Recommendation

The merge is **feasible and demonstrated**. It is a genuine net simplification with a clean underlying model, and the prototype proves the security and liveness properties survive (with explicit tests for the one boundary that the naive merge would have broken).

We recommend treating it as a **standards proposal** rather than a drop-in change: the value is real, but it changes the public interface and three behavioural guarantees, so it warrants community discussion and a fresh audit before adoption. The biggest practical cost is **integrator migration**, not contract risk.

For partners evaluating adoption, the decision reduces to three questions:

1. Do you need **overlapping/streaming claims**? If yes, the "no pay-around" serialization is a real constraint and may argue against the merge (or for keeping `settle`/`release` partially separate).
2. Are you comfortable with **"anyone who pays in full completes the job; only the evaluator reverses"** as the completion rule?
3. Can your ecosystem absorb a **one-time interface migration** (selectors + signed-message types)?

If those are acceptable, the collapse is a strong simplification. If overlapping claims or strict evaluator-exclusive completion are hard requirements, a partial merge (e.g. unify the terminal release but keep the provider/claim functions separate) captures much of the benefit at lower disruption.

---

*Appendix — surface at a glance:*

```
BEFORE (8):  submit · submitClaim · complete · settleClaim · approveClaim · reject · rejectClaim · claimRefund
AFTER  (5):  submit · settle · release · reject · claimRefund

  submit   (provider)            file a claim; full → Submitted, partial → pending
  settle   (client only)         originate a direct payment; drain → Completed
  release  (client | evaluator)  resolve a standing assertion; drain → Completed
  reject   (scoped by claim id)  cancel one claim (continue) OR terminate + refund
  claimRefund (anyone)           post-expiry refund
```
