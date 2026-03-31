# Review: Proposal 006 — Streaming Desks

Reviewer: Brian Beckman (role)
Scope: Algebraic compositionality review. The six primitives are fixed.

---

## Verdict

The algebra composes. The desk is a proper product. The event sum is well-formed. The staleness check is the one place where I have concerns — not fatal, but it needs tightening.

---

## 1. The Event Sum Type

The sum `Candle asset candle | Deposit asset amount | Withdraw asset amount` is a proper coproduct in the category of event types. Each variant is tagged, the tags are disjoint, and the fold dispatches by case analysis. This is exactly right.

One observation: the `asset` tag on every variant is good discipline. It means the heartbeat never needs to inspect the payload to know where to route. The routing decision is in the tag, the domain logic is in the payload. These are separate concerns and you have kept them separate. Well done.

A subtlety worth naming: `Deposit` and `Withdraw` are treasury-level events, while `Candle` is desk-level. The heartbeat dispatches all three, but the first two bypass desks entirely. This is fine — the sum type is the enterprise's event language, not the desk's. The desk sees only candles, filtered through `desk-receive`. The layering is clean.

## 2. The Desk as a Product Type

The desk record is:

```
(name, asset, quote-asset, observers, manager, risk, latest, last-tick, staleness-limit)
```

This is a product type — a labeled tuple of independent components. Each field has a well-defined type and a well-defined role. The desk is a value, not an object. It has no hidden channels, no lifecycle hooks, no background threads. You pass it in, you get it back. This is correct.

The key structural property: **desks do not share mutable state with each other.** Each desk has its own observers, own manager, own risk branch, own journals. The only shared thing is the treasury, and the treasury is passed as an argument to `desk-tick`, not stored inside the desk. This means desks compose by juxtaposition — you can add a desk or remove a desk without changing any other desk's behavior. That is the hallmark of a proper product decomposition.

One thing to verify in implementation: the proposal says "the treasury is shared — all desks draw from and return to the same pool." If desks tick in sequence within a single heartbeat step (which the fold guarantees), then each desk sees the treasury state left by the previous desk. This is deterministic but order-dependent. Desk A ticking before Desk B means A gets first claim on capital. The proposal acknowledges this in Question 4 but does not resolve it. I will return to this below.

## 3. The Fold

The enterprise remains `fold heartbeat initial-state events`. The event type changed from `Candle` to `Event`, but `fold` is parametric in its event type — it does not care. The heartbeat is the step function. The state is the accumulator. This is a standard catamorphism over the event stream and it composes.

The inner fold over desks within each heartbeat step is also correct:

```scheme
(fold (lambda (s desk) ...) state (desks state))
```

This is a fold within a fold. The outer fold processes events. The inner fold processes desks per event. Both are pure sequential reductions. No concurrency, no interleaving. The composition is straightforward.

## 4. The Staleness Check — Where I Push Back

Here is `desk-ready?`:

```scheme
(define (desk-ready? desk current-time)
  (and (some? (latest desk :asset))
       (some? (latest desk :quote))
       (< (- current-time (last-tick desk :asset))  (staleness-limit desk))
       (< (- current-time (last-tick desk :quote))  (staleness-limit desk))))
```

This is a predicate, not an algebraic operation. It does not violate the six primitives. But it introduces a **temporal coupling** that deserves scrutiny.

**4a. Staleness is relative to `current-time`, which is the candle timestamp.** This means staleness is determined by the data, not by a wall clock. Good — the fold remains deterministic. Same input stream, same staleness decisions, same output. No hidden state from the environment. I was worried about this and you handled it correctly.

**4b. But `staleness-limit` is a configuration parameter, and it encodes a hidden assumption about cadence.** You say "for 5-minute candles, a reasonable limit is one candle duration (300 seconds)." This means the staleness limit is coupled to the data frequency. If you feed the desk 1-hour candles with a 300-second staleness limit, the desk will never tick — every candle will be "stale" relative to the previous one on the other side. The staleness limit is not a property of the desk; it is a property of the desk-stream pair.

This is not a compositionality failure — it is a parameterization concern. But it means the desk is not fully self-describing. The desk record should either (a) derive its staleness limit from the stream metadata (candle interval), or (b) express staleness in units of candle intervals rather than seconds. Option (b) is simpler: `staleness-limit = 1` means "one candle interval." The desk does not need to know whether that is 300 seconds or 3600 seconds.

