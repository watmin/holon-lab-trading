# Thought Vector System — Vocabulary & Algebra Reference

Reference for the compositional symbolic reasoning system.
All composition happens in Rust at runtime using Holon primitives.

---

## 1. Type System

```
;; ─── TYPES ─────────────────────────────────────────────────────
;;
;; Indicator   — a measurable quantity (close, sma50, rsi, bb-width, ...)
;; Direction   — up | down | flat
;; Scale       — micro | short | major
;; Intensity   — low | medium | high
;; Zone        — a named threshold region (overbought, oversold, ...)
;; DayOfWeek   — monday | tuesday | ... | sunday
;; Session     — asian | european | us | off-hours
;; HourBlock   — h00 | h04 | h08 | h12 | h16 | h20  (4-hour buckets)
;; Period      — weekend | weekday
;; Fact        — a composed truth about the current state (a Vector)
;; Thought     — a bundle of Facts (the per-candle vector)
;; N           — natural number (candle count)
;; Stream      — ordered sequence of Vectors (one per candle)
;;
;; KEY PROPERTY: Fact is a Vector. Any primitive that returns Fact
;; can be used as input to other primitives that accept Fact.
;; This is what makes composition unlimited.
;;
;; SECOND KEY PROPERTY: Stream is a sequence of Vectors. Holon's
;; temporal primitives (segment, drift_rate, autocorrelate,
;; cross_correlate) operate on Streams natively. Indicator time
;; series become Streams by encoding each candle's indicator value.
```

---

## 2. Atoms Inventory (terminal symbols)

```
;; ─── INDICATORS (19) ──────────────────────────────────────────
close open high low volume
sma20 sma50 sma200
bb-upper bb-lower bb-width
rsi rsi-sma
macd-line macd-signal macd-hist
dmi-plus dmi-minus adx atr

;; ─── DERIVED INDICATORS (8) ─────────────────────────────────
;; Computed from candle OHLCV at the boolean gate layer.
;; Never encoded as vectors — only used as f64 inputs to
;; comparison/zone predicates.
prev-close prev-open prev-high prev-low   ;; previous candle values
candle-range                               ;; high - low
candle-body                                ;; |close - open|
upper-wick                                 ;; high - max(close, open)
lower-wick                                 ;; min(close, open) - low

;; ─── DIRECTIONS (3) ───────────────────────────────────────────
up down flat

;; ─── SCALES (3) ───────────────────────────────────────────────
micro short major

;; ─── INTENSITIES (3) ──────────────────────────────────────────
low medium high

;; ─── ZONES (13) ───────────────────────────────────────────────
overbought oversold neutral
above-midline below-midline                ;; RSI > 50 / RSI < 50
positive negative                          ;; MACD-line or hist > 0 / < 0
strong-trend weak-trend squeeze
middle-zone
large-range small-range                    ;; candle-range vs ATR

;; ─── DAYS OF WEEK (7) ────────────────────────────────────────
monday tuesday wednesday thursday friday saturday sunday

;; ─── SESSIONS (4) ────────────────────────────────────────────
;; Approximate UTC windows for crypto-relevant liquidity regimes:
;;   asian-session:    00:00–08:00 UTC
;;   european-session: 08:00–14:00 UTC
;;   us-session:       14:00–21:00 UTC
;;   off-hours:        21:00–00:00 UTC  (thin liquidity gap)
asian-session european-session us-session off-hours

;; ─── HOUR BLOCKS (6) ─────────────────────────────────────────
;; 4-hour buckets — aligns with crypto funding rate cycles
h00 h04 h08 h12 h16 h20

;; ─── PERIOD (2) ──────────────────────────────────────────────
weekend weekday

;; ─── MARKET HOLIDAYS (3) ────────────────────────────────────
;; Derived from candle timestamp via static calendar lookup.
;; True when major traditional markets are closed for a holiday.
;; US: NYE, MLK, Presidents, Good Friday, Memorial, July 4th,
;;     Labor Day, Thanksgiving+day after, Christmas
;; EU: Easter Monday, bank holidays, Boxing Day
;; Asia: Chinese New Year, Golden Week (JP), Diwali
us-holiday eu-holiday asia-holiday

;; ─── PREDICATES (17) ─────────────────────────────────────────
above below crosses-above crosses-below
touches bounces-off
trending at reversal continuation diverging since
at-day at-session at-hour at-period at-holiday

;; TOTAL: 84 atoms → 84 deterministic vectors from VectorManager
;; (derived indicators don't need atoms — they only provide f64
;; values to boolean predicates, never enter the vector space)
```

Each atom maps to exactly one deterministic vector via
`VectorManager::get_vector("atom-name")`. The vectors are
quasi-orthogonal by construction.

---

## 3. Composition Primitives (function signatures)

### 3.1 Comparison — binary predicates between indicators

```
above         : (Indicator, Indicator) → Fact
below         : (Indicator, Indicator) → Fact
crosses-above : (Indicator, Indicator) → Fact    ;; true iff prev: a < b, now: a >= b
crosses-below : (Indicator, Indicator) → Fact    ;; true iff prev: a > b, now: a <= b
touches       : (Indicator, Indicator) → Fact    ;; |a - b| < ε, didn't break through
bounces-off   : (Indicator, Indicator) → Fact    ;; approached, now leaving
```

#### Comparison Pairs (current + planned)

