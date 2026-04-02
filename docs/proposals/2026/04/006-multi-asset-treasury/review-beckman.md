# Review: Brian Beckman

**Verdict: CONDITIONAL**

Conditional on phasing: fix the single-pair treasury first, then generalize. The algebra is sound. The architecture composes. But I want to be precise about *why* it composes and where the seams are.

---

## What closes

The proposal's central claim is correct: **no new algebraic structures are needed.** Let me trace why.

The six primitives (atom, bind, bundle, cosine, journal, curve) form a closed vocabulary. Each desk instantiates the same vocabulary over different data streams. A desk is a *functor* in the categorical sense: it maps the structure (observers, manager, risk, journal) faithfully from one pair's data to another. The desk doesn't know it's one of N. It produces a signal. The treasury consumes signals. This is clean separation of concerns and it composes by construction.

The treasury operations (claim, release, swap) are already parametric over `Asset`. Looking at the code, `Treasury` holds `HashMap<Asset, f64>` for both balances and deployed. The `swap` method takes `from: &Asset, to: &Asset`. Nothing in the treasury assumes two assets. It is already an N-asset ledger. The proposal is asking to *use* generality that already exists in the types.

The position lifecycle (Active -> Runner -> Closed) is independent of which pair generated it. A `ManagedPosition` tracks `base_deployed`, `quote_held`, `entry_price`, `direction`. These are pair-local quantities. When you have N desks, you have N independent position pools. No cross-position algebra is needed because positions don't interact. This is the product of N independent monoids, which is itself a monoid. Good.

## What I want to examine more carefully

### 1. The `allocatable()` bottleneck

The current `allocatable()` method computes room from `base_asset` only:

```rust
pub fn allocatable(&self) -> f64 {
    let total_base = self.total(&self.base_asset);
    let max_deploy = total_base * self.max_utilization;
    let deployed_base = self.deployed(&self.base_asset);
    ...
}
```

In a multi-asset world, a (SOL, BTC) desk wants to deploy BTC, not USDC. The `allocatable` function needs to become `allocatable(asset: &Asset) -> f64` or the utilization constraint needs to be stated in terms of total portfolio value rather than a single base asset. This is not a design flaw in the proposal -- it's an implementation detail the proposal correctly implies but doesn't spell out.

The deeper question: is `max_utilization` a *per-asset* constraint or a *portfolio-wide* constraint? If per-asset, the algebra stays local (each asset has its own utilization fraction). If portfolio-wide, you need a valuation step -- convert everything to a common unit -- before computing utilization. The `total_value(&self, prices: &HashMap<Asset, f64>)` method already exists for this. Either choice composes. The per-asset version is the product monoid. The portfolio-wide version requires a valuation homomorphism (prices map) applied before the constraint. Both are algebraically clean. Pick one and commit.

### 2. The asymmetry in position settlement

Currently, a Long position does `claim(quote_asset, received)` after swapping USDC->WBTC. A Short position does... nothing equivalent. Looking at the open-position code:

```rust
if direction == Direction::Long {
    self.treasury.claim(ctx.quote_asset, received);
}
```

For Short, the WBTC is sold to USDC, but no `claim` locks the USDC. This means the USDC from a Short entry is immediately available for other positions. That's a design choice, not a bug, but it breaks the symmetry: Long positions lock capital, Short positions don't.

In the multi-asset world, this asymmetry multiplies. If the (SOL, BTC) desk sells SOL for BTC, is the received BTC locked? If not, the (USDC, BTC) desk might immediately deploy that BTC for a Long. You'd get implicit cross-desk coupling through the shared balance pool. That's not algebraically wrong, but it means desks are no longer independent -- they share a mutable resource. The proposal says "desks are independent" but the treasury's balance pool couples them.

This is fine as long as you acknowledge it. The desks are independent in their *signal generation*. They are coupled in their *capital consumption*. The coupling is mediated by a shared resource (the treasury balance), not by information flow. This is the classic distinction between logical independence and resource independence. The proposal gets the first right and should be explicit about the second.

