# Learnings: Adaptive Monitor Trading with Retroactive Learning

## Objective

Stress-test Holon's algebraic primitives as an adaptive online learning system for
BTC paper trading. Walk forward chronologically through 652K candles (2019–2025),
making BUY/SELL predictions at high-volatility moments using a 5-panel "monitor"
encoding, then learning from resolved trades using 8 different Holon algebra update
strategies. Compare all adaptive strategies against a static baseline that never
updates after warm-up.

## Experiment Design

### Encoding Pipeline

1. **Monitor encoding** (from v6): 5-panel layout simulating a trader's screen
   - Panel 1: OHLC + SMA20/50/200 + BB (clamped) — shared price Y-axis
   - Panel 2: Volume (window-normalized)
   - Panel 3: RSI (fixed 0–100)
   - Panel 4: MACD (window-normalized)
   - Panel 5: DMI (fixed 0–100)
   - Window: 48 candles (4 hours), all values normalized to [0,1]

2. **Thermometer encoding**: [0,1] flat image → 4096-dim bipolar vector.
   Each of 816 values (17 features × 48 candles) maps to ~5 dimensions,
   with the fraction of +1 dims proportional to the value.

3. **Oracle labels** (`label_oracle_10`): Retroactive BUY/SELL labels based on
   whether price moves ≥1.0% within 3 hours.

### Walk-Forward Protocol

- **Warm-up**: First 3 months (Jan–Mar 2019), ~25,920 candles → 382 BUY + 304 SELL vectors
- **Adaptive phase**: Apr 2019 → Mar 2025
- **Prediction locked at queue time**: Each trade's prediction is stored when first observed,
  not recomputed at resolution. This prevents sequential resolution bias.
- **Resolution**: 36 candles (3 hours) after observation
- **Volume filter**: Only candles with `atr_r > 0.002` are traded

### Strategies Tested

| Strategy | Update Mechanism | Holon Primitives Used |
|----------|------------------|----------------------|
| A | Simple accumulate | `prototype_add` |
| B | Error-corrective | `negate` (wrong) + `prototype_add` (correct) |
| C | Amplify/negate | `amplify` (good) + `negate` (bad) + `prototype_add` |
| D | Recency blend | `blend(alpha=0.05)` |
| E | Regime-aware | `coherence` + `drift_rate` → adaptive alpha `blend` |
| F | Attribution-guided | `resonance` + `similarity_profile` → dimension trust mask |
| G | Periodic sharpen | `prototype_add` + `grover_amplify` + `reject` every 200 trades |
| H | Sliding window rebuild | deque(200) + `bundle_with_confidence` every 100 trades |
| Static | No updates after warm-up | `prototype` (once) |

## Results

### Overall Accuracy (173,154 resolved trades)

| Strategy | Overall | Rolling 500 |
|----------|---------|-------------|
| **Static** | **51.1%** | 49.0% |
| F (attribution) | 50.6% | 44.6% |
| A (accumulate) | 50.5% | 44.0% |
| D (recency blend) | 50.5% | 44.0% |
| E (regime-aware) | 50.5% | 44.0% |
| G (sharpen) | 49.9% | 45.4% |
| B (error-corrective) | 49.8% | 39.8% |
| C (amplify/negate) | 49.8% | 39.8% |
| H (sliding window) | 48.9% | 38.6% |

### Per-Year Breakdown (accuracy %)

| Strategy | 2019 | 2020 | 2021 | 2022 | 2023 | 2024 | 2025 |
|----------|------|------|------|------|------|------|------|
| **Static** | **51.2** | **51.7** | 49.8 | 50.7 | **54.7** | **52.1** | **53.7** |
| A | 49.7 | 50.2 | 49.7 | **52.4** | 51.2 | 50.8 | 52.1 |
| B | 49.5 | 50.3 | 50.3 | 49.6 | 49.5 | 48.6 | 51.3 |
| C | 49.5 | 50.3 | 50.3 | 49.6 | 49.5 | 48.6 | 51.3 |
| D | 49.7 | 50.2 | 49.7 | 52.4 | 51.2 | 50.8 | 52.1 |
| E | 49.7 | 50.2 | 49.7 | 52.4 | 51.2 | 50.8 | 52.1 |
| F | 48.6 | 48.9 | 50.4 | **53.5** | 52.6 | 50.5 | 52.7 |
| G | 48.7 | 47.7 | 50.1 | 52.9 | 46.1 | 49.9 | 52.9 |
| H | 49.2 | 48.2 | 49.1 | 49.8 | 49.4 | 48.3 | 46.0 |

Trade counts per year: 23,400 / 26,620 / 58,349 / 28,772 / 9,556 / 20,861 / 5,596

### Diagnostics

| Metric | Value |
|--------|-------|
| Initial prototype similarity (BUY vs SELL) | 0.8526 |
| Final prototype similarity — A, D, E, F | 0.8892 |
| Final prototype similarity — B, C | 0.6866 |
| Final prototype similarity — G | -1.0000 |
| Final prototype similarity — H | 0.9034 |
| Final prototype similarity — Static | 0.8526 |
| Strategy E final coherence | 0.7125 |
| Strategy F dim trust range | [0.10, 8.10], mean=1.15, std=2.39 |
| Strategy G sharpen count | 869 |
| Strategy H prototype complexity | 0.9817 |

## Key Findings