```
;; ─── Current (9 pairs) ──────────────────────────────────────
("close", "sma20"), ("close", "sma50"), ("close", "sma200"),
("close", "bb-upper"), ("close", "bb-lower"),
("sma20", "sma50"), ("sma50", "sma200"),
("macd-line", "macd-signal"),
("dmi-plus", "dmi-minus"),

;; ─── Planned: OHLC vs structure (10 pairs) ──────────────────
("open", "sma20"), ("open", "sma50"), ("open", "sma200"),
("open", "bb-upper"), ("open", "bb-lower"),
("high", "bb-upper"), ("low", "bb-lower"),
("high", "sma200"), ("low", "sma200"),
("rsi", "rsi-sma"),

;; ─── Planned: Cross-candle (5 pairs) ────────────────────────
;; Using derived prev-* indicators from candle_field()
("high", "prev-high"),       ;; higher high / lower high
("low", "prev-low"),         ;; higher low / lower low
("open", "prev-close"),      ;; gap up / gap down
("close", "prev-close"),     ;; up/down sequence
("close", "prev-open"),      ;; close vs previous body

;; ─── Planned: Intra-candle structure (8 pairs) ──────────────
("close", "open"),           ;; bullish / bearish candle
("close", "high"),           ;; closing strength (touches = closed at top)
("low", "close"),            ;; closing weakness (touches = closed at bottom)
("upper-wick", "candle-body"),  ;; wick dominance (rejection)
("lower-wick", "candle-body"),  ;; wick dominance (hammer)
("upper-wick", "lower-wick"),   ;; wick symmetry (candle balance)
("candle-range", "atr"),     ;; abnormal candle size
("candle-body", "candle-range"),;; body fill ratio (conviction)
```

#### Compositional Pattern Philosophy

Named TA patterns are NOT atoms — they emerge from co-occurring
primitive facts bundled in the thought vector. The journaler
discovers which combinations are predictive without naming them.

```
;; "Bearish engulfing" is just these facts being simultaneously true:
(below close open)              ;; current candle bearish
(above prev-close prev-open)    ;; previous candle bullish
(above high prev-high)          ;; wider up
(below low prev-low)            ;; wider down

;; "Inside bar" is:
(below high prev-high)          ;; didn't exceed prev high
(above low prev-low)            ;; didn't exceed prev low

;; "Doji" is:
(touches close open)            ;; open ≈ close

;; "Hammer" is:
(above lower-wick candle-body)  ;; lower wick > body
(at candle-body small-range)    ;; small body

;; "Gap up" is:
(above open prev-close)         ;; opened above previous close

;; "Shooting star" is:
(above upper-wick candle-body)  ;; upper wick > body
(below close open)              ;; bearish

;; Three consecutive bullish candles:
(above close open)              ;; current bullish
(since (above close open) 1)    ;; previous bullish
(since (above close open) 2)    ;; two ago bullish
```

The power: the journaler can discover patterns that have no name
in the TA literature, or discover that named patterns don't work.
The combinatorial space of co-occurring facts IS the pattern language.

### 3.2 Trend — direction, scale, and intensity of movement

```
trending      : (Indicator, Direction, Scale, Intensity) → Fact

;; Examples:
;;   (trending close up major high)       — strong rally
;;   (trending rsi down micro low)        — RSI barely dipping
;;   (trending bb-width up short medium)  — vol expanding moderately
```

### 3.3 Zone — indicator within a threshold region

```
at            : (Indicator, Zone) → Fact

;; Examples:
;;   (at rsi overbought)        — RSI > 70
;;   (at rsi oversold)          — RSI < 30
;;   (at adx strong-trend)      — ADX > 25
;;   (at bb-width squeeze)      — BB width < threshold
;;   (at close middle-zone)     — close between BB bands
;;   (at rsi above-midline)      — RSI > 50 (bullish territory)
;;   (at rsi below-midline)      — RSI < 50 (bearish territory)
;;   (at macd-line positive)     — MACD line > 0 (bullish momentum)
;;   (at macd-line negative)     — MACD line < 0 (bearish momentum)
;;   (at macd-hist positive)     — histogram > 0
;;   (at macd-hist negative)     — histogram < 0
;;   (at candle-range large-range)  — candle-range > 1.5 * ATR (planned)
;;   (at candle-range small-range)  — candle-range < 0.5 * ATR (planned)
;;   (at volume high)           — volume spike (planned, needs vol SMA)
```

### 3.4 State Transitions — direction changes

```
reversal      : (Indicator, Direction, Scale) → Fact

;; Direction just changed. Detected via segment() on indicator stream.
;;
;;   (reversal close up micro)   — micro pivot: was falling, now rising
;;   (reversal close down major) — major top/trend reversal

continuation  : (Indicator, Direction, Scale) → Fact

;; Trend persists without reversal at this scale.
;;
;;   (continuation close up major)  — major uptrend intact
```

### 3.5 Divergence — indicators moving in opposite directions

```
diverging     : (Indicator, Direction, Indicator, Direction) → Fact

;; Examples:
;;   (diverging close up rsi down)       — bearish divergence
;;   (diverging close down macd-hist up) — bullish hidden divergence
```

### 3.6 Temporal — binding facts with recency

