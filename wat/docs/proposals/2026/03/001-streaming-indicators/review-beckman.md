# Review: Brian Beckman

Verdict: CONDITIONAL

## Summary

The proposal correctly diagnoses a real disease: the `(field raw-candle ...)` form conflates a point-in-time product type with a stream processor that accumulates history. The cure — closure factories that return stateful step functions — is sound engineering. But the algebraic story has gaps that need closing before this ships.

## What closes well

### The closure-as-state-machine pattern

Each `make-*` factory returns a function `f64 -> f64` (or `f64 -> (f64, f64, f64)` for Bollinger). These are coalgebras: a state `S` together with a step function `S -> A -> (S, B)`. The proposal hides `S` behind the closure, exposing only `A -> B`. That is the right thing to do. The enterprise heartbeat already has the shape `(state, event) -> state` — these closures compose with that fold because they ARE the same fold, just scoped to a single indicator.

The composition of higher-order indicators (RSI wrapping two Wilder smoothers, Bollinger wrapping an SMA) is clean. You get a tree of coalgebras, each ticking in lockstep. Since the enterprise feeds candles one at a time in temporal order, the tick discipline is trivially maintained. No indicator can "skip ahead" because no indicator holds a reference to the candle stream — it receives one value per step.

### The two-concern factoring

Indicator state (coalgebras over scalar values) vs. candle window (a ring buffer of raw OHLCV for spatial pattern modules) — this is a categorical product, not a coproduct. Each concern has its own projection, its own lifecycle, its own memory model. The proposal correctly identifies that these must not be conflated. An indicator closure has O(1) steady-state memory. A candle window has O(window) memory and serves a different population of consumers (Ichimoku, Fibonacci, divergence). Factoring them as independent concerns means you can vary one without perturbing the other. Good.

## What does not close

### 1. The indicator bank lacks algebraic structure

The proposal asks (Question 1): flat list or named struct? This is not a design preference question — it is an algebraic question. The indicator bank is a product type. It must be a struct. Here is why.

A vocab module like `eval-stochastic` currently projects fields from the Candle struct: `(:stoch-k now)`, `(:stoch-d now)`. Under the proposal, those values come from the indicator bank instead. If the bank is a flat list, the module must know the positional index of each indicator. That is a de Bruijn encoding — correct but fragile. A named struct preserves the projection law: `(:stoch-k bank)` extracts the stochastic %K value regardless of how many other indicators exist. This is the product elimination rule. It is not optional.

More precisely: the bank is a dependent product indexed by indicator name. Each fiber has type `f64` (or a small tuple). The struct declaration makes the index set explicit and static. The flat list makes it implicit and positional. Use the struct.

### 2. The composition boundary between indicators and vocab is underspecified

Today, `eval_stochastic(candles: &[Candle])` reads pre-computed values from the Candle struct. Under the proposal, the Candle struct shrinks to raw OHLCV. So where does `eval_stochastic` get `stoch_k` and `stoch_d`?

The proposal does not say. There are two clean options:

**(a)** The indicator bank is a second argument: `eval_stochastic(candles: &[Candle], bank: &IndicatorBank)`. This is a product in the function's domain. The vocab module projects from two sources — raw candles for spatial patterns, indicator bank for derived values. Clean, explicit, testable.

**(b)** The indicator bank's current values are stitched onto a "fat candle" before the vocab modules see it. This recovers the current interface but re-introduces the coupling the proposal aims to eliminate.

Option (a) is the right factoring. The proposal should specify it.

### 3. `set!` in a specification language needs a semantic anchor

The proposal acknowledges mutation inside closures (Question 3) but waves it away with "bounded and encapsulated." That is an engineering argument. The algebraic argument is: each closure is a Moore machine (finite state transducer). The `set!` operations transition the internal state. The closure boundary is the encapsulation boundary — no external observer can witness the intermediate states, only the outputs.

This is fine, but Wat's LANGUAGE.md says `set!` maps to `&mut self` in the Rust compilation target. That means each closure must own its state exclusively — no shared references, no aliasing. The proposal should state this as an invariant: **each closure is a uniquely-owned Moore machine. No two closures alias the same state.** This is trivially satisfied by the factory pattern (each `make-*` call allocates fresh state), but it should be explicit in the spec so that future compositions cannot violate it.

### 4. The warmup period is algebraically invisible

Every indicator has a warmup window during which its output is unreliable. SMA(20) needs 20 samples. Wilder RSI needs at least `period` samples for the initial average, then converges exponentially. The proposal's closures handle this internally (the `count <= period` branch in `make-wilder`), but the **consumer** of the indicator value has no way to distinguish "warmed up" from "warming up."