### 1. Static baseline wins — adaptive updates hurt performance

The static model (train once on 382+304 warm-up vectors, never update) outperforms
all 8 adaptive strategies. This is the clearest finding: **for thermometer-encoded
Holon prototypes at this resolution, online learning from resolved trades does not
improve prediction accuracy.**

The static model's 51.1% is small but consistent — it beats every adaptive strategy
by 0.5–2.2 percentage points overall, and by more in several individual years.

### 2. A/D/E produce identical predictions

Strategies A (prototype_add), D (blend α=0.05), and E (regime-aware blend) show
identical accuracy across all years: 49.7/50.2/49.7/52.4/51.2/50.8/52.1. This means
blend-based updates are too subtle to alter predictions meaningfully — the cosine
similarity between vec and prototype barely changes with incremental additions to an
already-large prototype.

### 3. Error-corrective strategies (B, C) degrade performance

Negate and amplify, when applied to error correction, push prototypes in
adversarial directions. B and C end at 0.6866 prototype similarity (down from 0.85
at warm-up), meaning the prototypes have diverged substantially — but this divergence
is noise-driven, not signal-driven. The result is 49.8% accuracy, worse than random
in some windows.

### 4. Grover amplification drives prototypes to perfect anti-correlation

Strategy G's repeated `grover_amplify + reject` cycle (869 sharpenings) drives the
BUY and SELL prototypes to -1.0 cosine similarity — they become perfect negatives of
each other. Despite maximum prototype separation, accuracy is 49.9%. This proves
that **prototype separation is necessary but not sufficient** — the separation must
be along dimensions that actually discriminate BUY from SELL.

### 5. Attribution-guided (F) shows marginal promise

F is the best adaptive strategy at 50.6% overall, with its strongest showing in
2022 (53.5%). The dimension trust mask identifies specific vector dimensions that
correlate with correct predictions. The trust values range from 0.10 to 8.10
(mean 1.15, std 2.39), showing meaningful differentiation. The most trusted
dimensions cluster in the 1170–1890 range, which maps to specific features in the
thermometer encoding.

### 6. The prototype similarity wall

All strategies face the same fundamental barrier: BUY and SELL prototypes are
0.85–0.89 similar. With 4096-dim thermometer encoding of 816 values (~5 dims per
value), the encoding is too coarse to capture the subtle differences between BUY and
SELL market patterns. The monitor encoding showed 60% in-sample k-NN accuracy on raw
(non-encoded) data — meaning the signal exists in the raw features but is lost in
the thermometer→bipolar conversion.

### 7. 2021 anomaly: 58K trades (2.5× other years)

2021 has 58,349 trades vs the 9K–28K range for other years. The 2021 bull market
created extreme volatility with many more high-ATR candles crossing the filter
threshold. No strategy performs notably well or poorly in 2021 — all hover at
49–50%.

## Root Cause Analysis

The adaptive learning experiment isolates three layers of the prediction pipeline:

1. **Feature engineering** (monitor encoding): Validated at 60% k-NN accuracy on raw data
2. **Vector encoding** (thermometer → bipolar): Loses ~10% of the signal
3. **Algebraic learning** (prototype operations): Cannot recover what the encoding lost