```
since         : (Fact, N) → Fact

;; Examples:
;;   (since (crosses-above sma50 sma200) 3)  — golden cross 3 candles ago
;;   (since (reversal close up major) 12)    — major reversal 12 candles ago
```

#### Structural vs Chronological Lookback

The current implementation uses chronological lookback (N = candles
ago) with a hardcoded max of 12. This is a magic number.

**Problem**: A human looking at a chart doesn't count candles. They
see structure — "the cross happened before that last pullback" or
"since the last pivot." Their temporal reference frame is defined
by market structure, not clock time.

**Planned: Segment-anchored lookback (Option B)**

Replace chronological N with structural N — "how many segments ago"
at the relevant scale. Use `segment()` on price to find changepoints,
then measure event distance in segment boundaries rather than candles.

```
;; Chronological (current — fragile):
(since (crosses-above sma50 sma200) 15)  ;; 15 candles ago — arbitrary

;; Structural (planned — adaptive):
(since (crosses-above sma50 sma200) 1)   ;; within current segment
(since (crosses-above sma50 sma200) 2)   ;; one pivot back
```

How this works:
1. Run segment() on close (or relevant indicator) at each scale
2. Get segment boundaries as candle indices
3. When scanning for temporal echoes, instead of binding with
   position_vector(candle_distance), bind with
   position_vector(segment_distance)
4. A cross 30 candles ago but within the current segment → distance 1
   A cross 5 candles ago but across a pivot → distance 2

Properties:
- Lookback adapts to market speed (fast market = more pivots = shorter
  lookback per segment; slow market = fewer pivots = longer lookback)
- No magic max_lookback — scan the full viewport (48 candles), encode
  structural distance for each hit
- Segment count is more stable than candle count (1-3 segments covers
  "recent context" regardless of market regime)
- Matches human perception: events are anchored to "before/after that
  reversal" not "N bars ago"

**Implementation note**: This is a refinement, not a rewrite. The
current `fact_since()` binding stays the same — only the N changes
from candle count to segment count. The `eval_temporal()` function
needs access to segment boundaries from the trend detection pass.

### 3.7 Clock — cyclical time context

```
at-day     : (DayOfWeek) → Fact
at-session : (Session)   → Fact
at-hour    : (HourBlock) → Fact
at-period  : (Period)    → Fact

;; All four emitted every candle. Derived from candle timestamp.
;; The journaler discovers which granularity discriminates.
;;
;; VSA encoding — simple binary bind:
;;   (at-day sunday)           → bind(at-day, sunday)
;;   (at-session off-hours)    → bind(at-session, off-hours)
;;   (at-hour h20)             → bind(at-hour, h20)
;;   (at-period weekend)       → bind(at-period, weekend)
;;
;; Examples of emergent temporal-TA correlations the journaler
;; can discover through superposition in the thought vector:
;;   (and (at-day sunday) (at-session off-hours) (rsi-oversold))
;;   (and (at-period weekend) (trending close up short medium))
;;   (and (at-session us-session) (crosses-above close sma200))
;;
;; We don't explicitly compose temporal-TA pairs. Both fact types
;; are bundled into the same thought vector, so correlations
;; between time and TA patterns emerge in the prototypes naturally.
```

### 3.8 Market Holidays — institutional flow awareness

```
at-holiday : (MarketStatus) → Fact

;; Derived from candle timestamp via static calendar lookup.
;; True when major traditional equity markets are closed.
;; Implementation: HashMap<NaiveDate, Vec<&str>> built at startup,
;; pre-computed for all years in the data range (2019–2026).
;;
;;   (at-holiday us-holiday)    → bind(at-holiday, us-holiday)
;;   (at-holiday eu-holiday)    → bind(at-holiday, eu-holiday)
;;   (at-holiday asia-holiday)  → bind(at-holiday, asia-holiday)
;;
;; Emergent patterns the journaler can discover:
;;   (and (at-holiday us-holiday) (at-day friday))
;;     → long weekend, thin liquidity for days
;;   (and (at-holiday asia-holiday) (at-session asian-session))
;;     → Asian institutional flow absent
;;   (and (at-holiday us-holiday) (at-holiday eu-holiday))
;;     → global holiday (Christmas), minimal institutional activity
```

### 3.9 Top-level composition

```
and           : (Fact, Fact, ...) → Thought

;; Superposition of all true facts for this candle.
;; Only evaluated-true facts are included.
```

---

## 4. VSA Encoding Rules

How each S-expression maps to Holon algebra.

### 4.1 Core rules

```
;; RULE 1: Binary predicate
;;   (pred a b) → bind(V("pred"), bind(V("a"), V("b")))
;;
;; RULE 2: Unary predicate
;;   (pred a) → bind(V("pred"), V("a"))
;;
;; RULE 3: N-ary predicate (left-fold bind)
;;   (pred a b c)     → bind(V("pred"), bind(V("a"), bind(V("b"), V("c"))))
;;   (pred a b c d)   → bind(V("pred"), bind(V("a"), bind(V("b"), bind(V("c"), V("d")))))
;;
;; RULE 4: Composition (and)
;;   (and f₁ f₂ ... fₙ) → bundle([f₁, f₂, ..., fₙ])
;;
;; RULE 5: Temporal binding
;;   (since fact N) → bind(fact_vec, position_vector(N))

;; WHY THIS WORKS:
;; - bind is self-inverse: unbind(bind(A,B), A) recovers B
;; - bind produces vectors quasi-orthogonal to inputs
;; - bundle preserves similarity to all inputs
;; - Same atoms + same structure = same vector (deterministic)
;; - Different structure = different vector (quasi-orthogonal)
;; - (above close sma200) ≠ (above sma200 close) — order matters via bind
;; - (above close sma200) ≠ (below close sma200) — different predicate atom
```

