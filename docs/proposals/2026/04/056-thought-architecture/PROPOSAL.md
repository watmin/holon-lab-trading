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

**Current state:** The market observer encodes ~33 facts from the
CURRENT candle only. A photograph. The window sampler selects a
slice of history but the vocabulary runs on one candle. The
progression of indicators across the window is invisible.

**Proposed:** The market observer thinks in indicator rhythm. The
vocabulary runs on EACH candle in the window. Each candle produces
a fact bundle. The candle bundles form the sequence. Trigrams of
consecutive candle bundles → bigram-pairs → bundled rhythm. The
same encoding as the phase rhythm, applied to indicator evolution.

Each candle's facts can carry deltas relative to the previous
candle — "RSI moved +0.06", "volume dropped -0.3". The rhythm
encodes how the indicators evolved, not just where they are.

The window sampler determines how far back the observer looks.
The trim to sqrt(D) bigram-pairs applies. The most recent candles
survive. The budget determines the memory depth.

```
window: [candle_t-N, ..., candle_t-1, candle_t]
each candle → fact bundle (33 facts + deltas from previous candle)
trigrams: sliding window of 3 candle bundles
pairs: sliding window of 2 trigrams
rhythm: bundle(all pairs) → one vector
```

The market observer's thought IS the rhythm of the indicators
across its window. Not a snapshot — a movie.

See: [examples/market-observer-thought.wat](examples/market-observer-thought.wat)
(example shows current single-candle form — to be updated when
the indicator rhythm encoding is implemented)

### Regime Observer (Middleware)

Thinks about interpretation. "Which of the market observer's facts
are anomalous? What does the market look like through my lens?"

Input: MarketChain (market thought + anomaly + raw + candle)
Output: MarketRegimeChain (market data + regime-specific facts)
Learns: nothing. Pure middleware. Two lenses:

**Core lens**: regime facts + time facts. The consensus minimum.
Sees the character of the market (trending vs choppy, persistent vs
mean-reverting) and the time context (hour, day). Does not see phases.

**Full lens**: regime facts + time facts + phase current facts + phase
scalar summaries. Sees everything Core sees plus the current phase
state (label, direction, duration) and summary statistics of the
phase history (avg duration, avg range).

The regime observer extracts from the market anomaly: for each of
the ~33 market facts, cosine against the anomaly vector. Facts above
the noise floor pass through as `(bind (atom "market") fact)`. Facts
above noise floor in the raw pass as `(bind (atom "market-raw") fact)`.
This IS the regime observer's interpretation — which market thoughts
are anomalous right now.

The phase sequence is NOT a regime observer thought. It is a fact
about the market that flows on the candle. The broker-observer owns it.

See: [examples/regime-core-thought.wat](examples/regime-core-thought.wat),
[examples/regime-full-thought.wat](examples/regime-full-thought.wat)

### Broker-Observer

Thinks about action. "Given what I see, do I need to get out right now?"

Input: MarketRegimeChain (position facts + market data + candle)
Output: Hold/Exit decision, paper proposals, exit proposals
Learns: gate reckoner (Hold/Exit from Grace/Violence outcomes)

The broker-observer's thought is a composition:
1. Market indicator rhythms (from the market observer — one per indicator)
2. Regime observer's lens facts (regime, time, phase current, phase scalars)
3. Portfolio anxiety (age spread, pressure, unrealized P&L, track record)
4. Phase rhythm (bundled bigrams of trigrams — one vector)

One thought. One encode. One question: do I get out now?

See: [examples/broker-thought.wat](examples/broker-thought.wat)

## The Indicator Rhythm

### The Problem

The market observer sees one candle — a photograph. It encodes ~33
facts from the current candle's indicators. "RSI is 0.68." It does
not see "RSI was 0.55, 0.58, 0.62, 0.68." The progression is
invisible. The reckoner accumulates many single-candle snapshots
over time, but each individual thought is memoryless.

### The Solution: Per-Indicator Rhythm

Each indicator the lens selects gets its own rhythm vector. Two
variants based on the indicator's nature:

**`indicator-rhythm`** — for continuous values (RSI, ADX, ATR, etc.).
Thermometer encoding for values. Thermometer encoding for deltas.
The atom wraps the WHOLE rhythm, not each candle's fact (Beckman:
factor the constant out of the per-candle encoding).

**`circular-rhythm`** — for periodic values (hour, day-of-week).
Circular encoding, no delta. The wrap from 23→0 is handled by
circular similarity, not by computing a delta of -23.