The bottleneck is at layer 2. The thermometer encoding maps 816 continuous values
into a 4096-dim binary vector, giving each value only ~5 bits of resolution. When
two market snapshots differ by small amounts (which is the typical case for BUY vs
SELL — they're mostly the same chart with slightly different slope/momentum), those
differences are below the encoding resolution.

## Implications for Holon

### What works
- `prototype()` and `cosine_similarity()` correctly build and compare centroids
- `coherence()` provides meaningful regime stability measurement (0.71 = stable)
- `similarity_profile()` and `resonance()` identify per-dimension agreement patterns
- `complexity()` correctly measures prototype mixedness (0.98 = near-maximum entropy)
- `grover_amplify()` + `reject()` successfully separate prototypes (to -1.0 similarity)

### What doesn't help (in this context)
- `negate()` for error correction — adversarial drift outweighs correction
- `amplify()` on correct predictions — reinforces noise alongside signal
- `blend()` with small alpha — too subtle to change outcomes
- `bundle_with_confidence()` for periodic rebuild — window too small, signal too weak
- `drift_rate()` for regime detection — regime changes don't correlate with encoding changes

### Remaining questions
- Would higher-dimensional encoding (e.g., 16K or 32K dims) resolve the resolution bottleneck?
- Would a learned encoding (e.g., binding features with learned role vectors) outperform thermometer?
- Would the k-NN classifier (which works at 60% on raw data) benefit from Holon's algebra
  if applied to raw feature vectors rather than bipolar-encoded ones?
- Can Strategy F's dimension trust mask be applied to the raw feature space to
  identify which specific chart features (RSI slope? BB width? MACD crossover?)
  most reliably distinguish BUY from SELL?

---

# Phase 2: Algebraic Refinement & Composed Signals

## Objective

After Phase 1 showed all adaptive prototype strategies landing at ~50%, Phase 2
explored whether Holon's algebra could extract directional signal through more
sophisticated approaches: algebraic refinement of subspace means, categorical
encoding, and adaptive regime-conditional trading.

## Experiments Run

### Experiment 2A: Algebraic Refinement of Subspace Means

**Script**: `algebra_refine.py`

Applied 5 algebraic strategies to per-stripe BUY/SELL subspace means from
2019-2020 data, then tested on 2021+ OOS data:

| Strategy | Method | In-Sample | OOS |
|----------|--------|-----------|-----|
| Raw discriminant | `buy_mean - sell_mean` | ~55% | ~52% |
| Reject shared | `reject(buy_mean, sell_mean)` | ~54% | ~51% |
| Difference + amplify | `amplify(difference(buy, sell))` | ~55% | ~52% |
| Grover amplify | `grover_amplify(discriminant)` | ~54% | ~51% |
| Resonance filter | `resonance(buy, sell)` mask | ~53% | ~51% |

**Finding**: All strategies hit the same wall. The per-stripe cosine similarity
between BUY and SELL means was ~0.996 — the algebra can't amplify signal that
isn't there.

### Experiment 2B: Explainability Analysis

**Script**: `explain_similarity.py`

Three-level decomposition of why BUY ≈ SELL:

1. **Raw features**: Mean cosine similarity between BUY and SELL feature vectors
   across 48 timesteps = **0.9987**. Max Cohen's d effect size = 0.24 (SMA200).
   Features themselves barely differ between BUY and SELL moments.

2. **Encoding level**: Categorical Holon encoding reduced per-stripe cosine of
   mean vectors to **0.67–0.77** — encoding does create better separation than
   raw features, but individual samples remain too similar.

3. **Variance**: Distribution overlaps are massive. No feature shows meaningfully
   different variance between BUY and SELL.

**Key insight**: The problem is not the encoding or the algebra — it's the data.
TA indicators at the moment of a BUY signal look nearly identical to the moment
of a SELL signal. The 0.24 Cohen's d on SMA200 is the strongest difference found
across all features and timesteps.

### Experiment 2C: Categorical/Symbolic Encoding

**Script**: `categorical_refine.py`

Switched from numerical LinearScale to symbolic facts inspired by the
`holon-lab-ddos/http-lab` spectral firewall encoding:

```
{rsi: "neutral", close_above_sma200: True, macd_bullish: False, ...}
```

Used sets for multi-facts, strings for enums, conditional key presence.

- Encoding 5× faster than numerical
- OOS accuracy: **~52%**
- Overall `cosine(buy_mean, sell_mean)` = 0.9960
- All 5 algebra strategies from 2A produced same results

**Finding**: Symbolic representation doesn't help when the underlying facts
don't differ between BUY and SELL.

### Experiment 2D: Cosine Voting Classifiers

**Script**: `cosine_vote_test.py`

After `inspect_facts.py` showed 85% accuracy on 20 hand-picked samples, tested
three cosine-based classifiers at scale:

- `classify_cosine_sum` (aggregate similarity)
- `classify_cosine_weighted_vote` (weighted by distance)
- `classify_cosine_majority` (stripe-level majority)

All three: **~57% in-sample, ~52% OOS**. The 85% on 20 samples was noise.

### Experiment 2E: Adaptive Composed Signals

**Script**: `adaptive_composed.py`

The "composed signals" hypothesis: volatility detection works (high accuracy in
identifying pivotal moments), and direction might be predictable within specific
market contexts that come and go with regime changes.

**Architecture**:
1. `StripedSubspace` regime detector — CCIPCA trained on all market data,
   detects anomalies via residual magnitude
2. Context bucketing — coarse categorical market state (MA alignment, RSI zone)
3. `AdaptiveBiasTable` — weighted counts per context, decayed on regime change
4. Walk-forward: warmup (2019) → supervised (2020) → blind adaptive (2021+)

**Tested configurations** (in parallel, single walk-forward pass):
- No regime detection (pure accumulation)
- Regime detection with decay factors: 0.3, 0.5, 0.7
- Regime detection with no decay (detection only)

**Results** (300,404 volatile candles, 2019-2025):

With 192 context buckets (7 features): observations spread too thin, most
buckets never reached min_samples. Very low action rate (~15% coverage).

With 8 context buckets (3 features: SMA20, SMA200, RSI binary):
- Early supervised accuracy: **54.2%** (1,836 trades in 2020)
- All 8 buckets converged to ~50/50 by candle 65,000
- **Zero actionable buckets from candle 65,000 onward** through 170,000+
- Only 48 regime changes detected in 170k candles (sigma=3.5)
- Action rate dropped to 0% — no context showed >60% directional bias

**The critical finding**: With 100k+ observations across only 8 buckets, every
single context bucket — regardless of whether price is above/below SMA20,
above/below SMA200, RSI bullish/bearish — has almost exactly 50/50 BUY vs SELL
outcomes. The data is perfectly balanced across all indicator-based contexts.

## Consolidated Findings

### What we CAN do with Holon
1. **Detect pivotal moments**: The volatility filter + subspace residual
   reliably identifies high-movement candles. Regime anomaly detection works.
2. **Encode market state**: Categorical encoding is fast, produces meaningful
   vector representations, and the algebra operates correctly on them.
3. **Separate class means**: Grover amplify can push BUY/SELL prototypes to
   -1.0 cosine similarity. The algebra is powerful.

### What we CANNOT do (with current approach)
1. **Predict direction at pivotal moments**: No combination of TA indicators,
   encoding scheme, algebraic operation, or adaptive strategy produces >52%
   OOS directional accuracy. This holds across:
   - 8 adaptive learning strategies (Phase 1)
   - 5 algebraic refinement approaches (Phase 2A)
   - Numerical vs categorical encoding (Phase 2C)
   - Context-conditional prediction (Phase 2E)
   - 300k+ candles across 6 years of BTC data

2. **Find indicator-based context where direction is biased**: Even the
   coarsest 3-feature context (8 buckets) converges to 50/50 with enough
   data. TA indicators have zero predictive relationship to 3-hour price
   direction in any combination.

### The fundamental barrier

The problem is not Holon, not the encoding, not the algebra, and not the
learning strategy. **The problem is the feature space.** Standard TA indicators
(SMA, RSI, MACD, BB, DMI, ADX) at the moment of a high-volatility candle
contain no directional information about the next 3 hours. The features look
the same before a BUY as before a SELL (cosine similarity 0.9987 between
class means on raw features, Cohen's d < 0.25 on all features).

### Open questions for future work

1. **Order flow / microstructure**: Does order book depth, trade flow imbalance,
   or funding rate contain directional signal that TA doesn't?
2. **Different time horizons**: Is 3 hours the wrong resolution? Would 15-min
   or 24-hour direction be more predictable?
3. **Sequence patterns**: Instead of snapshot features, can Holon detect
   *sequences* (e.g., "RSI divergence over 6 candles") that carry direction?
4. **Cross-asset signals**: Does correlation with ETH, S&P, DXY, or VIX
   provide directional context that single-asset TA cannot?
5. **Asymmetric targets**: Instead of BUY vs SELL, what about "big move up"
   vs "everything else"? Class imbalance might reveal signal that balanced
   classification misses.
6. **Raw OHLCV without TA**: Can Holon find patterns in raw price/volume
   that TA indicators are masking? (Briefly tested, inconclusive due to
   runtime crashes.)

---

# Phase 3: Surprise-Driven Fact Discovery (Spectral Firewall Architecture)

## Objective

Apply the spectral firewall's architecture to trading: learn a "normal
market" subspace via CCIPCA, then use `surprise_fingerprint` (recursive
drilldown probe) to identify which encoded facts are anomalously different
at BUY vs SELL moments. This is fundamentally different from prototype
classification — it measures the *out-of-subspace residual* and attributes
it to specific leaf-level facts.

## Setup

- Enhanced `candle_facts` with 25+ conditional-only keys (inspired by the
  firewall's conditional key presence: `oversold`, `bb_breakout_up`,
  `macd_cross_bull`, `volume_spike`, `stoch_oversold`, `cci_overbought`,
  `mfi_oversold`, `squeeze_active`, `engulfing_bull/bear`,
  `return_extreme_up/down`, `vol_extreme`, `streak_up/down`,
  `higher_high/lower_low`, `momentum`, `tf_1h/tf_4h`)
- Extended DB columns from 20 to 42 (added stochastic, Williams %R, CCI,
  MFI, ROC, consecutive candles, HH/LL, squeeze, engulfing, z-scores,
  multi-timeframe)
- Non-striped encoding with `encode_walkable` into 8192-dim vectors
- Recursive drilldown probe mirroring the spectral firewall's
  `_drilldown_probe` — walks the nested `{t0: {...}, t1: {...}, ...}`
  structure, unbinding at each level to isolate leaf contributions

## Experiment: Quick Test (500 train, 200 probe)

| Metric | Value |
|--------|-------|
| Training | 500 candles from 2019 |
| Probing | 200 BUY + 200 SELL (2020 volatile) |
| Unique paths | 2,588 |
| Cohen's d > 0.5 | **66** |
| Max d | 1.441 (`t8.engulfing_bear`) |

Appeared extremely promising — 66 high-signal facts. But sample sizes
were tiny (n=10-35 per path).

## Experiment: Full Run (20k train, 3k probe)

| Metric | Value |
|--------|-------|
| Training | 20,000 candles from 2019 (374s at 53/s) |
| Probing | 3,000 BUY + 3,000 SELL (2020 volatile, 85s each) |
| Dimensions | 8,192 |
| Subspace k | 32 |
| Unique paths | 2,588 |
| Cohen's d > 0.5 | **0** |
| Cohen's d 0.2-0.5 | 146 |
| Cohen's d < 0.2 | 2,442 |
| Max d | 0.413 (`t39.return_extreme_up`) |

### Top 10 facts by Cohen's d:

| Path | d | Direction | BUY mean | SELL mean | n |
|------|---|-----------|----------|-----------|---|
| t39.return_extreme_up | 0.413 | SELL> | 0.00103 | 0.00104 | 92/81 |
| t37.bb_breakout_down | 0.398 | BUY> | 0.00104 | 0.00103 | 169/198 |
| t0.oversold | 0.397 | SELL> | 0.00105 | 0.00106 | 267/243 |
| t17.mfi_oversold | 0.381 | BUY> | 0.00105 | 0.00104 | 96/131 |
| t40.bb_breakout_up | 0.374 | SELL> | 0.00101 | 0.00102 | 189/194 |
| t27.overbought | 0.362 | SELL> | 0.00104 | 0.00105 | 397/295 |
| t15.mfi_overbought | 0.353 | SELL> | 0.00102 | 0.00103 | 120/140 |
| t4.return_extreme_up | 0.350 | BUY> | 0.00105 | 0.00104 | 75/72 |
| t0.mfi_oversold | 0.348 | SELL> | 0.00104 | 0.00105 | 129/110 |
| t39.bb_breakout_up | 0.347 | SELL> | 0.00103 | 0.00104 | 198/174 |

### Conditional key presence analysis:

Max presence rate difference: 1.23% (overbought: 12.24% BUY vs 11.01% SELL).
All conditional keys appear at nearly identical rates in BUY and SELL windows.

## Key Finding

**The spectral firewall architecture also fails to find directional signal.**

The anomalous component (subspace residual) of BUY candles is
indistinguishable from SELL candles at scale. The mean anomaly shares
differ by ~0.00001 (0.00103 vs 0.00104) — pure noise.

The quick test's high d-values (up to 1.441) were entirely due to small
sample sizes (n=10-35). At scale (n=60-637), all effects regress below 0.5.

This is the strongest evidence yet that the fundamental barrier is not:
- The encoding (tried: thermometer, categorical, symbolic, conditional)
- The classification method (tried: prototype, subspace, algebra, k-NN, cosine voting)
- The learning strategy (tried: 8 adaptive, static, context-conditional, regime-adaptive)
- The analysis method (tried: raw features, encoded means, subspace residuals)

**The barrier is the feature space.** TA indicators do not contain
3-hour directional information for BTC, period.

---

# Phase 4: Visual Monitor Encoding + k-NN / Engram Library

## Objective

Two hypotheses tested:

1. **Visual encoding**: Encode spatial grid positions (where indicators sit
   on a virtual monitor) + cross-time shape descriptors (divergences,
   slopes, patterns). This captures what traders actually SEE vs what
   indicators SAY.
2. **Massive library matching**: Use k-NN or engram-based matching instead
   of prototype/subspace smoothing. Individual vectors may preserve local
   structure that averaging destroys.

## k-NN / Engram Library Results (Categorical Encoding, 48-candle)

| Classifier | OOS Accuracy |
|-----------|-------------|
| Prototype baseline (class means) | 51.7% |
| k-NN (best k=50) | 53.0% |
| Engram library (548 engrams, top-5) | 48.0% |

k-NN flat across all k (51-53%). No sweet spot. Engram library WORSE
than random (prefilter selects by eigenvalue energy, not query similarity).
1-NN cosine mean = 0.4731, gap to 10-NN = 0.0316 — flat neighborhoods.

## Visual Monitor Encoding Results

| Config | Encoding | Window | Oracle | Prototype | k-NN best | 1-NN cos |
|--------|----------|--------|--------|-----------|-----------|----------|
| Baseline | Categorical | 48 | 1.0% | 51.7% | 53.0% (k=50) | 0.4731 |
| Visual | Visual | 48 | 1.0% | 52.3% | 51.8% (k=20) | 0.2218 |
| Visual | Visual | 48 | 0.5% | 49.8% | 52.0% (k=50) | 0.2284 |
| Visual | Visual | 144 | 1.0% | 49.2% | 51.0% (k=20) | 0.1860 |
| Visual | Visual | 144 | 0.5% | 49.0% | 51.6% (k=1) | 0.1900 |

### Key observations:

1. **Visual encoding ≈ categorical** — 48-candle visual gets 52.3%
   prototype (vs 51.7% categorical). Difference is noise.
2. **Longer windows are WORSE** — 144-candle drops to 49-51%. The 3x more
   data per vector dilutes any signal that exists.
3. **Lower cosine similarity** — visual vectors are more diverse (0.22 vs
   0.47) because discrete row labels create more orthogonal encodings.
   But diversity doesn't help classification.
4. **Oracle target doesn't matter** — 0.5% and 1.0% move thresholds
   produce the same result (~50-52%).
5. **cosine(BUY_mean, SELL_mean) = 0.992** (visual) vs 0.998
   (categorical) — visual encoding does separate class means slightly
   more, but not enough to exploit.

## Comprehensive Approach Comparison

| # | Approach | Best OOS | What it tested |
|---|---------|----------|---------------|
| 1 | 8 adaptive learning strategies | ~52% | Online learning |
| 2 | Algebraic refinement (amplify, reject, grover) | ~52% | Algebra separation |
| 3 | Explainability analysis | d < 0.25 | Do features differ? |
| 4 | Categorical/symbolic encoding | ~52% | Encoding scheme |
| 5 | Cosine voting on prototypes | ~52% | Classifier type |
| 6 | Regime-conditional adaptive | ~52% | Context conditioning |
| 7 | Surprise fingerprint (spectral firewall) | d = 0.41 | Subspace residual |
| 8 | k-NN (10k library, no smoothing) | 53% | Local structure |
| 9 | Engram library (548 micro-subspaces) | 48% | Case-based reasoning |
| 10 | Visual monitor + k-NN (48-candle) | 52% | Spatial encoding |
| 11 | Visual monitor + k-NN (144-candle) | 51% | Longer visual context |
| 12 | Pixel chart + k-NN (48-candle, 32×4096) | **53.8%** | Raster color encoding |
| 13 | Pixel chart + k-NN (144-candle, 64×4096) | 49.9% | Wider raster, too sparse |
| 14 | Per-panel pixel + voting (48-candle) | 52.7% | Independent panel spaces |
| 14b | Per-panel unanimous (4/4 agree) | 54.7% (17% cov.) | High-confidence filter |

---

# Phase 5: Pixel Chart Encoding (Raster Color Rendering)

## Objective

Encode what a trader literally SEES on their monitor as colored pixels,
rather than abstract indicator values or discretized row labels. Each
candle column contains colored pixels — green/red bodies, wicks, yellow
SMA20, red SMA50, green SMA200, white BB bands — with empty space
implicitly absent (not encoded). Overlapping indicators at the same pixel
produce multi-color sets.

## Encoding Design

- **4 panels**: Price (OHLC + SMAs + BBs), Volume, RSI, MACD
- **50 rows per panel** (PX_ROWS=50)
- **Color tokens**: `gs`/`rs` (green/red solid body), `gw`/`rw` (wicks),
  `dj` (doji), `yl` (SMA20/BB middle), `rl` (SMA50), `gl` (SMA200),
  `wu`/`wl` (BB upper/lower), `vg`/`vr` (volume bars), `rb`/`ro`/`rn`
  (RSI line/overbought/oversold), `ml`/`ms`/`mhg`/`mhr` (MACD components)
- **BB off-screen guard**: Price viewport computed from OHLC + SMAs only;
  BB bands outside viewport are simply not rendered (row = -1, skipped)
- **Empty space**: Only occupied pixels are encoded — sparse by nature
- **Each pixel**: A set of color tokens, e.g. `{"gs", "yl"}` for a green
  candle body overlapping with SMA20

## Capacity Analysis

| Window | Stripes | Dims | Total dims | Est. bindings/stripe | sqrt(d) |
|--------|---------|------|-----------|---------------------|---------|
| 48     | 32      | 4096 | 131,072   | 23–41               | 64      |
| 144    | 64      | 4096 | 262,144   | 34–61               | 64      |

Both configs within Kanerva bundling capacity `sqrt(d)=64`.

## Results

| Config | Window | Dims | Prototype | k-NN best | BUY/SELL cos | 1-NN cos |
|--------|--------|------|-----------|-----------|-------------|----------|
| 32×4096 | 48 | 131k | 53.1% | **53.8% (k=10)** | 0.9955 | 0.2533 |
| 64×4096 | 144 | 262k | 48.9% | 49.9% (k=20) | 0.9909 | 0.1818 |

### Per-year for best config (48-candle, k=10):

| Year | Accuracy | n |
|------|----------|---|
| 2021 | 53.8% | 1,416 |
| 2022 | 51.2% | 697 |
| 2023 | 57.8% | 218 |
| 2024 | 56.3% | 499 |
| 2025 | 51.2% | 160 |

### Key observations:

1. **Pixel is the best encoding so far** — 53.8% OOS beats all 11 prior
   approaches. 2023 (57.8%) and 2024 (56.3%) show per-year signal that
   previous encodings never achieved.
2. **Lower BUY/SELL mean similarity** — 0.9955 (pixel 48) vs 0.9987
   (categorical). The raster representation separates class centroids
   more than any previous encoding.
3. **Much lower 1-NN cosine** — 0.25 (pixel) vs 0.47 (categorical).
   Pixel vectors are far more distinctive/orthogonal to each other,
   meaning the encoding captures more per-vector uniqueness.
4. **144-candle window collapses** — 262k dims with 2,717 training vectors
   is hopelessly sparse. Curse of dimensionality dominates.
5. **Still not actionable** — 53.8% is the highest OOS number seen in
   this project, but it's not a trading edge after transaction costs.

## Phase 5b: Per-Panel Pixel Encoding (Independent Vector Spaces)

### Motivation

Instead of cramming all 4 panels into a single vector space where they
compete for dimensions, give each panel its own independent space:
- Isolate per-panel signal from cross-panel noise
- Measure which panels actually carry directional signal
- Combine via panel-level voting (majority, unanimous, similarity-weighted)

### Config

- Price/Volume/MACD: 16 stripes x 4096D = 65,536 dims each
- RSI: 8 stripes x 4096D = 32,768 dims
- 48-candle window, 10k train / 5k test, oracle_10

### Per-Panel Results

| Panel | Best k | Accuracy | BUY/SELL cos |
|-------|--------|----------|-------------|
| price | 50 | 51.3% | 0.9766 |
| vol | 20 | 51.3% | 0.9987 |
| rsi | 10 | 51.9% | 0.9849 |
| **macd** | 20 | **52.4%** | 0.9811 |

### Combination Results (k=10 and k=20)

| Method | k=10 | k=20 |
|--------|------|------|
| Majority vote (3/4) | 52.5% | 52.7% |
| Unanimous (4/4) | **54.7%** (17% cov.) | **54.7%** (17% cov.) |
| Similarity-weighted | 52.0% | 52.2% |

### Key Findings

1. **MACD is the strongest individual panel** (52.4%) — momentum
   divergence/convergence carries the most directional information of
   any single indicator type.

2. **Price panel is surprisingly weak** (51.3%) — raw candlestick
   patterns in pixel space do not predict direction. The visual structure
   of price alone is insufficient.

3. **Volume is noise** (51.3%, highest BUY/SELL mean cosine at 0.9987) —
   volume patterns look identical before BUY and SELL moments.

4. **Panel agreement is a confidence filter**: When all 4 panels agree
   (unanimous, 4/4), accuracy jumps to **54.7%**, but coverage drops to
   17%. This means panel consensus identifies a subset of higher-
   confidence predictions.

5. **Single-space pixel (53.8%) beats per-panel combined (52.7%)**:
   Splitting panels hurt overall accuracy. Cross-panel interactions
   captured in the single vector (e.g., price+volume+RSI cooccurrence
   at the same moment) carry information that per-panel isolation loses.

6. **Lower per-panel cosine ≠ better accuracy**: Price panel has the
   lowest BUY/SELL mean cosine (0.9766) but the weakest k-NN accuracy.
   Better class centroid separation doesn't guarantee better k-NN
   performance when individual vectors overlap massively.

## What would need to change

To proceed with trading, the features themselves must change:

1. **Order flow / microstructure**: Order book depth, trade flow imbalance,
   funding rate, liquidation data
2. **Cross-asset signals**: ETH correlation, S&P 500, DXY, VIX, crypto
   fear/greed index
3. **Different time horizons**: 15-min or 24-hour targets instead of 3-hour
4. **On-chain data**: Whale movements, exchange inflows/outflows, MVRV ratio
5. **Sentiment**: Social media sentiment, news flow, options put/call ratio

Any of these could be encoded with the same Holon architecture (the
encoding, subspace, surprise fingerprint, and engram machinery all work
correctly). The question is whether *any* available data contains the
directional signal that TA lacks.

## Files

- `holon-lab-trading/scripts/adaptive_monitor.py` — Phase 1: walk-forward with 8 strategies + static baseline
- `holon-lab-trading/scripts/algebra_gauntlet_v6.py` — monitor encoding reference (5-panel)
- `holon-lab-trading/scripts/window_sweep.py` — window size optimization
- `holon-lab-trading/scripts/algebra_refine.py` — Phase 2A: algebraic refinement of subspace means
- `holon-lab-trading/scripts/explain_similarity.py` — Phase 2B: explainability analysis
- `holon-lab-trading/scripts/categorical_refine.py` — Phase 2C: symbolic/categorical + visual monitor encoding
- `holon-lab-trading/scripts/cosine_vote_test.py` — Phase 2D: cosine voting classifiers
- `holon-lab-trading/scripts/adaptive_composed.py` — Phase 2E: regime-conditional adaptive trading
- `holon-lab-trading/scripts/surprise_discovery.py` — Phase 3: surprise-driven fact discovery
- `holon-lab-trading/scripts/engram_knn.py` — Phase 4: k-NN + engram library + visual encoding
- `holon-lab-trading/data/vec_cache_cat_48w_16s_1024d.npz` — cached encoded vectors (300k, int8, 4.9 GB)

---

# Phase 6: VSA Introspection, Eigenvalue Profiling & Discriminative Methods

## Objective

Determine whether Holon's algebraic properties (unbind, cleanup, resonance,
amplify, negate) can extract discriminative signal from pixel-encoded BTC
charts, and whether the per-stripe subspace/engram PCA `k` parameter was
bottlenecking classification.

