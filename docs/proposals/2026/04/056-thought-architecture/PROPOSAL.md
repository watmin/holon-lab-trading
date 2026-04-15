# Proposal 056 — Thought Architecture

## The Problem

Three thinkers. Each thinks about different things. The boundaries
between what each thinks are unclear, violated, or missing. The
phase sequence is unbounded. The structural relations between
phases (higher highs, lower lows, weakening rallies) are not
encoded. The broker-observer has no name.

## Who Thinks What

### Market Observer

Thinks about direction. "Is the market going up or down?"

Input: candle window through its lens (momentum, structure, volume, regime, etc.)
Output: thought vector, anomaly vector, raw vector, prediction (Up/Down), edge
Learns: via its own reckoner, self-graded at peaks and valleys

The market observer's thought is ~33 facts per candle — the vocabulary
modules selected by its lens. It produces the anomaly (what the noise
subspace cannot explain) and the raw thought. Both flow downstream.

See: [examples/market-observer-thought.wat](examples/market-observer-thought.wat)

### Position Observer (Middleware)

Thinks about interpretation. "Which of the market observer's facts
are anomalous? What does the market look like through my lens?"

Input: MarketChain (market thought + anomaly + raw + candle)
Output: MarketPositionChain (market data + position-specific facts)
Learns: nothing. Pure middleware. Two lenses:

**Core lens**: regime facts + time facts. The consensus minimum.
Sees the character of the market (trending vs choppy, persistent vs
mean-reverting) and the time context (hour, day). Does not see phases.

**Full lens**: regime facts + time facts + phase current facts + phase
scalar summaries. Sees everything Core sees plus the current phase
state (label, direction, duration) and summary statistics of the
phase history (avg duration, avg range).

The position observer extracts from the market anomaly: for each of
the ~33 market facts, cosine against the anomaly vector. Facts above
the noise floor pass through as `(bind (atom "market") fact)`. Facts
above noise floor in the raw pass as `(bind (atom "market-raw") fact)`.
This IS the position observer's interpretation — which market thoughts
are anomalous right now.

The phase sequence is NOT a position observer thought. It is a fact
about the market that flows on the candle. The broker-observer owns it.

See: [examples/position-core-thought.wat](examples/position-core-thought.wat),
[examples/position-full-thought.wat](examples/position-full-thought.wat)

### Broker-Observer

Thinks about action. "Given what I see, do I need to get out right now?"

Input: MarketPositionChain (position facts + market data + candle)
Output: Hold/Exit decision, paper proposals, exit proposals
Learns: gate reckoner (Hold/Exit from Grace/Violence outcomes)

The broker-observer's thought is a composition:
1. Position observer's facts (market extraction + lens facts)
2. Portfolio anxiety (avg paper age, avg time pressure, avg unrealized residue, active count)
3. Phase sequence (capacity-trimmed, most recent from the right)

One thought. One encode. One question: do I get out now?

See: [examples/broker-thought.wat](examples/broker-thought.wat)

## The Phase Sequence

### Current State

Each phase record has 5 facts: label atom + duration + range + move + volume.
No structural relations. Each record is isolated. The broker cannot see
"the highs are falling" because no record knows about the record before it.

### Proposed: Structural Deltas

Each phase record carries 10 facts:

**Own properties (4):**
- `rec-duration` (log) — how long this phase lasted
- `rec-move` (linear, signed) — net price movement as % of open
- `rec-range` (linear) — high-low range as % of average
- `rec-volume` (linear) — average volume during this phase

**Prior-bundle deltas (3):**
Relative to the phase immediately before me. The linkage.
- `prior-duration-delta` (linear, signed) — my duration vs previous phase's duration, as ratio
- `prior-move-delta` (linear, signed) — my move vs previous phase's move
- `prior-volume-delta` (linear, signed) — my volume vs previous phase's volume

**Prior-same-phase deltas (3):**
Relative to the last occurrence of this same phase type. The structural momentum.
- `same-move-delta` (linear, signed) — my move vs last same-type's move
- `same-duration-delta` (linear, signed) — my duration vs last same-type's duration
- `same-volume-delta` (linear, signed) — my volume vs last same-type's volume

The first record has no priors — own properties only. The second has
prior-bundle deltas but may not have prior-same-phase deltas. Each
subsequent record gets richer.

### Four Phase Types

| Label | Direction | Meaning |
|-------|-----------|---------|
| `phase-transition-up` | Up | Price moving from valley to peak |
| `phase-peak` | None | Price pausing at a high |
| `phase-transition-down` | Down | Price moving from peak to valley |
| `phase-valley` | None | Price pausing at a low |

The rhythm: move, pause, move, pause. The transitions carry direction
and magnitude. The pauses carry duration and range. The deltas carry
the trend of the trend.

### Why This Encodes "Three Lower Lows"

Three valleys, each with negative `same-move-delta`:
- Valley 1: no prior-same delta (first valley)
- Valley 2: `same-move-delta = -0.005` (slightly lower)
- Valley 3: `same-move-delta = -0.012` (much lower)

These appear in trigrams: `(valley → trans-up → peak)` where the
valley's `same-move-delta` is increasingly negative. The trigrams
encode the shape. The chain preserves that the decline progressed
in this order. The reckoner learns this region predicts Violence.

No rule. No boolean. The geometry encodes it as a direction with
scalar strength.

## Encoding: Chained Trigrams

### Why Not Sequential (Positional)