### 4.2 Concrete encoding examples

```
(above close sma200)
  → bind(V("above"), bind(V("close"), V("sma200")))

(trending close up major high)
  → bind(V("trending"), bind(V("close"), bind(V("up"), bind(V("major"), V("high")))))

(at rsi overbought)
  → bind(V("at"), bind(V("rsi"), V("overbought")))

(crosses-above sma50 sma200)
  → bind(V("crosses-above"), bind(V("sma50"), V("sma200")))

(since (crosses-above sma50 sma200) 3)
  → bind(bind(V("crosses-above"), bind(V("sma50"), V("sma200"))), pos_vec(3))

(diverging close up rsi down)
  → bind(V("diverging"), bind(V("close"), bind(V("up"), bind(V("rsi"), V("down")))))

(and fact₁ fact₂ fact₃)
  → bundle([fact₁_vec, fact₂_vec, fact₃_vec])
```

---

## 5. Extended Holon Algebra — Primitives Beyond bind/bundle

The thought system can use the full Holon algebra, not just
bind and bundle. This section maps each relevant primitive to
its role in the thought system.

### 5.1 Stream Operations — trend and pivot detection

These operate on `Stream` (ordered sequences of vectors). An indicator
time series becomes a stream by encoding each candle's value.

```
segment(stream, window, threshold, method) → Vec<usize>
  Detects changepoints — where the stream's character shifts.
  Returns indices where new segments begin.

  USE: Pivot detection. This IS the reversal primitive.
    - Encode each candle's close (or RSI, etc.) as a vector
    - segment() finds where the trend breaks
    - SegmentMethod::Diff — consecutive dissimilarity exceeds threshold
    - SegmentMethod::Prototype — deviation from running prototype

  SCALES via window parameter:
    - micro:  window = 3-5   (minor pivots, noise-level turns)
    - short:  window = 8-12  (swing-level reversals)
    - major:  window = 20-48 (trend-level reversals)

  OUTPUT feeds into:
    - (reversal indicator direction scale)
    - (continuation indicator direction scale)

drift_rate(stream, window) → Vec<f64>
  Rate of change of similarity along the stream.
  High drift = fast movement. Low drift = consolidation.

  USE: Trend intensity measurement. This IS the intensity primitive.
    - low:    drift < threshold_low
    - medium: threshold_low <= drift < threshold_high
    - high:   drift >= threshold_high

  OUTPUT feeds into:
    - The Intensity argument of (trending indicator direction scale intensity)

autocorrelate(stream, max_lag) → Vec<f64>
  Self-similarity at various lags. Detects periodicity.

  USE: Identify cyclical patterns in indicator behavior.
    - High autocorrelation at lag N = indicator repeats every N candles
    - Could feed a new predicate: (periodic indicator N)

cross_correlate(stream_a, stream_b, max_lag) → Vec<f64>
  Similarity between two indicator streams at various offsets.

  USE: Lead/lag detection between indicators.
    - If close leads RSI by 3 candles, peak correlation at lag 3
    - Could feed: (leads indicator_a indicator_b N)
```

### 5.2 Resonance — confirmation between facts

```
resonance(vec_a, vec_b) → Vector
  Keeps only dimensions where both vectors agree.
  Zero where they disagree.

  USE: "Confirmation" — two facts mutually reinforce each other.
    - resonance(trend_fact, momentum_fact)
    - Strong resonance = facts are telling the same story
    - Weak resonance = conflicting signals

  NEW PRIMITIVE:
    confirms  : (Fact, Fact) → Fact
    (confirms (trending close up short medium) (above macd-hist 0))
      → resonance(trend_vec, macd_vec)

  WHY: Unlike bundle (which blurs facts together), resonance
  extracts only what they AGREE on. This is a much sharper
  signal for confirmation.
```

### 5.3 Analogy — relational composition

```
analogy(a, b, c) → Vector
  A : B :: C : ?
  Computes c + difference(b, a)

  USE: NOT for correction (that failed — load-bearing path).
  Instead, for relational transfer between market contexts.

  EXAMPLE: "What does a golden cross mean in a downtrend?"
    analogy(uptrend_context, golden_cross_in_uptrend, downtrend_context)
    → what golden cross "means" in a downtrend

  NEW PRIMITIVE:
    in-context-of : (Fact, Fact, Fact) → Fact
    (in-context-of base_context known_fact new_context)
      → analogy(base_context, known_fact, new_context)

  WHY: analogy degenerates when inputs converge (why it failed
  for correction — buy/sell protos converge). But for composition,
  the inputs are STRUCTURALLY different atoms, so convergence
  doesn't occur. Safe to use here.
```

### 5.4 Attend — selective focus