## Experiments

### 6A: Pixel Introspection (Depixelation)

**Script**: `pixel_inspect.py`

Programmatically "unbinds" each pixel position from BUY/SELL prototypes
to see what color each prototype associates with each pixel. Ranks positions
by discrimination score (1 - cos(buy_unbound, sell_unbound)).

| Config | Max disc score | Color similarity | Discriminant density |
|--------|---------------|-----------------|---------------------|
| 32×4096 | 0.118 | 0.01–0.05 (noise) | — |
| 64×4096 | 0.171 | Still noise-level | 1.1% |

**Finding**: Even after fixing the Kanerva capacity issue (32→64 stripes),
unbinding from prototypes produces noisy results. The superposition of
~2,018 bindings per vector makes clean retrieval of individual pixel
contributions impossible — the information is there but too diffuse to
isolate via single unbinding.

### 6B: Pixel Render Verification

**Script**: `pixel_render_check.py`

Visual confirmation that the pixel encoding correctly represents chart
patterns. Renders ANSI-colored text grids for each panel.

**Key finding**: Encoding is correct — price panels clearly show candlestick
bodies, wicks, SMA lines, and BB bands in the expected spatial positions.
The encoding faithfully represents what a trader would see. The problem
is not encoding fidelity.

**Kanerva capacity diagnosis**: With ~2,018 bindings per 48-candle window
and 32 stripes, some stripes held up to 78 bindings — exceeding the
sqrt(4096)=64 clean-retrieval capacity. This caused unbinding interference
in Phase 6A. Moving to 64 stripes reduced max per-stripe bindings to ~32,
well within capacity.

