# Thought System — Implementation Status

Tracks what from `THOUGHT_VOCAB.md` (specification) is implemented in
`rust/src/thought.rs` (code). Updated 2026-03-24.

---

## Architecture Change: v10 Segment Narrative (2026-03-24)

The thought encoder was overhauled from fixed-scale trend/reversal snapshots
to PELT-based segment narrative encoding. This replaces `eval_trends_view`,
`eval_reversals_view`, `eval_zones_cached`, and `eval_divergence_view` with
a single `eval_segment_narrative()` that runs PELT change-point detection on
17 raw indicator streams and encodes each structural segment with direction,
log-magnitude, log-duration, orthogonal position, and log-chronological anchor.

Zone checks are now scoped to relevant streams and bound to segment boundaries
with `beginning`/`ending` atoms. Calendar atoms (day of week, hour blocks,
sessions) added as viewport right-edge snapshot facts.

Removed: SCALES constant, micro/short/major atoms, low/medium/high intensity
atoms, IndicatorStreams vector encoding pipeline, segment_cache.

---

## Atoms

| Group | Spec | Code | Status |
|-------|------|------|--------|
| Indicators (19+2) | close, open, high, low, volume, sma20, sma50, sma200, bb-upper, bb-lower, bb-width, rsi, rsi-sma, macd-line, macd-signal, macd-hist, dmi-plus, dmi-minus, adx, atr | All 19 + body, range | DONE |
| Derived Indicators (8) | prev-close, prev-open, prev-high, prev-low, candle-range, candle-body, upper-wick, lower-wick | All 8 | DONE |
| Directions (3) | up, down, flat | All 3 | DONE |
| Scales (3) | micro, short, major | — | **REMOVED** (v10: continuous log-encoded duration) |
| Intensities (3) | low, medium, high | — | **REMOVED** (v10: continuous log-encoded magnitude) |
| Zones (13) | overbought, oversold, neutral, above-midline, below-midline, positive, negative, strong-trend, weak-trend, squeeze, middle-zone, large-range, small-range | 11 of 13 | large-range/small-range **REPLACED** by `range` stream segmentation; squeeze **REPLACED** by emergent bb-upper/bb-lower segments |
| Segment (2) | beginning, ending | Both | DONE (v10: zone-at-boundary binding) |
| Days of Week (7) | monday–sunday | All 7 | DONE (v10) |
| Sessions (4) | asian-session, european-session, us-session, off-hours | All 4 | DONE (v10) |
| Hour Blocks (6) | h00, h04, h08, h12, h16, h20 | All 6 | DONE (v10) |
| Period (2) | weekend, weekday | — | **DROPPED** (emergence from individual day atoms) |
| Market Holidays (3) | us-holiday, eu-holiday, asia-holiday | 0 of 3 | Deferred |
| Predicates (17) | above, below, crosses-above, crosses-below, touches, bounces-off, trending, at, reversal, continuation, diverging, since, at-day, at-session, at-hour, at-period, at-holiday | at-day, at-session, at-hour: DONE; trending, reversal, continuation, diverging: REMOVED | at-period dropped; at-holiday deferred |

---

## Composition Primitives (§3)

| Primitive | Spec Section | Code | Status |
|-----------|-------------|------|--------|
| Comparison (above/below/crosses/touches/bounces) | §3.1 | `eval_comparisons_cached()` | DONE |
| Trending (indicator, direction, scale, intensity) | §3.2 | — | **REMOVED** (v10: replaced by segment narrative) |
| Zone (at indicator zone) | §3.3 | `eval_segment_narrative()` (zone-at-boundary) | DONE (v10: zones bound to segment boundaries with beginning/ending atoms) |
| Reversal / Continuation | §3.4 | — | **REMOVED** (v10: implicit in direction changes between adjacent segments) |
| Divergence | §3.5 | — | **REMOVED** (v10: emergent from segment direction co-occurrence) |
| Segment Narrative | NEW (v10) | `eval_segment_narrative()` | DONE — PELT on 17 raw streams, 3-layer temporal binding |
| Since (temporal binding) | §3.6 | `eval_temporal()` | DONE (chronological, max_lookback=12) |
| Clock (at-day, at-session, at-hour) | §3.7 | `eval_calendar()` | DONE (v10) |
| Market Holidays (at-holiday) | §3.8 | — | Deferred |
| RSI vs RSI-SMA comparisons | §3.1 | Pre-computed in encoder | DONE |

---

## Segment Narrative Streams (v10)

17 streams, each independently PELT-segmented:

| Stream | Extractor | Zone Checks |
|--------|-----------|-------------|
| close | ln(close) | — |
| sma20 | ln(sma20) | — |
| sma50 | ln(sma50) | — |
| sma200 | ln(sma200) | — |
| bb-upper | ln(bb_upper) | — |
| bb-lower | ln(bb_lower) | — |
| volume | ln(volume) | — |
| rsi | rsi | overbought(>70), oversold(<30), above-mid(>50), below-mid(<=50) |
| rsi-sma | rolling 14-period RSI mean | — |
| macd-line | macd_line | positive(>0), negative(<=0) |
| macd-signal | macd_signal | — |
| macd-hist | macd_hist | positive(>0), negative(<=0) |
| dmi-plus | dmi_plus | strong(>25), weak(<20) |
| dmi-minus | dmi_minus | strong(>25), weak(<20) |
| adx | adx | strong(>25), weak(<20) |
| body | close - open | — |
| range | high - low | — |