### 3. Position as allocation change vs. isolated lot (Question 1)

Keep the lot model. Here's the algebraic argument.

A position is an *element of a free monoid* over trade events. Each position is a word: open, tick, tick, ..., partial-exit, tick, ..., close. The lifecycle is a finite-state machine. The state transitions (Active -> Runner -> Closed) are well-defined. The return computation is local to the position.

If you redefine a position as "I moved X% of the treasury," you've made the position's identity dependent on the treasury's state at the time of opening. That's a *relative* quantity, not an *absolute* one. When you have N positions open, the percentages don't sum to what they summed to at entry time because the treasury has changed. You'd need to track the basis continuously, which is a bookkeeping nightmare that adds complexity without adding information.

The lot model is a *value* -- it carries its own context. The allocation model is a *reference* -- it points at global state. Values compose. References don't. Keep the lot.

What the proposal correctly identifies is that the treasury should make *all* available balance eligible for deployment, not just "trading capital." That's a one-line change: remove the concept of seed capital. The lot model is orthogonal to this. You can have lots that draw from the full balance without redefining what a lot is.

### 4. Sell from holdings (Question 2)

Yes. Sell from holdings. The algebraic reason: if the treasury is a monoid over asset quantities, there is no distinguished "seed" sub-monoid. A balance is a balance. The only question is risk gating, which already exists. The `max_utilization` constraint limits how much of any asset can be deployed. The seed was an artifact of the initial condition, not a structural feature.

### 5. No cross-asset manager -- the right call

The proposal says no meta-layer learning "which desk combinations predict wealth." This is correct and I want to reinforce why.

Each desk has a conviction-accuracy curve. The curve is the desk's proof of edge. The curves are *independent measurements*. If you add a layer that learns correlations between desk signals, you've introduced a new journal that needs its own proof gate, its own warmup, its own conviction threshold. The meta-layer's sample efficiency is terrible because it sees one "event" (a portfolio-level outcome) per many desk-level events. You'd be building a slow learner on top of fast learners.

Worse, the meta-layer would need to solve the credit assignment problem: when the portfolio gains, which desk gets credit? This is precisely the kind of problem VSA handles poorly (constraint satisfaction, as noted in the CLAUDE.md). The current architecture avoids it by making each desk independently accountable. Don't give that up.

### 6. Phasing (Question 3)

Fix single-pair first. Here's why.

The proposal identifies three problems: dead capital, isolated lots, single pair. Problems 1 and 2 are bugs in the current single-pair implementation. Problem 3 is a feature request. Fixing 1 and 2 requires:

- Make all WBTC balance available for Short deployment (remove seed distinction)
- Fix `allocatable()` to consider the deploying asset, not just base
- Ensure Short positions properly lock capital via `claim`

These changes are small, testable, and don't require architectural changes. They also serve as the *proof that the treasury algebra generalizes*. If the single-pair treasury can deploy from either side symmetrically, the multi-pair extension is just N copies of the same pattern.

Building multi-asset before fixing single-pair means carrying the asymmetries into N desks, where they become N times harder to debug.

## Summary

The proposal is algebraically sound. The key insight -- desks as functors over the fixed observer/manager/risk structure, treasury as a shared resource pool -- is correct. No new primitives are needed because the existing ones are parametric over `Asset` already.

The conditions:

1. **Fix the single-pair asymmetry first.** Short positions should lock capital symmetrically with Long. The seed distinction should be removed. `allocatable()` should be parameterized by asset.
2. **Decide per-asset vs portfolio-wide utilization** and commit. Both compose. Don't leave it ambiguous.
3. **Acknowledge resource coupling.** Desks are logically independent but share a mutable resource (treasury balances). This is fine but should be stated explicitly so that future designers don't assume full independence.
4. **Keep the lot model.** Values compose. References don't.
