# Thought System — Implementation Status

Tracks what from `THOUGHT_VOCAB.md` (specification) is implemented in
`rust/src/thought.rs` (code). Updated 2026-03-22.

---

## Atoms

| Group | Spec | Code | Status |
|-------|------|------|--------|
| Indicators (19) | close, open, high, low, volume, sma20, sma50, sma200, bb-upper, bb-lower, bb-width, rsi, rsi-sma, macd-line, macd-signal, macd-hist, dmi-plus, dmi-minus, adx, atr | All 19 | DONE |
| Derived Indicators (8) | prev-close, prev-open, prev-high, prev-low, candle-range, candle-body, upper-wick, lower-wick | All 8 | DONE |
| Directions (3) | up, down, flat | All 3 | DONE |
| Scales (3) | micro, short, major | All 3 | DONE |
| Intensities (3) | low, medium, high | All 3 | DONE |
| Zones (13) | overbought, oversold, neutral, above-midline, below-midline, positive, negative, strong-trend, weak-trend, squeeze, middle-zone, large-range, small-range | 11 of 13 | **MISSING: large-range, small-range** |
| Days of Week (7) | monday–sunday | 0 of 7 | **NOT IMPLEMENTED** |
| Sessions (4) | asian-session, european-session, us-session, off-hours | 0 of 4 | **NOT IMPLEMENTED** |
| Hour Blocks (6) | h00, h04, h08, h12, h16, h20 | 0 of 6 | **NOT IMPLEMENTED** |
| Period (2) | weekend, weekday | 0 of 2 | **NOT IMPLEMENTED** |
| Market Holidays (3) | us-holiday, eu-holiday, asia-holiday | 0 of 3 | **NOT IMPLEMENTED** |
| Predicates (17) | above, below, crosses-above, crosses-below, touches, bounces-off, trending, at, reversal, continuation, diverging, since, at-day, at-session, at-hour, at-period, at-holiday | 12 of 17 | **MISSING: at-day, at-session, at-hour, at-period, at-holiday** |

**Total atoms**: 84 spec'd, 62 implemented, 22 missing (all calendar/temporal).

---

## Composition Primitives (§3)

| Primitive | Spec Section | Code | Status |
|-----------|-------------|------|--------|
| Comparison (above/below/crosses/touches/bounces) | §3.1 | `eval_comparisons()` | DONE |
| Trending (indicator, direction, scale, intensity) | §3.2 | `eval_trends()` | DONE |
| Zone (at indicator zone) | §3.3 | `eval_zones()` | DONE (missing large-range, small-range) |
| Reversal / Continuation | §3.4 | `eval_trends()` | DONE |
| Divergence | §3.5 | `eval_divergences()` | DONE |
| Since (temporal binding) | §3.6 | `eval_temporal()` | DONE (chronological, max_lookback=12) |
| Clock (at-day, at-session, at-hour, at-period) | §3.7 | — | **NOT IMPLEMENTED** |
| Market Holidays (at-holiday) | §3.8 | — | **NOT IMPLEMENTED** |
| RSI vs RSI-SMA comparisons | §3.1 | Pre-computed in encoder | DONE |

---

## Comparison Pairs (§3.1)