`(sequential A B C)` encodes as `bundle(permute(A,0), permute(B,1), permute(C,2))`.
Position 0, 1, 2 are fixed slots. "Peak at position 3" is a different
thought from "peak at position 7" even if the peak is identical. The
absolute position doesn't matter — the SHAPE matters. A pattern of
weakening rallies at the start of the history should look the same as
weakening rallies at the end.

### Why Chained Trigrams

A trigram is one full cycle: pause → move → pause.

```
trigram = bind(bind(phase_A, permute(phase_B, 1)), permute(phase_C, 2))
```

Internal order is preserved — "valley → transition-up → peak" differs
from "peak → transition-up → valley." The trigram IS the shape of one
cycle.

Trigrams are chained — each binds with the previous result:

```
chain = bind(bind(trigram_0, trigram_1), trigram_2)
```

The chain preserves the ORDER of cycles. The most recent trigram is on
the surface — one unbind to peel it off. Earlier cycles are deeper.
Natural recency bias. The reckoner doesn't decompose — it reads the
gestalt. Different rhythms produce different vectors. Similar rhythms
produce similar vectors.

The result is one vector. One thought. One slot in the broker's
outer bundle.

### Ngram Construction

From N phases, extract overlapping trigrams (windows of 3):

```
phases:   [valley, trans-up, peak, trans-down, valley, trans-up, peak]
trigrams: [v-up-p, up-p-down, p-down-v, down-v-up, v-up-p]  (5 trigrams)
chain:    bind(bind(bind(bind(t0, t1), t2), t3), t4)          (1 vector)
```

Each trigram is internally ordered (bind + permute). The chain is
ordered left to right. The output is one vector at D dimensions.

### Capacity

Each bind is a rotation in hyperspace. The signal holds for roughly
sqrt(D) binds before the compound rotation becomes quasi-random:

| Dimensions | sqrt(D) | Trigram Budget | Time Coverage |
|------------|---------|----------------|---------------|
| 4,096 | 64 | 64 trigrams | ~2-3 days |
| 10,000 | 100 | 100 trigrams | ~4-7 days |
| 20,000 | 141 | 141 trigrams | ~1-2 weeks |

The budget scales with the architecture, not the data. More dims,
longer memory. The trim is derived from `sqrt(dims)`.

Typical phase durations are 10-50 candles. One day (288 candles)
produces ~6-30 phases → ~4-28 trigrams. One week (2016 candles)
produces ~40-200 phases → ~38-198 trigrams.

At D=10,000: one week fits comfortably in most markets. Choppy
markets with very short phases may need trimming.

### Trim Strategy

If the trigram count exceeds `sqrt(dims)`:
1. Take the last `sqrt(dims)` trigrams from the right (most recent)
2. Chain them left to right
3. The oldest surviving trigram starts the chain
4. The most recent is on the surface

The trim is a safety bound. In practice, most weeks fit within budget.

### Broker-Observer's Outer Bundle

The outer bundle (the broker-observer's full thought) contains:
- Position facts: ~10-30 facts (lens dependent)
- Extracted market facts: ~10-20 (after anomaly filtering)
- Anxiety facts: 4 (avg age, avg pressure, avg unrealized, active count)
- Phase rhythm: 1 (the chained trigrams — one vector)

Total: ~25-55 facts + 1 rhythm = ~26-56 items in the outer bundle.
Well within Kanerva capacity.

## Migration

### Phase Record Encoding (`vocab/exit/phase.rs`)

`phase_series_thought` changes:
- Walk the history computing deltas (prior-bundle and prior-same-phase)
- Each record gets 4-10 facts (4 own + 0-3 prior-bundle + 0-3 prior-same)
- Trim to `sqrt(dims)` items from the right
- Return `ThoughtAST::Sequential(trimmed_items)`

### Lens (`domain/lens.rs`)

Remove `phase_series_thought` from Full lens. The lens produces
lens-specific interpretation facts. The sequence is not lens-specific.

### Broker Program (`programs/app/broker_program.rs`)

`broker_thought_ast` adds the sequence:
1. Start with position facts (from chain)
2. Add anxiety facts (portfolio state)
3. Add phase sequence (from `chain.candle.phase_history`, trimmed, with deltas)
4. Encode once. Predict once.

### PhaseRecord (`types/pivot.rs`)

No changes needed. The record already carries duration, close_open,
close_final, close_min, close_max, close_avg, volume_avg. The deltas
are computed at encoding time from adjacent records, not stored.

## Naming

The broker program becomes the broker-observer program. The broker
domain struct stays `Broker`. The file stays `broker_program.rs`.
The doc comment, the console diagnostics, and the telemetry namespace
change to `broker-observer`.

## Examples

Full worked examples with all scalars computed:

- [examples/market-observer-thought.wat](examples/market-observer-thought.wat) — 33 facts from momentum lens
- [examples/position-core-thought.wat](examples/position-core-thought.wat) — Core lens: 10 regime+time facts
- [examples/position-full-thought.wat](examples/position-full-thought.wat) — Full lens: 13 facts + phase scalars
- [examples/broker-thought.wat](examples/broker-thought.wat) — composed thought with trimmed sequence
- [examples/bullish-momentum.wat](examples/bullish-momentum.wat) — three rising valleys, strengthening rallies
- [examples/exhaustion-top.wat](examples/exhaustion-top.wat) — weakening rallies, longer pauses
- [examples/breakdown.wat](examples/breakdown.wat) — lower high after higher highs
- [examples/choppy-range.wat](examples/choppy-range.wat) — peaks and valleys at similar levels
- [examples/recovery-bottom.wat](examples/recovery-bottom.wat) — three rising valleys from a crash