```
attend(query, memory, strength, mode) → Vector
  Soft/hard attention. Modes:
    Hard    — resonance (binary mask)
    Soft    — tanh-weighted blending
    Amplify — boost agreeing dimensions

  USE: Focus a thought on specific aspects.
    - attend(thought, trend_subspace, 2.0, Amplify)
      → amplify trend-related dimensions in the thought
    - attend(thought, momentum_atoms, 1.0, Hard)
      → extract only momentum-related components

  NEW PRIMITIVE:
    focus : (Thought, Fact) → Thought
    (focus full_thought (trending close up major high))
      → attend(full_thought, trend_fact, strength, mode)

  WHY: A thought vector bundles ALL true facts. Sometimes we
  want to ask "what does this thought say about momentum?"
  Attend extracts that specific facet.
```

### 5.5 Project / Reject — subspace isolation

```
project(vec, subspace, orthogonalize) → Vector
  Project onto subspace defined by reference vectors.

reject(vec, subspace, orthogonalize) → Vector
  Orthogonal complement — what's NOT in the subspace.

  USE: Decompose a thought into components.
    - project(thought, [trend_facts...]) → trend component
    - reject(thought, [trend_facts...])  → everything except trend

  This enables multi-faceted analysis:
    - What does the thought say about trend? (project onto trend atoms)
    - What remains after removing trend? (reject trend atoms)
    - Compare the projected components across candles.

  NEW PRIMITIVES:
    within   : (Thought, Fact...) → Thought   ;; project
    without  : (Thought, Fact...) → Thought   ;; reject
```

### 5.6 Conditional Bind — gated composition

```
conditional_bind(vec_a, vec_b, gate, mode) → Vector
  Bind only where gate passes:
    Positive — gate > 0
    Negative — gate < 0
    NonZero  — gate ≠ 0

  USE: Conditionally compose facts based on another fact.
    - Only bind momentum info where trend info is positive.
    - conditional_bind(rsi_fact, trend_fact, trend_gate, Positive)

  NEW PRIMITIVE:
    when : (Fact, Fact, Fact) → Fact
    (when condition consequence gate_vector)
      → conditional_bind(consequence, condition, gate_vector, Positive)

  WHY: Sometimes a fact is only meaningful in a specific context.
  E.g., RSI overbought matters differently in uptrend vs downtrend.
```

### 5.7 Weighted Bundle — confidence-weighted composition

```
weighted_bundle(vectors, weights) → Vector
  Superposition with explicit per-vector weights.

  USE: Weight facts by confidence or recency.
    - Recent facts get higher weight than stale ones
    - High-intensity trends weighted more than low-intensity
    - Zone facts weighted by how deep into the zone

  REPLACES: flat bundle in Rule 4 when we have confidence info.

  VARIANT of 'and':
    and-weighted : (Fact, weight, Fact, weight, ...) → Thought
      → weighted_bundle([f₁, f₂, ...], [w₁, w₂, ...])
```

### 5.8 Similarity Profile — structural comparison

```
similarity_profile(vec_a, vec_b) → Vector
  Per-dimension agreement: +1 where they agree, -1 where they
  disagree, 0 where either is zero.

  USE: Compare two thoughts structurally.
    - similarity_profile(thought_t, thought_t-1)
    - The RESULT is itself a vector — can be bundled, compared, etc.
    - A "change vector" between consecutive candle thoughts.

  NEW PRIMITIVE:
    diff : (Thought, Thought) → Fact
    (diff thought_now thought_prev)
      → similarity_profile(thought_now, thought_prev)

  WHY: difference() gives the algebraic delta. similarity_profile()
  gives the structural agreement map. Both are useful but different.
```

### 5.9 Cleanup / Invert — debug and interpretation

```
cleanup(noisy, codebook) → Option<(usize, f64)>
  Best match in codebook.

invert(vec, codebook, top_k, threshold) → Vec<(usize, f64)>
  All codebook entries above threshold, ranked.

  USE: Debug interface for thought vectors.
    - Build a codebook of ALL possible fact vectors
    - Given a thought, invert() → ranked list of active facts
    - This IS the S-expression debug readout

  EXAMPLE:
    thought_vec = bundle([
      (above close sma200),
      (at rsi overbought),
      (trending close up short medium)
    ])

    invert(thought_vec, all_fact_codebook, 10, 0.1) →
      [(idx_above_close_sma200, 0.82),
       (idx_at_rsi_overbought, 0.78),
       (idx_trending_close_up_short_medium, 0.75),
       ...]

  The top similarities decode the thought back into readable S-expressions.
```

### 5.10 Coherence — signal clarity measurement

```
coherence(vectors) → f64
  Mean pairwise cosine similarity.

  USE: Measure how "together" the active facts are.
    - High coherence = market signals agree → high confidence
    - Low coherence = mixed signals → low confidence / uncertainty

  This could feed into the meta-orchestrator:
    - thought_coherence = coherence(active_fact_vectors)
    - High coherence → trust the thought prediction
    - Low coherence → discount it or trigger straddle

  Also useful for comparing visual vs thought coherence.
```

### 5.11 Entropy — thought complexity

```
entropy(vec) → f64
  Normalized entropy of {+1, -1, 0} distribution.

  USE: Measure thought vector quality.
    - Low entropy = thought is dominated by few facts (sparse, clear)
    - High entropy = many competing facts (dense, ambiguous)

  Unlike complexity() which failed for pixel encoding (uniform
  density), thought vectors have genuinely varying density because
  different candles trigger different numbers of facts.
```

### 5.12 Sparsify — focused thoughts