| Category | Spec | Code | Status |
|----------|------|------|--------|
| Core MA/BB/MACD/DMI (9) | 9 pairs | 9 pairs | DONE |
| OHLC vs structure (10 spec'd) | open vs sma20/50/200, open vs bb-upper/lower, high vs bb-upper, low vs bb-lower, high/low vs sma200, rsi vs rsi-sma | 7 + rsi-sma separate | **MISSING: (rsi, rsi-sma) in COMPARISON_PAIRS** (but pre-computed separately) |
| Cross-candle (5) | high/prev-high, low/prev-low, open/prev-close, close/prev-close, close/prev-open | All 5 | DONE |
| Intra-candle (8 spec'd) | close/open, close/high, low/close, upper-wick/candle-body, lower-wick/candle-body, upper-wick/lower-wick, candle-range/atr, candle-body/candle-range | 6 of 8 | **MISSING: (close, high), (low, close)** |

---

## Zone Checks (§3.3)

| Zone Check | Code | Status |
|------------|------|--------|
| (at rsi overbought/oversold/neutral) | Yes | DONE |
| (at rsi above-midline/below-midline) | Yes | DONE |
| (at adx strong-trend/weak-trend) | Yes | DONE |
| (at bb-width squeeze) | Yes | DONE |
| (at close middle-zone) | Yes | DONE |
| (at macd-line positive/negative) | Yes | DONE |
| (at macd-hist positive/negative) | Yes | DONE |
| (at candle-range large-range) | No | **NOT IMPLEMENTED** (needs atom + threshold) |
| (at candle-range small-range) | No | **NOT IMPLEMENTED** (needs atom + threshold) |
| (at volume high/low) | No | **NOT IMPLEMENTED** (needs vol-sma20) |

---

## Holon Primitives Used (per primers)

Primitives listed per the official primer docs at
`~/work/holon/algebraic-intelligence.dev/src/content/docs/blog/primers/`.

### Core Algebra (series-001-002-holon-ops)

| Primitive | Primer Description | Used in Thought Encoder | Used in Journaler (observe) | Status |
|-----------|-------------------|------------------------|---------------------------|--------|
| `bind` | Associate two vectors (element-wise multiply) | Yes — all fact composition | No | DONE |
| `bundle` | Superpose vectors (majority vote) | Yes — combine facts into thought | No | DONE |
| `unbind` | Retrieve component from bound pair (self-inverse of bind) | No | No | Not used |
| `prototype` | Extract category essence (threshold on agreement) | No | No | Not used (Accumulator.threshold() used instead) |
| `prototype_add` | Incremental prototype update | No | No | Not used |
| `negate` | Remove component's influence (subtract/orthogonalize/flip) | No | Yes — correction: negate misleading features | DONE (observe) |
| `amplify` | Boost signal in superposition | No | Yes — amplify aligned/corrected signals | DONE (observe) |
| `flip` | Element-wise negation (+1 ↔ -1) | No | No | Not used |
| `blend` | Weighted interpolation between vectors | No | No | Not used (was used for delta smoothing, now removed) |
| `difference` | Delta between two states (after - before, thresholded) | Yes — raw_delta for direction | No | DONE |
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
| `segment` | Structural breakpoints in stream | Yes — trend/reversal detection | DONE |
| `drift_rate` | Rate of change of similarity along stream | Yes — trend intensity | DONE |
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
| `$linear` / `$log` encoding | Magnitude-aware scalar encoding | Yes — ScalarEncoder for indicator streams | DONE |
| `$time` encoding | Cyclical temporal encoding (hour/day/month rotations) | No | **NOT IMPLEMENTED** (calendar uses atomic bind instead) |
| Positional list encoding | bind(item, position_vector) | Yes — `since` temporal binding | DONE |

---

## Structural Features

| Feature | Spec | Status |
|---------|------|--------|
| Chronological since (candle N) | §3.6 current | DONE (max_lookback=12) |
| Segment-anchored since (structural N) | §3.6 planned | **NOT IMPLEMENTED** |
| Dynamic support/resistance | §12.1 | Deferred |
| Periodicity detection | §12.2 | Deferred |
| Lead/lag relationships | §12.3 | Deferred |
| Volume SMA / volume zones | §12.5 | **NOT IMPLEMENTED** |

---

## Summary

**Implemented**: Core TA vocabulary (indicators, comparisons, trends, zones,
reversals, divergences, temporal echoes), fact codebook debug decoder, coherence.
Streaming primitives (accumulate, decay, accumulate_weighted, segment, drift_rate,
entropy, grover_amplify) used in Journaler observe/recalibrate. Core algebra
(bind, bundle, difference, resonance, negate, amplify) used across encoder and
observer.

**Not implemented — low-hanging fruit (vocab)**:
- Calendar atoms + predicates (22 atoms, 5 predicates, ~50 lines of code)
- Missing zone atoms: large-range, small-range (2 atoms, 2 zone checks)
- Missing comparison pairs: (close, high), (low, close)
- Volume zones (needs vol-sma20 derived indicator)

**Not implemented — low-hanging fruit (primitives)**:
- `purity` — accumulator concentration, could inform learning health
- `participation_ratio` — effective active dimensions, complementary to entropy
- `capacity` — accumulator fullness, could gate when to stop learning

**Not implemented — medium effort**:
- `$time` cyclical encoding for timestamps (alternative to atomic calendar approach)
- Segment-anchored temporal lookback (replace candle distance with segment distance)
- `resonance` in encoder as confirmation primitive between facts
- `bundle_with_confidence` for per-dimension confidence margins on thoughts
- `similarity_profile` for structural delta between consecutive thoughts

**Not implemented — larger effort / high potential**:
- `Engram` / `EngramLibrary` — persistent pattern memory (queued in NEXT_MOVES #2)
- `OnlineSubspace` — manifold learning for market regime detection
- `attend` / `project` / `reject` — subspace isolation in thought vectors
- `conditional_bind` — gated composition (facts meaningful only in context)
- `analogy` — relational transfer between market contexts
- Dynamic support/resistance levels
- `autocorrelate` / `cross_correlate` — periodicity and lead/lag detection
