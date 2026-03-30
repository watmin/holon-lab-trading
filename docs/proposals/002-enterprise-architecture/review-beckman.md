# Review: Brian Beckman

Verdict: CONDITIONAL

The algebra is mostly honest. The six primitives close. The architecture has two genuine escapes from the monoid and one structural misplacement, but these are fixable without redesign. What follows addresses the six questions, then the categorical structure.

---

## Answers to the six questions

### 1. The encoding split: inside or outside the fold?

Outside is correct. Here is why.

The encoding step `Candle -> Vector` is a functor. Call it `F: Candle -> Vect`. It is deterministic (same candle window, same seed, same vector), stateless in the categorical sense (the VectorManager is a memo table, not mutable state -- it is an oracle for a pure function from names to vectors), and structure-preserving (bind preserves role-filler distinctness, bundle preserves superposition).

A functor that precedes a fold is not an escape -- it is the standard construction. You have:

```
Stream<Candle> --F--> Stream<Vector> --fold--> State
```

This is `fold . fmap F`, which by the universal property of catamorphisms is itself a catamorphism over `Stream<Candle>` with algebra `(state, candle) -> state` defined as `g(s, c) = h(s, F(c))` where `h` is the vector-level fold step. The split is a performance optimization that preserves the algebra exactly because `F` is a functor (no side effects, no state leakage).

The ThoughtEncoder carries window samplers, but these are deterministic functions of the candle index -- they compute, they do not mutate. The VectorManager's internal cache is operationally mutable but semantically pure (it is a memoized function `String -> Vector` with a fixed seed). Neither breaks the functor law.

**Verdict: valid optimization, not an escape.** The encoding functor commutes with the fold.

### 2. Two entry points: should on_event and on_candle unify?

Yes, but the current split is not algebraically wrong -- it is categorically redundant. You have two morphisms into the same carrier:

```
on_event:  Event x State -> State
on_candle: (i, Candle, Vector, Facts, ObserverVecs) x State -> State
```

`on_candle` is `on_event` post-composed with the encoding functor, specialized to the `Event::Candle` variant, with the functor's output passed as arguments. The `on_event` path for `Candle` is a stub (`let _ = candle`). So you have a coproduct that is only half-wired.

This is not an escape from the monoid. It is an incomplete morphism. The algebra closes on the `on_candle` path. The `on_event` path closes for `Deposit/Withdraw` (pure treasury arithmetic). The gap is that `on_event` for `Candle` does nothing -- the fold step is undefined on one summand of the input coproduct.

**Verdict: not a leak, but a dangling morphism.** Unify when the live feed arrives. Until then, the architecture is a partial function on Event, total on the paths actually exercised. This is fine for a backtest-first system. Document the partiality.

### 3. The pending queue: accumulator or escape hatch?

This is the first real question. The `VecDeque<Pending>` is a delayed-evaluation buffer. Each `Pending` entry stores a thought vector and waits `horizon` candles for the market to reveal a label. This is a standard construction: the fold's carrier type includes a finite queue of unevaluated thunks.

Formally, the state is `S = CoreState x Queue<Pending>`, and the fold step is:

```
step(s, candle) = (update_core(s', candle), enqueue(candle) . resolve_mature(queue, candle))
```

where `resolve_mature` pops entries whose age exceeds `horizon` and feeds their labels back into the journals. The queue is bounded by `horizon * max_concurrent_trades` -- it does not grow without bound because entries expire via the safety valve (`10 * horizon`).

This IS the accumulator. A fold over a stream where labels arrive later than observations requires exactly this structure. The alternative -- labeling immediately -- would mean the fold has no memory of its predictions, which breaks the learning loop entirely.

The 20 fields on `Pending` are a concern, but categorically they are the product of the observation and its deferred resolution. Each field is either set at entry time (the observation) or set at resolution time (the outcome). This is a standard writer/reader pair over the queue.

**Verdict: the pending queue is the correct accumulator for a learning fold with delayed labels.** The field count is domain complexity, not algebraic escape. However -- the `i: usize` parameter (candle index) that drives `path_candles` and expiry is an escape. See below.

### 4. Risk boundaries: treasury or portfolio?

The proposal notes that `risk_branch_wat()` lives on `Portfolio`, not in the risk module, and measures trade-sequence patterns rather than treasury-level state. Let me be precise about what this means categorically.

The risk branches are `OnlineSubspace` instances -- Template 2, the reaction template. They consume feature vectors and learn a normal subspace. Their `residual()` scores deviation from normal. This is a proper endofunctor on the vector space: `Vect -> R` (the residual is a scalar projection).