```
sparsify(vec, k) → Vector
  Keep only top k dimensions by absolute value.

  USE: Focus a thought vector on its strongest components.
    - sparsify(thought, k) → the k most decisive dimensions
    - Compare: full thought similarity vs sparse thought similarity
    - If they diverge, the thought is spread thin across many facts

  Could enable "strong conviction" thoughts where only the
  clearest signals survive.
```

### 5.13 Power — fractional relationships

```
power(vec, exponent) → Vector
  Scalar power of a vector.

  USE: Partial/graduated relationships.
    - power(fact, 0.5) = "half-strength" version of a fact
    - power(fact, 2.0) = "double-strength" version (for emphasis)
    - Useful when a zone boundary is approached but not crossed:
      how "overbought" is RSI at 68 vs 75 vs 85?

  VARIANT of 'at' with graduated strength:
    approaching : (Indicator, Zone, Intensity) → Fact
    Where intensity maps to a power exponent.
```

### 5.14 Permute — positional encoding alternative

```
permute(vec, k) → Vector
  Circular shift by k positions.

  USE: Alternative to position_vector for temporal encoding.
    - permute(fact, -3) = "this fact, 3 candles ago"
    - Cheaper than bind with position_vector
    - Self-inverse: permute(permute(v, k), -k) = v

  TRADE-OFF vs position_vector binding:
    - permute: preserves more structure, fewer quasi-orthogonal
    - bind with pos_vec: fully quasi-orthogonal, more robust
    - Experiment to decide which works better for 'since'
```

---

## 6. Derived / Composite Predicates

Built from the primitives above. These are common TA patterns
expressed as S-expressions.

```lisp
;; ─── MOVING AVERAGE PATTERNS ──────────────────────────────────

golden-cross     ≡ (crosses-above sma50 sma200)
death-cross      ≡ (crosses-below sma50 sma200)
price-above-200  ≡ (above close sma200)
price-below-200  ≡ (below close sma200)
ma-stack-bull    ≡ (and (above close sma20) (above sma20 sma50) (above sma50 sma200))
ma-stack-bear    ≡ (and (below close sma20) (below sma20 sma50) (below sma50 sma200))

;; ─── BOLLINGER BAND PATTERNS ──────────────────────────────────

bb-squeeze       ≡ (at bb-width squeeze)
bb-bulge         ≡ (and (trending bb-upper up short medium) (trending bb-lower down short medium))
bb-ride-upper    ≡ (touches close bb-upper)
bb-ride-lower    ≡ (touches close bb-lower)
bb-rejection     ≡ (bounces-off close bb-upper)
bb-support       ≡ (bounces-off close bb-lower)

;; ─── RSI PATTERNS ─────────────────────────────────────────────

rsi-overbought   ≡ (at rsi overbought)
rsi-oversold     ≡ (at rsi oversold)
rsi-bull-cross   ≡ (crosses-above rsi rsi-sma)
rsi-bear-cross   ≡ (crosses-below rsi rsi-sma)
rsi-bear-div     ≡ (diverging close up rsi down)
rsi-bull-div     ≡ (diverging close down rsi up)

;; ─── MACD PATTERNS ────────────────────────────────────────────

macd-bull-cross  ≡ (crosses-above macd-line macd-signal)
macd-bear-cross  ≡ (crosses-below macd-line macd-signal)
macd-bull-div    ≡ (diverging close down macd-hist up)
macd-bear-div    ≡ (diverging close up macd-hist down)

;; ─── TREND PATTERNS ───────────────────────────────────────────

strong-uptrend   ≡ (and (trending close up major high) (at adx strong-trend))
strong-downtrend ≡ (and (trending close down major high) (at adx strong-trend))
trend-weakening  ≡ (and (trending close up major low) (trending adx down short medium))
trend-exhaustion ≡ (and (at rsi overbought) (trending adx down micro low))

;; ─── CONFIRMATION PATTERNS ────────────────────────────────────

;; Using resonance:
confirmed-breakout ≡ (confirms
                       (above close bb-upper)
                       (trending volume up short high))

;; Using analogy for relational transfer:
;;   "golden cross in THIS market context"
contextualized   ≡ (in-context-of current-regime golden-cross reference-regime)
```

---

## 7. Full Candle Thought — Example

```lisp
;; A candle where price is rallying above key MAs, RSI is getting
;; hot, MACD just crossed bullish 3 candles ago, and vol is rising.

(and
  (above close sma200)
  (above close sma50)
  (above sma50 sma200)
  (at rsi overbought)
  (trending close up short medium)
  (continuation close up major)
  (since (crosses-above macd-line macd-signal) 3)
  (trending volume up short high)
  (diverging close up rsi down))
```

VSA encoding of this thought:

```
fact₁ = bind(V("above"), bind(V("close"), V("sma200")))
fact₂ = bind(V("above"), bind(V("close"), V("sma50")))
fact₃ = bind(V("above"), bind(V("sma50"), V("sma200")))
fact₄ = bind(V("at"), bind(V("rsi"), V("overbought")))
fact₅ = bind(V("trending"), bind(V("close"), bind(V("up"), bind(V("short"), V("medium")))))
fact₆ = bind(V("continuation"), bind(V("close"), bind(V("up"), V("major"))))
fact₇ = bind(bind(V("crosses-above"), bind(V("macd-line"), V("macd-signal"))), pos_vec(3))
fact₈ = bind(V("trending"), bind(V("volume"), bind(V("up"), bind(V("short"), V("high")))))
fact₉ = bind(V("diverging"), bind(V("close"), bind(V("up"), bind(V("rsi"), V("down")))))

thought = bundle([fact₁, fact₂, fact₃, fact₄, fact₅, fact₆, fact₇, fact₈, fact₉])
```