**4c. The nil-as-infinite-staleness trick is elegant but should be made explicit.** Question 3 in the proposal asks whether "no data yet" and "data arrived but is old" should be distinguished. The answer is no — and the reason is algebraic. The `some?` check on `latest` handles the nil case. If `latest` is nil, the desk is not ready. If `latest` is present but old, the staleness check handles it. The two cases have the same observable effect (desk does not tick), so there is no reason to distinguish them in the type. The predicate is already correct. Just document that nil means "not yet entered the stream" and let the staleness arithmetic handle the rest.

**4d. One genuine concern: the desk accumulates `latest` state that never resets.** When the desk receives a candle, it overwrites `latest`. The old candle is gone. This is fine for freshness checking. But the desk also passes `(candles desk)` to the observers in `desk-tick`. Where does `candles desk` come from? The proposal does not show a candle buffer in the desk record. The current enterprise uses a `VecDeque` window. If each desk needs its own candle window per side, that state must be in the desk record. This is not an algebraic problem — it is a completeness problem. The desk product type is missing fields.

## 5. The Stablecoin Degenerate Case

Question 1 asks: synthetic candles or disabled staleness check?

Neither. The right answer is: **the quote side of a stablecoin pair has `staleness-limit = infinity`** (or equivalently, the staleness check for that side always returns true). This is not a special case — it is a configuration. The desk record already has `staleness-limit` as a parameter. Make it per-side:

```scheme
(latest     { :asset nil  :quote nil })
(last-tick  { :asset 0    :quote 0 })
(staleness  { :asset 300  :quote +inf })  ;; stablecoin quote never goes stale
```

This is still a product type. No conditionals in the predicate. No synthetic data polluting the stream. The desk is honest about what it knows: the asset side needs fresh data, the quote side does not. Per-side staleness is the clean generalization.

## 6. Capital Allocation and Desk Ordering

Question 4 is the real open problem and the proposal is right to flag it.

The sequential fold over desks means the first desk in the list gets priority access to capital. This is an implicit policy. Implicit policies are complected state — you cannot reason about capital allocation without knowing the desk ordering, and the desk ordering is not part of any desk's type.

Three options, in order of algebraic cleanliness:

**(a) Two-phase tick.** Phase 1: all desks produce a request (direction, conviction, sizing). Phase 2: the enterprise allocates capital across requests proportionally or by priority, then executes. This separates the decision from the execution. The desk tick becomes pure — it produces a recommendation, not a side effect on the treasury. The enterprise step applies recommendations. This is the cleanest but requires splitting `desk-tick` into `desk-recommend` and `desk-execute`.

**(b) Capital budgets.** Each desk has a maximum allocation. The treasury enforces it. Desks cannot over-draw. Order does not matter because each desk's budget is independent. This is simple but static — you need a cross-desk policy to set the budgets, which is the problem you deferred.

**(c) Accept order-dependence as a feature.** Document that desk ordering is a parameter. The first desk is the primary strategy; subsequent desks are satellites. This is honest but limits compositionality — you cannot freely reorder desks.

I recommend (a). It preserves the product structure: desks are independent in the recommendation phase, and the allocation policy is a separate function that composes recommendations with treasury state. This also gives you a natural place for the cross-desk manager (Question 2) — it reads all desk recommendations before the treasury acts.

## 7. Price Map Placement

Question 5: should the price map live in the treasury or enterprise state?

In the enterprise state. The price map is updated by candle events, which the treasury does not process. The treasury is pure accounting — it should receive prices, not observe candle streams. The heartbeat updates the price map from candle events. The treasury reads the price map for valuation. This is the same separation of concerns that keeps the treasury clean in the current design.

The alternative — having the treasury own the price map and receive price updates directly — would mean the treasury processes two kinds of input (swap requests and price updates). That is two responsibilities in one module. Keep it separate.

## 8. Summary of Findings

| Aspect | Assessment |
|---|---|
| Event sum type | Well-formed coproduct. Tags are disjoint, dispatch is exhaustive. |
| Desk product type | Proper product. No shared mutable state between desks. Missing candle buffer fields. |
| Fold composition | Catamorphism over events, inner fold over desks. Both pure sequential reductions. Composes. |
| Staleness predicate | Deterministic (uses candle timestamps, not wall clock). But staleness-limit should be per-side and expressed in candle intervals, not seconds. |
| Hidden state | None that breaks determinism. The fold is reproducible from the stream alone. |
| Capital allocation | Order-dependent implicit policy. Recommend two-phase tick to separate recommendation from execution. |
| Primitives | Unchanged. The six are not touched. This is userland. |

The proposal is sound. The desk is a product, the event is a sum, the fold composes. Fix the staleness parameterization, add per-side limits, complete the desk record with candle buffers, and consider the two-phase tick for capital fairness. None of these are blockers — they are refinements that strengthen what is already a clean design.