The question is: what generates the feature vectors? Currently, `Portfolio::risk_branch_wat()` encodes trade history (drawdown depth, drawdown velocity, win streaks, loss streaks, return autocorrelation). These are derived from `Portfolio`'s deques -- `equity_at_trade`, `trade_returns`, `completed_drawdowns`.

This is the wrong boundary, but for a subtle reason. The risk branches should be a natural transformation from the treasury's observable state to the risk vector space. Right now they are a natural transformation from the *portfolio's* observable state. The portfolio is a subset of the enterprise state that tracks trade outcomes. The treasury tracks asset holdings.

The distinction matters for multi-desk composition. If risk reads the portfolio, each desk's risk branch sees only that desk's trade history. If risk reads the treasury, it sees the aggregate exposure across all desks. For single-desk, these coincide. For multi-desk, portfolio-level risk misses cross-desk correlation -- the exact thing the correlation branch is supposed to detect.

**Verdict: the algebra closes either way, but the natural transformation's domain is wrong for the multi-desk case.** Move `risk_branch_wat` to the treasury (or to a new `RiskEncoder` that reads treasury state). The risk branches should be functors from treasury observables, not portfolio history.

### 5. The generalist: entity or vestige?

The generalist is an observer with a fixed window and all facts, whose `curve_valid` flag is driven by the manager's resolved predictions rather than its own. Categorically, this means the generalist's proof gate is not an endomorphism on its own state -- it depends on an external morphism (the manager's resolution).

Every other observer has this structure:

```
observe: Candle -> Vector  (own window, own vocab)
predict: Vector -> Prediction  (own journal)
prove:   Resolved -> Bool  (own curve)
```

The generalist has:

```
observe: Candle -> Vector  (fixed window, all facts)
predict: Vector -> Prediction  (own journal)
prove:   ManagerResolved -> Bool  (external curve)
```

The `prove` morphism breaks the pattern. The observer category has objects `(Journal, WindowSampler, Curve)` and morphisms that are closed within each observer's state. The generalist violates this closure -- its proof gate is not a self-map.

This does not break the algebra of the fold (the fold still converges). It breaks the *uniformity* of the observer category. The generalist is not an observer in the same category as the specialists. It is a degenerate case -- an observer whose proof gate has been replaced by the manager's.

**Verdict: the generalist is a vestige.** Its facts should be distributed to the specialists (each already selects from the full vocabulary via its profile). Its prediction, if it adds signal, should become a sixth observer with its own window sampler and its own proof gate. If it does not add signal, dissolve it. The current structure is a categorical orphan -- it lives in neither the observer category nor the manager category.

### 6. Desk composition: does the fractal close?

The multi-desk structure would be:

```
Treasury (shared root)
|
+-- Desk BTC
|   +-- Manager_BTC
|   |   +-- Observers_BTC (own journals, own windows)
|   +-- Risk_BTC
|
+-- Desk ETH
|   +-- Manager_ETH
|   |   +-- Observers_ETH
|   +-- Risk_ETH
|
+-- Cross-desk allocator (reads all managers, modulates treasury allocation)
```

This is a product category. Each desk is an object `(Manager, [Observer], [RiskBranch])` with morphisms that close within the desk. The treasury is the terminal object -- all desks map into it via allocation requests and P&L settlements.

The cross-desk allocator is a new morphism: `Product(Desk_i) -> Treasury`. It reads the managers' proven bands and the risk branches' residuals across all desks and decides how to allocate the shared treasury. This is a natural transformation from the product of desk states to treasury actions.

Does it close? Yes, if:

1. Each desk's encoding is independent (different VectorManager seeds or namespaced atoms). Currently atoms are global strings ("momentum", "structure"), so two desks encoding "momentum" would collide. **This is a real problem.** Atom names must be desk-scoped.

2. Each desk's fold step is independent given the treasury state. Currently `on_candle` mutates a single `EnterpriseState`. For multi-desk, you need `on_candle_desk(desk_id, ...)` or separate `DeskState` objects composed into `EnterpriseState`.

3. The treasury's `open_position/close_position` interface is already asset-keyed (HashMap<String, f64>), so it generalizes naturally.

**Verdict: the fractal closes in principle, but requires two mechanical changes -- scoped atom namespaces and per-desk state separation.** The algebraic structure (product of desk categories with a shared terminal object) is sound.

---

## Categorical structure

### The fold

The enterprise is a catamorphism over `Stream<Event>` with carrier `EnterpriseState`. The fold algebra is:

```
h: EnterpriseState x Event -> EnterpriseState
```

This is a proper left fold (foldl). It is NOT a catamorphism in the strict sense (catamorphisms are over recursive data types with an initial algebra; a stream fold is the dual -- an anamorphism consumed by a catamorphism). But the operational semantics are correct: one pass, left to right, no revisiting.

The carrier type (`EnterpriseState`, ~40 fields) is the product of:
- Learning state (journals, labels) -- a monoid under `update`
- Queue state (pending, positions) -- a monoid under `enqueue/dequeue`
- Accounting state (treasury, portfolio) -- a monoid under `settle`
- Tracking state (counters, rolling windows) -- a commutative monoid under increment

Each component is independently a monoid. Their product is a monoid. The fold closes.

### The encoding functor

`F: [Candle] -> (Vector, [String], [Vector])` is a functor from the category of candle windows to the category of thought vectors. It preserves structure:
- `F(empty) = zero vector` (identity)
- `F(window1 ++ window2)` is not `F(window1) + F(window2)` -- this is NOT a monoidal functor. The encoding depends on the full window. This is fine. It means the encoding is a functor on *windows* (fixed-length subsequences), not on the stream itself.

### The two templates as a product

Template 1 (Journal prediction): `Vector -> Prediction` (discriminant query)
Template 2 (OnlineSubspace reaction): `Vector -> Residual` (anomaly score)

These live in different categories:
- Template 1: `Vect -> Label x R` (discrete label + continuous conviction)
- Template 2: `Vect -> R` (continuous residual)

They form a product: `Vect -> (Label x R) x R`. The manager consumes Template 1 outputs. The risk branches consume Template 2 outputs. The treasury consumes both. This is a standard fan-out followed by a fan-in at the treasury level. The product closes.

### Where the monoid breaks

Two genuine escapes:

**1. The `i` parameter.** `on_candle` takes `i: usize`, a global candle index. This is used for:
- Pending expiry (`path_candles`)
- Ledger keys
- Age tracking
- Progress display

A stream has no global index. The `i` is an artifact of the batch model (array indexing). In a true streaming fold, you would use a monotonic tick counter internal to the state -- which is exactly what `state.cursor` already is. The external `i` and the internal `cursor` are redundant. The external `i` should be eliminated; the cursor should be incremented by the fold step.

This is the most visible algebraic escape. It couples the fold to the batch runner's iteration variable.

**2. The SQLite ledger inside the fold.** `CandleContext` carries `&Connection`. The fold step writes to the DB inside `on_candle`. This is a side effect inside the catamorphism. A pure fold would return `(new_state, Vec<LogEntry>)` and the caller would write to the DB. The current design fuses the fold with its observation, which prevents the fold from being tested without a DB, replayed, or composed.

This is a pragmatic choice (buffered writes are faster than collecting and writing later), but it is categorically impure. The fold is `State x Event -> State x IO`, not `State x Event -> State`. The `IO` is an escape from the monoid.

---

## The complexity question

The 21 eval methods, 150 facts, 180-line resolution loop, 20-field Pending, 30-field CandleContext -- is this the domain or the machinery?

It is the domain. Markets emit ~150 distinguishable signals per candle (oscillators, flow, persistence, regime, structure). The encoding pipeline has one eval method per signal family. The resolution loop has one concern per level of the tree (observer resolve, manager resolve, exit resolve, risk update, treasury settle, ledger write). The Pending struct has one field per dimension of a trade's lifecycle. The CandleContext has one field per configuration parameter.

None of these are redundant. The question is whether they can be factored into smaller products. The answer: CandleContext should split into `EncodingConfig x TradingConfig x DisplayConfig`. Pending should split into `Observation x Resolution x Accounting`. The resolution loop should be a chain of morphisms, not a monolithic function. These are refactoring opportunities, not algebraic failures.

---

## Summary

| Question | Answer | Status |
|----------|--------|--------|
| 1. Encoding split | Valid functor, commutes with fold | CLEAN |
| 2. Two entry points | Partial function, will unify at live | CLEAN |
| 3. Pending queue | Correct accumulator for delayed labels | CLEAN |
| 4. Risk boundaries | Wrong domain for multi-desk | NEEDS WORK |
| 5. Generalist | Categorical orphan, dissolve or promote | NEEDS WORK |
| 6. Desk composition | Closes with scoped atoms + per-desk state | CONDITIONAL |

**The `i` parameter and the in-fold DB writes are the two algebraic escapes.** Everything else closes.

The condition for approval: acknowledge the two escapes and the risk boundary misplacement. None require immediate action -- the single-desk system is operationally correct. But the multi-desk composition will not close until atoms are scoped, risk reads treasury, and the generalist is resolved.

The six primitives are used correctly. No new primitives are needed. The templates compose as a product. The tree is a proper categorical structure. The fold converges. The algebra is sound where it claims to be algebraic, and honest about where it is not.

-- Brian Beckman