---

## 8. Available Candle Fields (from db.rs)

These are the raw indicator values available per candle:

```
close, open, high, low, volume
sma20, sma50, sma200
bb_upper, bb_lower     (bb_width = bb_upper - bb_lower)
rsi                    (rsi_sma = TODO: add to DB or compute in Rust)
macd_line, macd_signal, macd_hist
dmi_plus, dmi_minus, adx
atr_r
```

---

## 9. Condition Detection — How Facts Are Evaluated

Each predicate requires runtime condition evaluation against the
candle window (48 candles). This section describes the detection
logic.

### 9.1 Comparison predicates

```
above(a, b):          candle[now].a > candle[now].b
below(a, b):          candle[now].a < candle[now].b
crosses-above(a, b):  candle[now-1].a < candle[now-1].b AND candle[now].a >= candle[now].b
crosses-below(a, b):  candle[now-1].a > candle[now-1].b AND candle[now].a <= candle[now].b
touches(a, b):        |candle[now].a - candle[now].b| < ε * atr AND no crossover
bounces-off(a, b):    touches(a,b) at t-1 AND now moving away
```

### 9.2 Trend detection (via segment + drift_rate)

```
1. Encode each indicator's values as a vector stream:
   stream[t] = scalar_encode(candle[t].indicator)

2. Run segment(stream, window, threshold, SegmentMethod::Diff)
   to find changepoints (pivot indices).

3. Determine direction from last segment:
   direction = if stream[now] > stream[segment_start] then Up else Down

4. Determine intensity from drift_rate(stream, window):
   low/medium/high = binned drift value

5. Scale from window parameter:
   micro=3-5, short=8-12, major=20-48
```

### 9.3 Reversal / Continuation

```
reversal(indicator, direction, scale):
  The MOST RECENT segment boundary at this scale changed the
  direction. I.e., the segment before the current one went
  the other way.

continuation(indicator, direction, scale):
  No segment boundary at this scale within recent window.
  The current direction has persisted.
```

### 9.4 Zone membership

```
at(rsi, overbought):    rsi > 70
at(rsi, oversold):      rsi < 30
at(rsi, neutral):       30 <= rsi <= 70
at(rsi, above-midline): rsi > 50
at(rsi, below-midline): rsi < 50
at(macd-line, positive): macd_line > 0
at(macd-line, negative): macd_line < 0
at(macd-hist, positive): macd_hist > 0
at(macd-hist, negative): macd_hist < 0
at(adx, strong-trend):  adx > 25
at(adx, weak-trend):    adx < 20
at(bb-width, squeeze):  bb_width < squeeze_threshold (e.g., < 0.5 * avg bb_width)
at(close, middle-zone): close between bb_lower and bb_upper
```

### 9.5 Divergence

```
diverging(a, dir_a, b, dir_b):
  trending(a, dir_a, short, *) AND trending(b, dir_b, short, *)
  AND dir_a ≠ dir_b
```

### 9.6 Temporal (since)

```
since(fact, N):
  Evaluate fact at candle[now - N]. If true, bind the
  fact vector with position_vector(N).

  Iterate N = 1..max_lookback, encoding each hit.
  Bundle all temporal echoes into the thought.

Current: max_lookback = 12 (hardcoded), N = candle distance.

Planned: max_lookback = viewport width (48), N = segment distance.
  1. Scan full viewport for event occurrences
  2. For each hit, compute segment_distance = number of segment
     boundaries between the event candle and now
  3. Bind with position_vector(segment_distance)
  See section 3.6 "Structural vs Chronological Lookback" for
  rationale and details.
```

---

## 10. Holon Primitive ↔ Thought System Role Map

Quick reference: which Holon primitive serves which purpose.

```
COMPOSITION:
  bind             → encode S-expressions (predicate + arguments)
  bundle           → combine facts into thoughts (flat 'and')
  weighted_bundle  → combine facts with confidence weighting
  conditional_bind → compose facts only when a gate holds
  permute          → alternative temporal encoding for 'since'

DETECTION:
  segment          → pivot/reversal detection at multiple scales
  drift_rate       → trend intensity measurement
  autocorrelate    → periodicity detection
  cross_correlate  → lead/lag between indicators

ENRICHMENT:
  resonance        → confirmation (shared agreement between facts)
  analogy          → relational transfer between contexts
  attend           → focus thought on specific aspect
  project          → extract subspace component of thought
  reject           → remove subspace component from thought
  power            → graduated/partial fact strength
  sparsify         → distill thought to strongest signals

ANALYSIS:
  coherence        → signal clarity (how much do facts agree)
  entropy          → thought complexity (sparse vs dense)
  complexity       → structural density (useful now — non-uniform)
  similarity_profile → structural delta between thoughts

DEBUG:
  cleanup          → best codebook match for a thought
  invert           → decode thought → ranked list of active facts
```

---

## 11. Open Questions (to resolve experimentally)