---

## Comparison Pairs (§3.1)

| Category | Spec | Code | Status |
|----------|------|------|--------|
| Core MA/BB/MACD/DMI (9) | 9 pairs | 9 pairs | DONE |
| OHLC vs structure (10 spec'd) | open vs sma20/50/200, open vs bb-upper/lower, high vs bb-upper, low vs bb-lower, high/low vs sma200, rsi vs rsi-sma | 7 + rsi-sma separate | **MISSING: (rsi, rsi-sma) in COMPARISON_PAIRS** (but pre-computed separately) |
| Cross-candle (5) | high/prev-high, low/prev-low, open/prev-close, close/prev-close, close/prev-open | All 5 | DONE |
| Intra-candle (8 spec'd) | close/open, close/high, low/close, upper-wick/candle-body, lower-wick/candle-body, upper-wick/lower-wick, candle-range/atr, candle-body/candle-range | 6 of 8 | (close,high) and (low,close) **DROPPED** — covered by body/range streams + wick ratios |

---

## Holon Primitives Used (per primers)

### Core Algebra (series-001-002-holon-ops)

| Primitive | Primer Description | Used in Thought Encoder | Used in Journaler (observe) | Status |
|-----------|-------------------|------------------------|---------------------------|--------|
| `bind` | Associate two vectors (element-wise multiply) | Yes — all fact composition + segment narrative | No | DONE |
| `bundle` | Superpose vectors (majority vote) | Yes — combine facts into thought | No | DONE |
| `unbind` | Retrieve component from bound pair (self-inverse of bind) | No | No | Not used |
| `prototype` | Extract category essence (threshold on agreement) | No | No | Not used (Accumulator.threshold() used instead) |
| `prototype_add` | Incremental prototype update | No | No | Not used |
| `negate` | Remove component's influence (subtract/orthogonalize/flip) | No | Yes — correction: negate misleading features | DONE (observe) |
| `amplify` | Boost signal in superposition | No | Yes — amplify aligned/corrected signals | DONE (observe) |
| `flip` | Element-wise negation (+1 ↔ -1) | No | No | Not used |
| `blend` | Weighted interpolation between vectors | No | No | Not used |
| `difference` | Delta between two states (after - before, thresholded) | No | No | Removed (was used for raw_delta) |
| `analogy` | Relational transfer: C + (B - A) | No | No | **NOT IMPLEMENTED** |

### Pattern Extraction (series-001-002)

| Primitive | Primer Description | Used | Status |
|-----------|-------------------|------|--------|
| `resonance` | Keep dimensions where two vectors agree in sign | No (encoder) / Yes (observe — correct predictions) | DONE (observe only) |
| `permute` | Circular shift for positional encoding | No | **NOT IMPLEMENTED** (position_vector used instead) |
| `cleanup` | Find closest match in codebook | No | Not used |
| `similarity_profile` | Per-dimension agreement vector | No | **NOT IMPLEMENTED** |
| `complexity` | How mixed is the vector (0=clean, 1=dense) | No | Not used |
| `invert` | Reconstruct components from vector (top-k matches) | Yes — FactCodebook.decode() | DONE |

### Extended Algebra (series-001-002)

| Primitive | Primer Description | Used | Status |
|-----------|-------------------|------|--------|
| `attend` | Soft/hard/amplify attention | No | **NOT IMPLEMENTED** |
| `project` | Project onto subspace | No | **NOT IMPLEMENTED** |
| `reject` | Orthogonal complement (what's NOT in subspace) | No | **NOT IMPLEMENTED** |
| `conditional_bind` | Gated binding (bind only where gate passes) | No | **NOT IMPLEMENTED** |
| `sparsify` | Keep top-k dimensions by magnitude | No | **NOT IMPLEMENTED** |
| `centroid` | True geometric average (normalized before threshold) | No | Not used |
| `bundle_with_confidence` | Bundle + per-dimension confidence margins | No | **NOT IMPLEMENTED** |
| `power` | Fractional binding strength | No | **NOT IMPLEMENTED** |

### Streaming Operations (series-001-002)

| Primitive | Primer Description | Used | Status |
|-----------|-------------------|------|--------|
| `accumulate` / `decay` | Frequency-preserving running bundle | Yes — all 5 accumulators in Journaler | DONE |
| `accumulate_weighted` | Weighted accumulation (confidence scaling) | Yes — novelty-gated corrections | DONE |
| `segment` | Structural breakpoints in stream | No | **REMOVED** (v10: replaced by PELT on raw values) |
| `drift_rate` | Rate of change of similarity along stream | No | **REMOVED** (v10: magnitude is log-encoded per segment) |
| `autocorrelate` | Self-similarity at lags (periodicity) | No | Deferred (§12.2) |
| `cross_correlate` | Cross-stream similarity at lags (lead/lag) | No | Deferred (§12.3) |
| `coherence` | Mean pairwise cosine similarity | Yes — ThoughtResult.coherence | DONE |
| `entropy` | Normalized Shannon entropy of {-1,0,1} | Yes — recalibrate noise floor | DONE |
| `purity` | Accumulator concentration (Tr(ρ²)) | No | **NOT IMPLEMENTED** |
| `participation_ratio` | Effective active dimensions | No | **NOT IMPLEMENTED** |
| `capacity` | Accumulator fullness estimate | No | **NOT IMPLEMENTED** |
| `grover_amplify` | Iterative signal amplification | Yes — amplify_signal() in observe | DONE |

### Memory Layer (series-001-003-memory)

| Primitive | Primer Description | Used | Status |
|-----------|-------------------|------|--------|
| `OnlineSubspace` | Incremental manifold learning (CCIPCA) | No | **NOT IMPLEMENTED** |
| `StripedSubspace` | Crosstalk-free attribution via stripe hashing | No | **NOT IMPLEMENTED** |
| `Engram` | Named serializable subspace snapshot | No | **NOT IMPLEMENTED** |
| `EngramLibrary` | Pattern memory bank with two-tier matching | No | **NOT IMPLEMENTED** |

### Encoding Layer (series-001-001-atoms-and-vectors)

| Primitive | Primer Description | Used | Status |
|-----------|-------------------|------|--------|
| String atomization | SHA-256 + seed → bipolar vector | Yes — all atoms via VectorManager | DONE |
| `$linear` / `$log` encoding | Magnitude-aware scalar encoding | Yes — ScalarEncoder for segment magnitude/duration/chrono | DONE |
| `$time` encoding | Cyclical temporal encoding (hour/day/month rotations) | No | **NOT IMPLEMENTED** (calendar uses atomic bind instead) |
| Positional list encoding | bind(item, position_vector) | Yes — segment position + `since` temporal binding | DONE |

---

## Structural Features

| Feature | Spec | Status |
|---------|------|--------|
| PELT change-point detection | v10 | DONE (bic_penalty + pelt_changepoints on raw values) |
| Segment narrative encoding | v10 | DONE (17 streams, 3-layer temporal binding) |
| Zone-at-boundary facts | v10 | DONE (scoped to relevant streams, explicit opposites) |
| Calendar facts | v10 | DONE (day of week, hour blocks, sessions) |
| Chronological since (candle N) | §3.6 current | DONE (max_lookback=12) |
| Segment-anchored since (structural N) | §3.6 planned | **NOT IMPLEMENTED** (PELT boundaries now available) |
| Dynamic support/resistance | §12.1 | Deferred |
| Periodicity detection | §12.2 | Deferred |
| Lead/lag relationships | §12.3 | Deferred |
| Volume SMA / volume zones | §12.5 | **NOT IMPLEMENTED** (volume segmentation partially covers) |

---

## Summary

**Implemented (v10)**: PELT-based segment narrative across 17 indicator streams
with 3-layer temporal binding (position, duration, chronological anchor). Zone
checks scoped to relevant streams with explicit opposite poles, bound to segment
boundaries. Calendar atoms (day, hour, session). Comparisons, temporal echoes,
RSI-SMA unchanged. Core algebra (bind, bundle, resonance, negate, amplify) used
across encoder and observer. ScalarEncoder for log-encoded magnitudes, durations,
and chronological anchors.

**Removed (v10)**: Fixed-scale trending/reversal/continuation/divergence facts,
SCALES constant, micro/short/major atoms, low/medium/high intensity atoms,
IndicatorStreams vector encoding pipeline (segment, drift_rate on encoded streams),
standalone eval_zones.

**Not implemented — backlog (not blocking)**:
- Volume SMA comparison (vol-sma20 + comparison pair)
- OHLC vs structure comparison pairs (3 of 10 missing)
- Segment-anchored `since` lookback (PELT provides boundaries)
- (rsi, rsi-sma) in COMPARISON_PAIRS (currently pre-computed separately)

**Not implemented — low-hanging fruit (primitives)**:
- `purity` — accumulator concentration, could inform learning health
- `participation_ratio` — effective active dimensions, complementary to entropy
- `capacity` — accumulator fullness, could gate when to stop learning

**Not implemented — larger effort / high potential**:
- `Engram` / `EngramLibrary` — persistent pattern memory
- `OnlineSubspace` — manifold learning for market regime detection
- `attend` / `project` / `reject` — subspace isolation in thought vectors
- `conditional_bind` — gated composition (facts meaningful only in context)
- `analogy` — relational transfer between market contexts
- Dynamic support/resistance levels
- `autocorrelate` / `cross_correlate` — periodicity and lead/lag detection
