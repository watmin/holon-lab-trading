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

## Encoding: Bundled Bigrams of Trigrams

### The Design Space

Four encoding modes exist in holon-rs:

| Mode | Order | Pattern Recognition | Problem |
|------|-------|--------------------|---------| 
| **Bundle** | None | Each item recoverable | "A then B" == "B then A" |
| **Positional** | Fixed slots | Position-dependent | Same shape at different offsets = different thought |
| **Chained** | Total ordering | Recent on surface | Same suffix + different prefix = different thought |
| **Ngram** | Local ordering | Offset-independent | ✓ |

**Positional** (what Sequential does now) fails because "peak at
position 3" differs from "peak at position 7." The shape should be
recognizable regardless of when it appeared.

**Chained** fails because different history prefixes rotate the final
vector into different orientations. The same recent pattern with
different early history is unrecognizable.

**Bundled ngrams** succeed: each ngram preserves local order via bind.
The ngrams are bundled — each one equally recoverable by cosine,
regardless of when it occurred. The same shape is recognizable at
any offset.

### Three Layers

**Layer 1 — Phase record.** One phase. 4-10 facts: own properties +
prior-bundle deltas + prior-same-phase deltas. Encoded as a bundle.
Produces one vector.

**Layer 2 — Trigram.** Three consecutive phase records. One full cycle:
pause → move → pause. Internally ordered via bind + permute.

```
trigram = bind(bind(encode(phase_A), permute(encode(phase_B), 1)),
              permute(encode(phase_C), 2))
```

"Valley → transition-up → peak" differs from "peak → transition-up →
valley." The trigram IS the shape of one cycle. Produces one vector.

**Layer 3 — Bigram of trigrams.** Two consecutive trigrams. "This cycle
then that cycle." Ordered via bind.

```
pair = bind(trigram_i, trigram_i+1)
```

"Exhaustion-cycle then panic-cycle" IS a specific direction in
hyperspace. Produces one vector.

**Layer 4 — Rhythm.** All bigram-pairs bundled. Unordered. Each pair
equally recoverable. The rhythm is the SET of all cycle-to-cycle
progressions.

```
rhythm = bundle(pair_0, pair_1, ..., pair_N)
```

One vector. One thought. One slot in the broker's outer bundle.

### Example: 9 Phases → 1 Rhythm Vector

```scheme
;; 9 phases from the labeler
phases:   [valley, trans-up, peak, trans-down, valley, trans-up, peak, trans-down, valley]

;; 7 trigrams (sliding window of 3)
tri-0: valley → trans-up → peak         ;; the rally cycle
tri-1: trans-up → peak → trans-down     ;; the top
tri-2: peak → trans-down → valley       ;; the selloff cycle
tri-3: trans-down → valley → trans-up   ;; the bottom
tri-4: valley → trans-up → peak         ;; another rally cycle
tri-5: trans-up → peak → trans-down     ;; another top
tri-6: peak → trans-down → valley       ;; another selloff

;; 6 bigram-pairs (sliding window of 2 trigrams)
pair-0: bind(tri-0, tri-1)   ;; rally THEN top
pair-1: bind(tri-1, tri-2)   ;; top THEN selloff
pair-2: bind(tri-2, tri-3)   ;; selloff THEN bottom
pair-3: bind(tri-3, tri-4)   ;; bottom THEN rally
pair-4: bind(tri-4, tri-5)   ;; rally THEN top (again)
pair-5: bind(tri-5, tri-6)   ;; top THEN selloff (again)

;; The rhythm — bundle all pairs
rhythm: bundle(pair-0, pair-1, pair-2, pair-3, pair-4, pair-5)
```

Pair-0 and pair-4 are both "rally then top." If the second rally was
weaker (smaller scalars in the phase deltas), the two pairs point in
similar-but-not-identical directions. They REINFORCE the common shape
in the bundle. The scalar differences create SPREAD around that
direction. The reckoner reads both the pattern and the drift.

### Why Familiar Shapes Stay Familiar

Bind is deterministic. The same two vectors always produce the same
result. A trigram of "valley(rising) → transition-up(strong) → peak"
produces the same vector whether it appears in January or July. A
bigram of "rally-cycle then top-cycle" produces the same vector
regardless of what happened before or after.

The bundle preserves each pair independently. Cosine against any
individual pair recovers it. The reckoner's discriminant learns:
"when pair(exhaustion-cycle, panic-cycle) is present in the rhythm
bundle, Violence follows." It doesn't matter WHEN that pair appeared
in the history. It matters that it's THERE.

Two different market histories that share the same cycle-to-cycle
transitions produce similar rhythm vectors. That IS the recognition.
The shape is the direction. The scalars carry the magnitude. The
reckoner discriminates.

### Capacity

Two separate Kanerva limits, both comfortable:

**Inner (rhythm bundle):** each bigram-pair is one item. Budget =
sqrt(D) pairs before interference.

| Dimensions | sqrt(D) | Pair Budget | Time Coverage |
|------------|---------|-------------|---------------|
| 4,096 | 64 | 64 pairs | ~2-3 days |
| 10,000 | 100 | 100 pairs | ~4-7 days |
| 20,000 | 141 | 141 pairs | ~1-2 weeks |

Typical: 1 day → 4-28 pairs. 1 week → 38-198 pairs. At D=10,000,
most weeks fit. Choppy markets may need trimming.

The budget scales with the architecture. More dims = longer memory.
The trim is derived from `sqrt(dims)`, not hardcoded.

**Outer (broker's thought bundle):** the rhythm is one vector.

- Position facts: ~10-30 (lens dependent)
- Extracted market facts: ~10-20 (after anomaly filtering)
- Anxiety facts: 4
- Phase rhythm: 1

Total: ~25-55 items. Well within sqrt(D).

**Bind operations inside trigrams and pairs cost ZERO capacity.**
Bind rotates — it doesn't consume bundle slots. Only the final
bundle of pairs counts against the Kanerva limit.

### Trim Strategy

If the bigram-pair count exceeds `sqrt(dims)`:
1. Take the last `sqrt(dims)` pairs from the right (most recent)
2. Bundle them
3. The oldest surviving pair is the earliest progression
4. The most recent is the latest

The trim is a safety bound. The budget scales with dims. Moving to
20,000 dims extends the memory from ~100 to ~141 pairs without
changing any code — just the dimension parameter.

## Migration

### Phase Rhythm Encoding (`vocab/exit/phase.rs`)

`phase_series_thought` replaced by `phase_rhythm`:
- Walk the history computing deltas (prior-bundle and prior-same-phase)
- Each record: bundle of 4-10 facts → encode → one vector
- Sliding window of 3 records → trigram (bind + permute) → one vector
- Sliding window of 2 trigrams → bigram-pair (bind) → one vector
- Bundle all pairs → trim to `sqrt(dims)` from the right if needed
- Return one `Vector` (not a ThoughtAST — the encoding is done here)

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