1. **segment() parameters**: What window sizes and thresholds
   produce useful pivot detection at each scale? Start with
   micro=5, short=10, major=30 and tune.

2. **Scalar encoding for streams**: How to encode indicator values
   as vectors for segment/drift_rate? Options:
   - `ScalarEncoder::encode_log(value)` for price-like indicators
   - `ScalarEncoder::encode(value, Linear { scale })` for bounded (RSI)
   - Bind the scalar encoding with the indicator atom

3. **permute vs position_vector for 'since'**: Which preserves
   more useful structure? permute is cheaper but less orthogonal.

4. **weighted_bundle weights**: How to set fact weights?
   - Uniform (current plan)
   - By recency (recent facts weighted higher)
   - By intensity (high-intensity trends weighted more)
   - By zone depth (how deep into overbought)

5. **Confirmation via resonance threshold**: What cosine threshold
   constitutes "confirmation" vs noise?

6. **RSI SMA**: Compute in Rust from the RSI values in the candle
   window, or add to the Python preprocessing pipeline?

---

## 12. Deferred Vocabulary Extensions

Concepts identified as valuable but deferred to keep initial
scope focused. The visual system covers some of these natively.

### 12.1 Dynamic Support / Resistance

The current vocabulary detects bounces off NAMED levels (SMAs, BB
bands). It does NOT detect data-derived horizontal levels where
price has reversed multiple times.

A trader looking at a chart thinks: "it was going up a few times,
looks like it hit some kind of resistance." That's a dynamic level
discovered from local highs clustering at a similar price.

**Why defer**: Different kind of detection (data-derived vs
indicator-derived). The visual system captures this innately via
pixel patterns. Adds implementation complexity.

**When to add**: After the core thought system proves viable. The
vocabulary extension would look like:

```
;; New atoms
support resistance

;; New predicates
at-level      : (Indicator, Zone) → Fact
tested        : (Zone, N) → Fact
rejected-from : (Indicator, Zone, Direction) → Fact
```

Detection logic: scan window for local highs/lows, cluster within
ATR-based tolerance, count touches, check if current price is near
any cluster.

### 12.2 Periodicity

`autocorrelate(stream, max_lag)` can detect repeating patterns in
indicator behavior. Deferred because it requires tuning max_lag and
interpreting the output.

```
periodic : (Indicator, N) → Fact   ;; indicator repeats every N candles
```

### 12.3 Lead/Lag Relationships

`cross_correlate(stream_a, stream_b, max_lag)` can detect which
indicators lead or lag others. Deferred because the output needs
interpretation.

```
leads : (Indicator, Indicator, N) → Fact  ;; a leads b by N candles
```

### 12.4 Candle Anatomy & Cross-Candle Primitives

Derived indicators for intra- and cross-candle structure. These
values are computed as f64 from raw OHLCV, then consumed by
boolean predicates. No new vectors needed — only new comparison
pairs and zone checks.

**Derived values** (computed, not vectorized):

```
prev-close  = candles[i-1].close
prev-open   = candles[i-1].open
prev-high   = candles[i-1].high
prev-low    = candles[i-1].low
candle-range = high - low
candle-body  = |close - open|
upper-wick   = high - max(close, open)
lower-wick   = min(close, open) - low
```

**New comparison pairs** that enable compositional patterns:

```
;; Cross-candle structure
("high", "prev-high")        ;; higher-high / lower-high
("low", "prev-low")          ;; higher-low  / lower-low
("open", "prev-close")       ;; gap detection
("close", "prev-close")      ;; price sequence
("close", "prev-open")       ;; body-to-body relation

;; Intra-candle structure
("close", "open")            ;; bullish vs bearish candle
("upper-wick", "candle-body")   ;; rejection signal
("lower-wick", "candle-body")   ;; hammer signal
("candle-range", "atr")         ;; abnormal candle size
("candle-body", "candle-range") ;; body fill (conviction)
```

**What this unlocks** (no named patterns, just co-occurring facts):

```
;; Bearish engulfing:
;;   (below close open) ∧ (above prev-close prev-open)
;;   ∧ (above high prev-high) ∧ (below low prev-low)

;; Inside bar:
;;   (below high prev-high) ∧ (above low prev-low)

;; Doji:
;;   (touches close open)

;; Hammer:
;;   (above lower-wick candle-body) ∧ (at candle-body small-range)

;; Shooting star:
;;   (above upper-wick candle-body) ∧ (below close open)
```

**Implementation notes**:

- Derived indicators are computed in `ThoughtEncoder` before the
  boolean gate layer. They never enter the vector space directly.
- The `since` predicate + cross-candle pairs compose multi-candle
  sequences without hardcoded pattern names.
- Volume awareness needs a volume SMA (e.g., SMA20 of volume) to
  define "high volume" / "low volume" zones.

### 12.5 Volume Analysis

Volume is currently in the indicator list but lacks comparative
structure. Needed additions:

```
;; New derived indicator
vol-sma20     ;; 20-period SMA of volume

;; New comparison pair
("volume", "vol-sma20")   ;; volume vs its average

;; New zone checks
(at volume high)           ;; volume > 1.5 * vol-sma20
(at volume low)            ;; volume < 0.5 * vol-sma20
```

Volume + direction confirms conviction: a bearish candle on high
volume is more meaningful than one on low volume. This is captured
naturally by the co-occurrence of facts in the thought vector.