### 6C: Discriminative Resonance Classification

**Script**: `pixel_subspace.py` (new methods added)

Three new scoring methods using discriminative resonance:

1. **disc_res**: Flat discriminative resonance — `resonance(flat, discriminant)`
   then cosine to prototypes
2. **disc_res_stripe**: Per-stripe discriminative resonance — resonate each
   stripe with its per-stripe discriminant
3. **disc_masked**: Filter both input AND prototypes through discriminant
   before cosine comparison

Also added `--update-mode selective` for amplify/negate reinforcement
instead of prototype_add.

**Results at 32×4096D** (first run, capacity-constrained):
All methods ~50%, freeze/unfreeze flapping observed.

### 6D: k-NN at 64×4096D (Capacity-Fixed Config)

**Script**: `engram_knn.py --stripes 64 --dims 4096`

| Metric | 32×4096 (old) | 64×4096 (new) |
|--------|--------------|--------------|
| Prototype baseline | 52.7% | 52.7% |
| k-NN best (k=10) | **53.8%** | **53.8%** |

Per-year at 64×4096, k=10:

| Year | Accuracy | n |
|------|----------|---|
| 2021 | 53.1% | 1,416 |
| 2022 | 51.5% | 697 |
| 2023 | 56.4% | 218 |
| 2024 | 55.9% | 499 |
| 2025 | 55.6% | 160 |

