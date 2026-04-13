# Review: Beckman / Verdict: APPROVED

Proposals 043-048 built a tower from conviction spikes to pivot
biographies to tracker programs. 049 rips out the detection
mechanism and replaces it with a structural classifier. Good.
The tower was built on sand (conviction percentiles). Now it
stands on price. The architecture above the detection layer
is preserved. This is a morphism swap at the base of a
composition chain. Clean.

## 5. Where does the labeler live categorically?

The labeler is a **stream transducer**. Specifically a Mealy
machine: it consumes `(f64, f64, usize)` — close, volume,
candle number — and emits `PhaseRecord` updates. It has
internal state. It produces output on every input. This is
exactly the categorical shape of a streaming indicator.

Look at what the indicator bank already does. `tick` takes a
`RawCandle`, advances 26 streaming primitives (EMA, Wilder,
RingBuffer — all accumulators over monoids), and produces a
`Candle` with ~80 derived fields. Each `step_*!` call is a
Mealy machine: state + input -> state + output. The labeler
is one more `step_phase!` call.

The labeler belongs on the indicator bank. The argument is
categorical: the indicator bank is a **product of Mealy
machines** running in parallel over the same input stream.
Adding one more factor to the product does not change the
product's type. The `Candle` struct gains a `phase: PhaseRecord`
field (or `current_phase` plus `phase_history`). Every observer
sees it. No new wiring. No new channels.

The pivot tracker program (047) was needed because conviction-
based detection required N market observers to write to a shared
store. The phase labeler does not. It reads closes — which are
already on the candle stream. It needs no observer output. It is
**pre-observation**, not post-observation. It belongs upstream of
the observers, on the indicator pipeline, exactly where RSI and
ATR live.

This eliminates the tracker program (047) and its channel
machinery entirely. The program was the right pattern for
conviction-based detection (many writers, many readers). It is
the wrong pattern for price-structure detection (one writer —
the candle stream — many readers). Simpler is better. The
indicator bank is simpler.

Do not make it a separate functor. A separate functor would
require its own scheduling, its own channel, its own lifetime
management. The indicator bank already solves all of these.
The labeler is a **component** of the product, not a peer.

## 6. The state: monoid accumulator or state machine?

Both. And this is the interesting part.

A streaming indicator like EMA is an accumulator over a monoid.
The state is a single value. The transition is
`s' = alpha * x + (1 - alpha) * s`. The output is `s'`. This is
a Moore machine (output depends only on state), and the state
space is R. One dimension. One mode.

The phase labeler has **multiple modes**: tracking-high,
tracking-low, in-transition. Within each mode, the transitions
are monoid-like (extending the extreme is `max`, extending the
phase stats is accumulation). But the **mode switches** — when
a reversal exceeds the threshold — are genuine state machine
transitions. The state space is not R. It is:

```
{tracking-high, tracking-low, transition-up, transition-down}
  x (extreme: f64)
  x (phase_stats: PhaseRecord)
  x (history: VecDeque<PhaseRecord>)
```

This is a product: a finite automaton (the mode) tensored with
continuous accumulators (the stats). The mode governs which
accumulator updates fire. This is richer than RSI (one mode,
one accumulator) but not categorically different from what the
indicator bank already handles. The DMI indicator, for instance,
has directional modes (+DI dominant vs -DI dominant) with
separate accumulators for each. The Ichimoku has five lines with
different lookback windows interacting. The indicator bank is
already a product of stateful transducers with internal branching.
The phase labeler is one more.

The key observation: the **mode transitions are deterministic
functions of the input and state**. There is no nondeterminism.
No external signal. No oracle. The labeler is a deterministic
Mealy machine with a product state space. This is exactly what
a streaming indicator is allowed to be.

The history (confirmed phases as a bounded VecDeque) is the only
piece that looks different. RSI does not remember its past values.
But this is just a RingBuffer of structs instead of a RingBuffer
of f64s. The indicator bank already uses RingBuffers everywhere.
A `RingBuffer<PhaseRecord>` is the same categorical object as a
`RingBuffer<f64>` — a bounded stream with a sliding window. The
type parameter changes. The structure does not.

## The composition diagram

The question is whether this commutes:

```
closes --[labeler]--> phases --[Sequential]--> thought --[reckoner]--> verdict
```

**closes -> phases:** The labeler is a Mealy machine. Deterministic.
Same closes, same smoothing -> same phases. Functorial: it
preserves the stream structure (order, causality). Check.

**phases -> Sequential:** Each PhaseRecord becomes a ThoughtAST
via `phase-thought`. The sequence of phases becomes
`Sequential(vec![...])`. This is a natural transformation from
the phase stream to the thought algebra. The Sequential form
(from 044) is `permute(child, position) + bundle` — a composition
of existing primitives. The permutation is invertible (in
principle) so no information is destroyed. Check.

**Sequential -> thought:** The Sequential vector bundles with
the trade atoms (040), the market extraction, and whatever else
the exit observer composes. Bundle is the superposition operator.
The permuted elements live in rotated subspaces and compose
cleanly with non-permuted elements — this was established in
044's review. Check.

**thought -> reckoner -> verdict:** The reckoner consumes the
composed thought vector and produces a prediction. This is the
existing learning path. The reckoner does not care where the
vector came from. It sees geometry. Check.

The diagram commutes. Each arrow is a well-typed morphism. The
composition is:

```
reckoner . bundle . Sequential . map(phase-thought) . labeler
```

Each component is a stream transducer or a pointwise function.
The composition of stream transducers is a stream transducer.
The whole pipeline from closes to verdict is one composed Mealy
machine.

## One concern: the smoothing parameter

The smoothing determines the labeler's behavior. If ATR-based,
the smoothing itself is a streaming indicator output. This
creates a dependency within the indicator bank: the phase
labeler reads the ATR output. This is fine — the indicator bank
already has internal dependencies (Bollinger reads SMA, MACD
reads two EMAs, Ichimoku reads multiple lookbacks). The `tick`
function orders the `step_*!` calls to respect these
dependencies. `step_phase!` must come after `step_atr!`. The
dependency is acyclic. No issue.

If the smoothing is a fixed percentage, the dependency
disappears entirely. Even simpler.

## Summary

The labeler is a Mealy machine. It belongs on the indicator
bank as one more factor in the product. Its state is richer
than a scalar accumulator — it is a finite automaton tensored
with continuous accumulators — but this is a difference of
degree, not kind. The composition from closes through phases
through Sequential through thought to reckoner is a chain of
well-typed morphisms. The diagram commutes. The tracker program
(047) can be retired.