This matters because the journal learns from thoughts. If the first 200 candles produce garbage indicator values, the journal learns from garbage. The closure should either:

- Return `Option<f64>` (None during warmup), forcing the consumer to handle it.
- Emit a warmup flag alongside the value.
- Expose a `ready?` predicate.

The first option is the cleanest — it makes the partial function explicit. Wat already has `field?` for optional struct fields. Use it: `(:rsi bank)` returns `Option<f64>`, and vocab modules that require RSI return `None` during warmup. The partiality propagates naturally through the `when-let` form.

### 5. The observer's journal composition is not addressed

The proposal says "the learning pipeline (journal, observe, predict, resolve, curve) is unchanged." But the journal observes thoughts, and thoughts are bundles of facts, and facts come from vocab modules, and vocab modules now read from the indicator bank instead of the Candle struct. The data flow changes even if the journal API does not.

Specifically: when an observer samples a window of N candles, it currently gets a slice of fat Candles with all 52 fields. Under the proposal, it gets a slice of raw Candles plus an indicator bank that holds only the *current* indicator values (the closures tick once per candle, producing a single output). But `eval_stochastic` needs `prev.stoch_k` — the previous candle's indicator value. So either:

- The indicator bank stores a small history (at least `[prev, current]` for cross-detection modules).
- Or the enterprise maintains a ring buffer of recent indicator bank snapshots alongside the raw candle window.

This is not hard to solve, but it must be solved in the proposal, not discovered during implementation. The closure produces one value per tick. The vocab module needs at least two. The proposal must specify how that gap is bridged.

## The monoid question

Do closures form a monoid? Almost. The operation "run indicator A, then run indicator B, emit both values" is the product of two Moore machines. It has an identity (the trivial machine that emits nothing). It is associative. So the indicator bank as a whole is a product monoid of Moore machines, ticked in parallel. This is a strong structure — it means you can add or remove indicators without disturbing the others.

But the higher-order indicators (RSI, Bollinger, MACD) break the simple product because they compose vertically — RSI wraps two Wilder smoothers. This is not monoid composition; it is functor composition. RSI is a functor from the category of Wilder-smooth outputs to the category of oscillator values. The proposal handles this correctly by nesting closures, but it should name the structure: **the indicator bank is a DAG of Moore machines, where edges represent data dependencies, and the bank ticks the DAG in topological order.** The product monoid is the horizontal structure (independent indicators). The functor composition is the vertical structure (dependent indicators). Both must be present.

## The functor question

Does the two-concern split (indicator state vs. candle window) factor cleanly categorically? Yes, if you see it as a bifunctor:

```
F : IndicatorBank x CandleWindow -> Facts
```

Each vocab module is a morphism in this product category. The indicator bank evolves coalgebraically (tick by tick). The candle window evolves as a sliding window (append, drop oldest). The vocab module observes both and produces facts. The fact bundle then enters the Holon encoder, which is a separate functor from Facts to Vectors. The composition `encode . vocab . (bank, window)` is a well-defined pipeline.

This factoring is clean. The proposal should state it explicitly so that future contributors do not accidentally merge the two concerns back together.

## Conditions for approval

1. **Specify the indicator bank as a named struct**, not a flat list. The product type is the algebraic structure. Answer Question 1 definitively.

2. **Specify the vocab module interface** post-migration: `eval_foo(candles: &[Candle], bank: &IndicatorBank) -> Option<Vec<Fact>>`. The dual-source projection must be explicit.

3. **Return `Option<f64>` during warmup.** Make the partial function visible to consumers. No silent garbage during convergence.

4. **Specify the history bridge** for vocab modules that need previous indicator values. Either the bank stores `[prev, current]` or a ring buffer of snapshots exists. The proposal must say which.

5. **State the ownership invariant**: each closure uniquely owns its state. No aliasing, no shared mutation.

These are not implementation details — they are algebraic properties that determine whether the system composes correctly. The closure pattern is the right idea. The factoring is the right factoring. But a specification must close, and this one has five open seams.

## What I like

The proposal is honest about what is broken (the 17 phantoms, the field-as-lie diagnosis) and conservative about what it preserves (the journal, the encoder, the enterprise fold). The two-concern split is genuinely insightful — most engineers would have muddled indicator state and candle history into a single "enriched candle" and wondered why the memory model was incoherent.

The closure factories compose well because they are coalgebras. The enterprise's `(state, event) -> state` fold is also a coalgebra. The indicator bank ticks inside that fold. It is coalgebras all the way down. That is the kind of uniformity you want in a system that has to survive contact with live data.

Fix the five conditions and this is a clean piece of work.

-- Brian Beckman