**Finding**: Doubling stripes (fixing capacity) did not change overall
accuracy. The capacity constraint was real but its effect on classification
was negligible — the signal ceiling is in the data, not the encoding fidelity.

### 6E: Eigenvalue Profiling — Intrinsic Dimensionality

**Script**: `eigen_profile.py`

Batch SVD analysis of 500 pixel-encoded vectors at 64×4096D to find the
optimal PCA `k` by measuring the eigenvalue spectrum shape.

#### Per-Stripe Spectrum (4096D)

| Metric | Value |
|--------|-------|
| Total variance | 1790.23 |
| Top-1 PC share | 2.8% |
| Top-5 share | 11.7% |
| Top-10 share | 19.6% |
| Top-32 share | 38.4% |
| Top-64 share | 54.8% |
| Top-128 share | 76.3% |
| 90% variance knee | **k=191** |
| 95% variance knee | k=221 |
| 99% variance knee | k=249 |

Per-stripe 90% knee: min=185, max=198, mean=190.7

BUY 90% knee: mean=189.7 | SELL 90% knee: mean=167.5

#### Flat Vector Spectrum (262,144D)

| Metric | Value |
|--------|-------|
| 90% variance knee | k=413 |
| 95% variance knee | k=455 |
| 99% variance knee | k=490 |
| Top-1 share | 1.6% |
| Top-32 share | 20.4% |
| Top-128 share | 46.7% |