```scheme
;; Continuous indicators: thermometer + delta
(define (indicator-rhythm window atom-name extract-fn
                          value-min value-max delta-range dims)
  (let facts
    (map-indexed (lambda (i candle)
      (let value (extract-fn candle))
      (if (= i 0)
        (thermometer value value-min value-max)
        (let prev (extract-fn (nth window (- i 1))))
        (bundle
          (thermometer value value-min value-max)
          (bind (atom "delta")
                (thermometer (- value prev)
                             (- 0 delta-range) delta-range)))))
    window))
  ;; trigrams → bigram-pairs → trim → bundle → bind atom
  ...
  (bind (atom atom-name) raw-rhythm))

;; Periodic indicators: circular, no delta
(define (circular-rhythm window atom-name extract-fn period dims)
  (let facts
    (map (lambda (candle)
      (circular (extract-fn candle) period))
    window))
  ...
  (bind (atom atom-name) raw-rhythm))
```

The atom appears ONCE — wrapping the final rhythm vector. Not N
times inside the per-candle facts. Two RSI rhythms (rising vs
falling) differ in their raw progression, not in the shared atom
structure. The atom identifies. The raw rhythm differentiates.

The delta IS the causality. "RSI rose 0.07 then rose 0.06" — the
deceleration is in the scalars. "RSI positive then negative" — the
reversal is a sign flip in the delta. The reckoner doesn't need a
rule. The direction on the sphere where delta flips sign IS reversal.

Bounds come from the indicator's nature — not magic numbers:
- RSI: `thermometer 0.0 100.0` — Wilder's definition
- Bollinger position: `thermometer 0.0 1.0` — by construction
- Hour: `circular 24.0` — by the clock
- Deltas: symmetric `thermometer -range +range` — from ScaleTracker

### The Market Observer's Thought

```scheme
(define (market-thought window dims)
  (bundle
    (indicator-rhythm window "rsi"       (lambda (c) (:rsi c))       0.0 100.0 10.0 dims)
    (indicator-rhythm window "macd-hist" (lambda (c) (:macd-hist c)) -50.0 50.0 20.0 dims)
    (indicator-rhythm window "bb-pos"    (lambda (c) (:bb-pos c))    0.0 1.0 0.2 dims)
    (indicator-rhythm window "adx"       (lambda (c) (:adx c))       0.0 100.0 10.0 dims)
    (indicator-rhythm window "atr-ratio" (lambda (c) (:atr-ratio c)) 0.0 0.05 0.01 dims)
    (indicator-rhythm window "obv-slope" (lambda (c) (:obv-slope c)) -2.0 2.0 1.0 dims)
    ;; ... one call per indicator the lens selects ...
    ))
```

One call per indicator. One rhythm per indicator. One bundle of all
rhythms. The lens determines which indicators. The window sampler
determines how far back. The dims determine the trim budget.

### Emergent Pairs

Each indicator rhythm is its own vector. MACD falling while RSI
rising → two rhythm vectors pointing in different directions. The
outer bundle holds both. The reckoner's discriminant learns: "when
the RSI rhythm points HERE and the MACD rhythm points THERE at the
same time, Violence follows." The meaningful pairs emerge from the
geometry. The noise subspace strips what doesn't matter.

We don't name the combinations. The reckoner discovers them.

### Coverage: Pairs → Trigrams → Candles

Overlapping windows mean pairs trace back further than their count.
100 pairs → 101 trigrams → 103 candles. Each pair shares a trigram
with the next. Each trigram shares two candles with the next.

| Pairs (budget) | Trigrams | Candles covered |
|----------------|----------|-----------------|
| 40 | 41 | 43 |
| 64 | 65 | 67 |
| 100 | 101 | 103 |
| 141 | 142 | 144 |

The window sampler selects 12 to 2016 candles (log-uniform,
median ~155, p25 ~43, p75 ~560). At D=10,000:

- Window of 43 candles → 40 pairs. Under budget. No trim.
- Window of 155 candles → 152 pairs. Trimmed to 100 → covers last 103 candles.
- Window of 560 candles → trimmed to 100 → covers last 103 candles.

The trim determines memory depth. Larger windows than sqrt(D)+2
candles see no benefit — the oldest candles fall off. The window
sampler may over-select but the trim caps the actual thought.

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

### Order Lives in the Deltas, Not the Container

The bundle is a set — it loses the order of pairs. "Pair-0 happened
before pair-4" is not expressed. But the ORDER is not lost. It moved
from the container to the content.

Each phase record carries `same-move-delta`: "I moved X% less than the
last phase of my type." This IS ordering. A weakening sequence of
rallies produces:

- Rally 1: no same-move-delta (first rally)
- Rally 2: `same-move-delta = -0.01` (weaker than rally 1)
- Rally 3: `same-move-delta = -0.02` (weaker than rally 2)

The delta on rally 3 says "I am weaker than my predecessor." It
doesn't need to know where rally 2 is in the bundle. The relation
is IN the scalar. The degradation is encoded on each record, not
between records.

The bundle sees "rallies with increasingly negative same-move-delta."
The composite direction drifts toward weakness. The reckoner reads
the drift. The ordering that the bundle lost is carried by the
deltas the bundle contains.

If the deltas were absent — if each phase only had its own properties —
the bundle truly couldn't distinguish "strong then weak" from "weak
then strong." The deltas make the distinction. They are the linkage.

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

**Outer (broker's thought bundle):** each rhythm is one vector.

- Market indicator rhythms: ~10-15 (one per lens indicator)
- Regime lens facts: ~10-15
- Extracted market facts: ~10-20 (after anomaly filtering)
- Anxiety facts: ~11 (age/pressure/unrealized spreads + track record)
- Phase rhythm: 1

Total: ~42-62 items at D=10,000 (budget: 100). Comfortable.
At D=4,096 (budget: 64): tight. The lens must be selective.

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
1. Start with regime facts (from chain)
2. Add anxiety facts (portfolio state)
3. Add phase sequence (from `chain.candle.phase_history`, trimmed, with deltas)
4. Encode once. Predict once.

### PhaseRecord (`types/pivot.rs`)

No changes needed. The record already carries duration, close_open,
close_final, close_min, close_max, close_avg, volume_avg. The deltas
are computed at encoding time from adjacent records, not stored.

## Noise Subspace: Every Thinker Strips Its Own Background

### The Principle

The `OnlineSubspace` learns the manifold of normal. The anomaly is
what the subspace cannot explain — the deviation from the background.
The surprise fingerprint unbinds the anomaly to find which components
drove the deviation. This is the memory layer's core contribution.

With rhythm-based thoughts, the subspace learns normal rhythm
bundles. When a rhythm bundle deviates — because some indicators
are evolving in unusual ways — the anomaly captures the deviation.
The subspace doesn't know about atoms or binds. It sees vectors.
A bundle of 15 rhythms is one vector. The subspace learns the
typical direction that vector points. When it deviates, the
deviation IS the signal.

### One Subspace Per Thinker

Each thinker produces its own thought vector. Each thinker has its
own noise subspace that learns what's normal for THAT thinker's
specific question.

**Market observer subspace:** learns normal market indicator rhythm
bundles. "The indicators usually evolve like THIS." The anomaly:
"today's indicator rhythms are unusual — RSI is doing something
it doesn't normally do." The reckoner predicts from the anomaly,
not the raw thought. It learns which deviations from normal predict
Up vs Down.

**Regime observer subspace:** learns normal regime rhythm bundles.
"The regime character usually evolves like THIS." The anomaly:
"the regime shifted — kama-er dropped while entropy spiked." The
regime observer strips its own background. What survives is the
regime shift, not the regime's usual state.

**Broker-observer subspace:** learns normal composed thought bundles
(market rhythms + regime rhythms + portfolio rhythms + phase rhythm).
"My full picture usually looks like THIS." The anomaly: "something
is unusual about the combination of market state + regime + my
portfolio + the phase rhythm." The gate reckoner predicts Hold/Exit
from the anomaly — what's unusual about the broker's full situation.

### The Surprise Fingerprint at Each Level

Because the thought is built from reversible VSA operations, the
anomaly can be decomposed. Unbind the anomalous component against
any indicator rhythm's atom to find that rhythm's contribution to
the deviation.

```scheme
;; After the market observer encodes and strips noise:
(let anomaly (anomalous-component subspace market-thought))

;; Which rhythm drove the anomaly?
(for-each indicator-name lens-indicators
  (let rhythm-vec (unbind anomaly (atom indicator-name)))
  (let surprise (norm rhythm-vec))
  ;; high surprise → this indicator's rhythm is anomalous
  )
```

The same unbinding technique from the DDoS domain. The same algebra.
Different vocabulary. The field is a rhythm instead of a packet field.
The surprise says "this indicator's evolution is unusual right now."

### Anomaly Filtering Between Thinkers

The regime observer currently filters market facts by cosining
them against the market observer's anomaly. With rhythms, this
becomes: cosine each market rhythm vector against the market
anomaly vector. Rhythms with high presence in the anomaly pass
through — they are what's unusual about the market right now.
Rhythms with low presence are the background — the noise subspace
absorbed them.

The broker-observer receives the filtered rhythms. Only the
anomalous market rhythms arrive. The regime rhythms come with
their own anomaly filtering (regime observer's subspace). The
broker's own subspace then strips what's normal about the
combination. What survives all three filters is the triple
anomaly — what's unusual about the market AND the regime AND
the portfolio AND the phase structure, all at once.

## Naming

The broker program becomes the broker-observer program. The broker
domain struct stays `Broker`. The file stays `broker_program.rs`.
The doc comment, the console diagnostics, and the telemetry namespace
change to `broker-observer`.

## Scalar Encoding: Thermometer

The rotation-based scalar encoding (`ScalarMode::Linear`) fails for
indicator rhythms. Small value differences produce tiny rotation angles
that bipolar thresholding destroys. `+0.07` and `-0.07` encode to
IDENTICAL vectors at `scale=1.0`. The sign — the direction of change —
is invisible.

**Thermometer encoding** fills dimensions proportionally to the value's
position in a range. Value in [min, max] → first `frac * D` dimensions
= +1, rest = -1. The cosine between two thermometer vectors is exact:

```
cosine(a, b) = 1.0 - 2.0 * |a - b| / (max - min)
```

Linear gradient. No rotation. No thresholding loss. Sign-preserving
for symmetric ranges.

Added to holon-rs as `ScalarMode::Thermometer { min, max }`. Third
scalar mode alongside `Linear` (rotation) and `Circular` (wrapping).

**Bounds come from the indicator's nature:**
- RSI: `Thermometer { min: 0.0, max: 100.0 }` — Wilder's definition
- Bollinger position: `Thermometer { min: 0.0, max: 1.0 }`
- ATR ratio: `Thermometer { min: 0.0, max: 0.05 }`
- Deltas: `Thermometer { min: -range, max: range }` — symmetric, from ScaleTracker

No magic numbers. The math defines the bounds. The ScaleTracker
learns them for deltas.

## Proof

### The Problem (measured)

Raw rhythm cosine between uptrend and downtrend windows: **0.96**.
Nearly identical. The shared structure (same atoms, same encoding
operations) dominates. Without the noise subspace, rhythm encoding
alone cannot separate market regimes.

### The Solution (measured)

Train an `OnlineSubspace(D=10000, k=32)` on 200 uptrend rhythm
windows (4 indicators, 50 candles each). Test against unseen
uptrends, downtrends, and choppy markets.

```
Residual separation:
  uptrend (familiar):   6.29
  downtrend (novel):    21.94   — 3.49x higher
  chop (novel):         39.57   — 6.29x higher

Anomaly cosine:
  raw rhythm:   uptrend vs downtrend = 0.9643
  after strip:  uptrend vs downtrend = 0.1223
```

The noise subspace learned what uptrend rhythms look like. It stripped
the shared background (0.96 → 0.12). What survived is the deviation —
the signal that separates regimes. Downtrend residual is 3.5x higher
than uptrend. Chop is 6.3x higher.

Four indicators. Fifty candles. One subspace. The full proposal calls
for ~15 market + ~10 regime + ~5 portfolio indicators. More dimensions
of variation = more for the subspace to learn from.

### Test files

- `tests/prove_rhythm_with_subspace.rs` — regime separation proof
- `tests/prove_indicator_rhythm.rs` — encoding property tests
- `tests/debug_rhythm.rs` — layer-by-layer introspection
- `tests/debug_thermometer.rs` — thermometer gradient verification
- `tests/debug_scalar.rs` — Linear encoding failure diagnosis

## Examples

Full worked examples:

- [examples/indicator-rhythm.wat](examples/indicator-rhythm.wat) — the generic function + RSI example expansion
- [examples/market-observer-thought.wat](examples/market-observer-thought.wat) — 15 indicator rhythms via the generic function
- [examples/regime-core-thought.wat](examples/regime-core-thought.wat) — 10 regime rhythms + market rhythms
- [examples/regime-full-thought.wat](examples/regime-full-thought.wat) — 13 regime+phase rhythms + market rhythms
- [examples/broker-thought.wat](examples/broker-thought.wat) — composed: market + regime + portfolio rhythms + phase rhythm
- [examples/bullish-momentum.wat](examples/bullish-momentum.wat) — three rising valleys, strengthening rallies
- [examples/exhaustion-top.wat](examples/exhaustion-top.wat) — weakening rallies, longer pauses
- [examples/breakdown.wat](examples/breakdown.wat) — lower high after higher highs
- [examples/choppy-range.wat](examples/choppy-range.wat) — peaks and valleys at similar levels
- [examples/recovery-bottom.wat](examples/recovery-bottom.wat) — three rising valleys from a crash
