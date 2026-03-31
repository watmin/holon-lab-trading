# Review: Rich Hickey

Verdict: CONDITIONAL

Conditional on resolving the encoding split honestly and collapsing the two entry points. The rest is sound engineering with domain-appropriate complexity.

---

## Preamble

You have six primitives. They are fixed. The question is whether your application composes them simply or whether it has introduced accidental complexity through its own choices. Let me take each question in turn.

---

## 1. The encoding split: should thought encoding live inside or outside the fold?

**Current design is simple, but mislabeled.**

You call the enterprise "a fold over `Stream<Event>`." It is not. It is a fold over `Stream<(Event, EncodedThought)>`. That is a different type. The encoding step is a *map* that precedes the fold. The pipeline is:

```
candles  ->  map(encode)  ->  fold(state, encoded_event)  ->  state
```

This is not a leak. This is a transducer. The encoding is a pure function of the candle window — it has no state that the fold needs to know about. `ThoughtEncoder` and `VectorManager` are deterministic: same input, same vector. They are not accumulators. They do not learn. They are functions, not state.

The lie is not in the architecture. The lie is in calling `on_candle` part of the fold when it consumes pre-encoded data. The `Event::Candle` variant in your sum type promises that the enterprise can process a raw candle. It cannot. The `on_event` handler for `Candle` is a dead branch with a comment that says "placeholder."

**What to do:** Either make `Event::Candle` carry the encoded thought (honest type), or implement the live encoding path in `on_event`. Do not leave a sum type variant that lies about what it handles. The type is the contract. A variant that does nothing violates the contract.

The rayon batch encoding is a valid optimization. Map-then-fold is how you parallelize a sequential reduction. Nothing is complected here except the naming.

---

## 2. Two entry points: should on_event and on_candle be unified?

**Yes. This is complected.**

You have two functions that advance the state machine: `on_event` and `on_candle`. The first handles Deposit/Withdraw. The second handles the actual work. The caller must know which to call and when. This is complecting *dispatch* with *interface*.

The fix is straightforward. Your Event sum type already has the right shape. Make one entry point:

```
on_event(&mut self, event: &EnrichedEvent, ctx: &CandleContext)
```

where `EnrichedEvent` is:

```
Candle { candle, thought_vec, fact_labels, observer_vecs }
Deposit { asset, amount }
Withdraw { asset, amount }
```

The encoding lives in the map step. The fold has one entry point. The binary constructs `EnrichedEvent::Candle` from the rayon output. A live feed constructs it inline. Same type, same fold, different source. This is the whole point of the streaming abstraction you already built.

This is not a performance concern. It is a simplicity concern. Two entry points means two places where state transitions happen. Two places to audit. Two places where invariants can diverge.

---

## 3. The pending queue: is VecDeque<Pending> the right accumulator?

**Yes. This is domain complexity, not accidental complexity.**

The Pending struct has 20 fields. You worry this is too many. But look at what they are:

- Immutable entry-time data (candle_idx, entry_price, entry_atr, tht_vec, observer_vecs, mgr_thought, fact_labels) — this is the *value* captured at prediction time. It must be preserved for resolution. You cannot compute it later because the journal state will have changed.
- Mutable tracking (max_favorable, max_adverse, trailing_stop, path_candles) — this is the position management state, updated each candle.
- Resolution output (first_outcome, exit_reason, exit_pct) — written once when the trade resolves.

This is a *log entry being written over time*. It starts as a prediction, accumulates market observations, and resolves into a labeled training example. The 20 fields are three distinct concerns: the snapshot, the tracking, and the resolution.

The VecDeque is the right structure. Entries arrive at the back, resolve at the front, and the queue is bounded by `horizon * max_concurrent_trades`. In practice, with horizon=36 and max_positions=1, this is dozens of entries. The "grows unbounded in theory" concern is theoretical — the safety valve (10x horizon expiry) provides the bound.

**One improvement:** The three concerns (snapshot, tracking, resolution) could be made structurally explicit. Not three structs — that is over-engineering. But grouping the fields with clear section comments (which you already do) is sufficient. The Pending struct is a *value being assembled*. That is a legitimate pattern.

---

## 4. Risk boundaries: treasury or portfolio?