#### Comparison to L7 HTTP Processor (docs/challenges/017-batch, 018-batch)

| Metric | L7 HTTP (8-field) | L7 HTTP (19-field) | BTC Pixel |
|--------|-------------------|--------------------| ----------|
| k @ 90% var | **25** | **66** | **191** |
| k @ 99% var | 53 | 215 | 249 |
| Top-1 PC share | ~10% | ~5.5% | 2.8% |
| Spectrum shape | Sharp two-tier elbow | Clear elbow | **Near-linear decay** |
| Recommended k | 32 | 64 | 229 |

The L7 HTTP data had clear low-dimensional structure: 4 high-cardinality
fields each mapped to a dominant PC, creating a visible elbow in the
spectrum. k=32 captured essentially everything useful.

The BTC pixel data has **no elbow** — variance spreads near-uniformly
across all components. This is characteristic of data where the encoded
features (TA indicators at chart pixels) lack low-dimensional structure
relative to their target (future price direction). The encoding is faithful
but the underlying signal is diffuse.

**Implication for k**: Previous experiments used k=4 (engrams) and k=8
(subspace), which captured <10% of variance — effectively discarding 90%+
of the information. However, raising k to 128-191 merely retains more
noise alongside any marginal signal, since there's no clean signal
subspace to isolate.

## Consolidated Phase 6 Findings

1. **The encoding works correctly** — pixel rendering confirmed
2. **Capacity constraints are real but don't matter for classification** — 
   fixing 32→64 stripes didn't change accuracy
3. **Algebraic introspection (unbind/cleanup) can't isolate pixel-level
   signal** — superposition of ~2k bindings is too dense for clean retrieval
4. **Discriminative resonance methods don't improve OOS accuracy** — the
   discriminant vector itself has low density (1.1% of dimensions)
5. **The eigenvalue spectrum reveals fundamental data structure**: pixel-
   encoded BTC charts have near-uniform variance distribution (no manifold),
   unlike L7 HTTP which had clear low-dimensional structure matching its
   field count
6. **PCA k=4/8 was severely undertrained** but fixing it won't help — 
   there's no compact signal subspace to project onto

## Next Steps (Planned)

1. **Try k=128 per stripe** — even though the spectrum is flat, the top-128
   PCs capture 76% of variance vs 10-20% for k=4/8. Worth testing whether
   the sheer volume of retained information helps subspace-based scoring.

2. **Revisit oracle labels with delayed action** — current `label_oracle_10`
   labels based on price at exactly the decision point. Real trading would
   involve waiting 1–5 periods (5–25 minutes) before acting, to ride a
   developing wave up or down. Need to test labels like:
   - `label_oracle_delayed_1`: Skip 1 candle, then look for 1% move
   - `label_oracle_delayed_3`: Skip 3 candles (~15 min)
   - `label_oracle_delayed_5`: Skip 5 candles (~25 min)
   This addresses whether TA signal exists for *continuation* of a move
   that's already started, rather than predicting the *start* of a move.

## Files

- `holon-lab-trading/scripts/pixel_inspect.py` — Phase 6A: depixelation & introspection
- `holon-lab-trading/scripts/pixel_render_check.py` — Phase 6B: visual encoding verification
- `holon-lab-trading/scripts/pixel_subspace.py` — Phase 6C: discriminative resonance methods
- `holon-lab-trading/scripts/eigen_profile.py` — Phase 6E: eigenvalue profiling