**The code is right. The spec is wrong. Update the spec.**

The `// decomplect:allow(wrong-struct)` comment on `risk_branch_wat` tells me you already know this. The risk branches measure *trade-sequence patterns*: loss clustering, accuracy decay, drawdown velocity, return volatility. These are properties of the *trading history*, not the treasury balance.

The treasury knows balances. The portfolio knows outcomes. Risk is a function of outcomes. The portfolio is the right home.

When you build the multi-asset enterprise, each desk will have its own portfolio and its own risk branches. The treasury will have its own health metrics (utilization, concentration, correlation across desks). These are different concerns. Do not unify them prematurely.

**What to do:** Move the `decomplect:allow` to a proper architectural decision. The risk features belong on Portfolio (or better: extracted as a pure function `fn risk_features(&Portfolio, &VectorManager, &ScalarEncoder) -> [Vec<f64>; 5]` that takes the portfolio as data). The spec should say "risk branches measure trade-sequence patterns" because that is what they do and what they should do.

---

## 5. The generalist: entity or vestige?

**Vestige. Dissolve it.**

The generalist uses a fixed window. Every other observer discovers its own window through the sampler. The generalist's curve_valid flag is driven by the manager's resolved predictions, not its own accuracy. It does not have its own identity in the proof gate — it borrows someone else's.

A thing that does not prove itself has no place in a system built on proof gates. The generalist was useful when there was one journal. Now there are five specialists plus a manager. The generalist's role — "see everything at one scale" — is what the manager does by reading the panel.

The facts the generalist encodes are the union of all specialist facts. The specialists each see these same facts through their own window. The generalist adds no information that the panel does not already contain.

**What to do:** Remove the generalist. If you want a "full-spectrum" observer, make it a sixth specialist with its own window sampler, its own journal, its own proof gate. Either it earns its place or it does not exist.

---

## 6. Desk composition: does the architecture fractal?

**Yes. This is the strongest part of the design.**

The tree structure already implies the answer:

```
Treasury (shared)
├── BTC Desk (own observers, own manager, own risk, own portfolio)
├── ETH Desk (own observers, own manager, own risk, own portfolio)
└── SOL Desk (own observers, own manager, own risk, own portfolio)
```

Each desk is a self-contained fold over its asset's candle stream. The treasury is the shared resource that desks claim from and release to. The `Event` sum type already carries an `asset` field. The `merge_streams` function already exists. The treasury already has a balance map keyed by asset.

The algebra closes because each desk's state is independent. Desks do not read each other's journals. The only shared state is the treasury, and the treasury's interface is claim/release/swap — three operations that compose.

The one thing you will need is a *cross-desk allocator* — something that decides how much capital each desk can claim. This is a new node in the tree, between treasury and desks. It is Template 2 (reaction): an OnlineSubspace that learns what "healthy portfolio allocation" looks like across desks. This is a natural extension, not a redesign.

**The `i` parameter** deserves a note here. In multi-asset, different assets tick at different rates. A global candle index is meaningless. Replace `i` with the enterprise's own tick counter (which `cursor` already is). The candle index is a batch artifact. The cursor is the fold's time.

---

## Summary of conditions

1. **Collapse the two entry points.** One function, one enriched event type. The encoding map lives outside. The fold has one door.

2. **Make the Event type honest.** Either `Event::Candle` carries encoded thoughts, or it carries a raw candle and `on_event` encodes it. No dead variants.

3. **Dissolve the generalist.** It does not prove itself. If it cannot stand on its own proof gate, it is not an observer.

4. **Replace `i` with `cursor`.** The fold counts its own ticks. The candle index is the source's concern, not the fold's.

5. **Update the spec.** Risk features belong on trade history, not treasury state. The code is right. Make the spec agree.

These are not large changes. They are naming changes and type changes. The architecture is sound. The six primitives compose correctly. The tree is the right shape. The pending queue is the right accumulator. The encoding split is a valid map-then-fold, not a leak.

The complexity you see — 150 facts, 20-field Pending, 40-field state — is the market. Markets are complex. Your job is not to make the market simple. Your job is to not add complexity on top. You have largely succeeded. Clean up the interface, and this design is ready for multi-asset.
