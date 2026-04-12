# Vocabulary Review — Brian Beckman
*Physicist. Category theorist. Does it compose? Does the algebra close?*

---

## Preamble: The Geometry of the Encoding

Before atom-by-atom analysis, establish the mathematical ground.

**Linear encoding** maps `value/scale` to an angle in `[0, 2π)`, then takes
`cos(angle) * base + sin(angle) * ortho`. Two consequences the vocabulary must
respect:

1. **Periodicity.** The encoding is periodic with period `scale`. A value of
   `1.5 * scale` produces the same vector as `0.5 * scale`. This is *not*
   saturation — it is aliasing. If your data can exceed `scale`, you have
   folded distinct market states onto indistinguishable geometry.

2. **Distance semantics.** The full [0, scale] range maps to a full rotation.
   Values separated by `scale/2` are **orthogonal**. Values separated by
   `scale` are **identical**. The discriminant region — where cosine similarity
   changes meaningfully — is roughly [−scale/4, +scale/4] around any reference
   point. Pack your signal into that window.

**Log encoding** maps `log10(value)` through `encode_linear(..., scale=10.0)`.
One full rotation spans 10 orders of magnitude. This is correct for ratio
quantities — equal ratios produce equal angular separation, which is the
defining property of a multiplicative group. The 0.001 floor on many log-encoded
atoms prevents `log(0)` from returning the zero vector (which would be
geometrically invisible, not "small").

**Circular encoding** wraps at `period`. This is the correct choice for any
quantity with genuine modular structure. Hour and day-of-week are the canonical
examples and are handled correctly throughout.

---

## Module: `market/momentum.rs`

**Atoms:** close-sma20, close-sma50, close-sma200, macd-hist, di-spread, atr-ratio

### `close-sma20`, `close-sma50`, `close-sma200`
```
value = (close - smaN) / close   → Linear, scale=0.1
```
**Type:** Correct. These are fractional deviations — additive after
normalization, so Linear is appropriate. The sign carries direction (above/below
MA), which Linear preserves.

**Scale:** `0.1` means the full rotation spans ±10% deviation. BTC routinely
exceeds ±10% distance from its 200-day MA during trending markets — close-sma200
will alias in strong trends. For `close-sma200` specifically, a value of 0.15
(15% above MA) maps to the same angular region as 0.05 (5% above), but on the
other side of the rotation. The scale for sma200 should be `0.3` or larger, or
you should apply a soft tanh-like clamp before encoding. close-sma20 and
close-sma50 are well-served by `0.1`.

**Precision:** `round_to(..., 4)` — four decimal places on values in [−0.1,
+0.1] gives 0.1mm resolution on a 10cm ruler. Appropriate; no cache thrash.

### `macd-hist`
```
value = macd_hist / close   → Linear, scale=0.01
```
**Type:** Correct. MACD histogram normalized by price is a fractional quantity.
Linear is appropriate.

**Scale:** `0.01` means a 1% price-normalized histogram fills the full rotation.
BTC MACD histograms, when normalized by close price, typically live in the
range [−0.005, +0.005] on 5-minute candles, occasionally spiking to ±0.01
during strong momentum. Scale is tight but not wrong. Consider `0.02` for
headroom during violent moves.

**Precision:** `round_to(..., 4)` on values in [−0.01, +0.01] gives 0.1mm
resolution on a 1cm ruler — marginally over-precise for a cache key but
harmless.

### `di-spread`
```
value = (plus_di - minus_di) / 100.0   → Linear, scale=1.0
```
**Type:** Correct. DI values live in [0, 100], so their difference lives in
[−100, +100]. Normalized by 100, this becomes [−1, +1]. Linear is appropriate.

**Scale:** `1.0` maps the full [−1, +1] range to one full rotation. Values in
[−0.5, +0.5] are the discriminant region (maximum cosine gradient). Strong
trends push di-spread toward ±0.8, which is well within the [−1, +1] range and
correctly encoded. **No issues.**

**Precision:** `round_to(..., 2)` — two decimal places on [−1, +1]. This is
the coarsest rounding in the momentum module. 100 distinct states. Reasonable
for a cache key; coarser than the others by design.

### `atr-ratio`
```
value = atr_r.max(0.001)   → Log
```
**Type:** Correct. ATR ratio (ATR/close) is a ratio quantity — "twice as
volatile" should encode as twice the geometric distance, not twice the linear
distance. Log is the right choice.

**0.001 floor:** ATR ratio rarely falls below 0.001 (0.1% of price) in any
liquid market. Floor is appropriate; it prevents the zero-vector invisibility
problem without hiding meaningful near-zero signals.

**Precision:** `round_to(..., 2)` — two decimal places. Values live in
[0.001, ~0.05] for BTC 5-minute candles. Two decimal places gives:
0.001, 0.01, 0.02, 0.03 — about 50 distinct cache keys across the realistic
range. Slightly coarse; `round_to(..., 3)` would give 5x more resolution at
the cost of more cache misses. Acceptable tradeoff.

---

## Module: `market/regime.rs`

**Atoms:** kama-er, choppiness, dfa-alpha, variance-ratio, entropy-rate,
aroon-up, aroon-down, fractal-dim

### `kama-er` (Kaufman Efficiency Ratio)
```
value = kama_er   → Linear, scale=1.0
```
**Type:** Correct. KAMA ER is bounded [0, 1] by construction — ratio of net
directional movement to total path length. Linear is appropriate.

**Scale:** `1.0`. Full range fills half the rotation. ER rarely hits 1.0
exactly; the realistic range is [0, 0.8]. Well-encoded.

### `choppiness`
```
value = choppiness / 100.0   → Linear, scale=1.0
```
**Type:** Correct. Choppiness Index is bounded [100*log10(1)/log10(N),
100] in theory, and practically [38.2, 100] for standard N=14. Normalized
to [0.382, 1.0]. Linear is appropriate.

**Scale:** `1.0`. Values cluster in [0.4, 1.0]. The bottom half of the Linear
rotation [0, 0.4] is effectively dead space — you're using roughly 60% of
the available discriminant range. Not wrong, but the encoding allocates
geometric distance proportionally: the [0, 0.4] region (unreachable in
practice) gets the same angular budget as [0.4, 1.0]. Consider normalizing
to the actual range [0.382, 1.0] → [0, 0.618] before encoding. Minor issue.

### `dfa-alpha` (Detrended Fluctuation Analysis Hurst exponent)
```
value = dfa_alpha / 2.0   → Linear, scale=1.0
```
**Type:** Correct. DFA alpha is bounded [0, 2] theoretically (0.5 =
random walk, 1.0 = 1/f, >1 = non-stationary). Normalized to [0, 1].
Linear is appropriate.

**Scale:** `1.0`. Clean. However, the meaningful boundary is at 0.5 (= 0.25
normalized). Values below 0.5 (mean-reverting) and above 0.5 (trending) are
the relevant signal. The encoding treats 0.0 and 1.0 as equally far from 0.5,
which is correct. **No issues.**

### `variance-ratio`
```
value = variance_ratio.max(0.001)   → Log
```
**Type:** Correct. Variance ratio tests whether price returns follow a random
walk. Under the null (random walk), VR = 1.0. Deviations are multiplicative —
VR = 2.0 and VR = 0.5 are equally "surprising" from the random walk. Log
encoding captures this multiplicative symmetry. **Correct choice.**

**0.001 floor:** Variance ratio cannot naturally be near zero unless the price
series has near-zero short-run variance, which would be extraordinary. The
floor is a numerical safety guard; it does not hide meaningful signal.

### `entropy-rate`
```
value = entropy_rate   → Linear, scale=1.0
```
**Type:** Conditionally correct. Entropy rate is non-negative and bounded, but
the question is whether differences in entropy rate are additive (→ Linear) or
multiplicative (→ Log). For entropy as a measure of information density,
differences are typically additive (entropy is already in log space from
its definition). Linear is defensible.

**Scale:** `1.0`. If entropy rate is normalized to [0, 1], this is fine.
The implementation does not show the normalization of `c.entropy_rate` — if
it's already in [0, 1], scale=1.0 is correct. If it's in bits (potentially
[0, log2(N)] for N states), it needs normalization or a different scale.
**Unverified assumption: entropy_rate arrives pre-normalized to [0,1].**

### `aroon-up`, `aroon-down`
```
value = aroon_X / 100.0   → Linear, scale=1.0
```
**Type:** Correct. Aroon indicators are bounded [0, 100]. Normalized to [0, 1].
Linear is appropriate.

**Scale:** `1.0`. Correct.

**Redundancy concern:** The bundle simultaneously encodes aroon-up and
aroon-down. These two quantities are *not* independent — they are jointly
determined by the position of the N-period high and N-period low. When
aroon-up is 1.0, aroon-down is typically low. Their correlation is negative
but not perfectly so. The bundle algebra handles linear combinations
automatically, but encoding both separately means the aroon signal is
geometrically weighted twice in the bundle. This is not an error — it means
aroon information contributes more to the thought vector than a single atom
would. Whether this is desirable is a design question, not a mathematical one.
**Flag, not defect.**

### `fractal-dim`
```
value = fractal_dim - 1.0   → Linear, scale=1.0
```
**Type:** Correct. Fractal dimension of price ranges from 1.0 (pure trend) to
2.0 (Brownian motion). Subtracting 1.0 maps to [0, 1]. Linear is appropriate.

**Scale:** `1.0`. Full range uses full rotation. **No issues.**

---

## Module: `market/oscillators.rs`

**Atoms:** rsi, cci, mfi, williams-r, roc-1, roc-3, roc-6, roc-12

### `rsi`
```
value = rsi   → Linear, scale=1.0
```
**CRITICAL DEFECT: WRONG SCALE.**

RSI is bounded [0, 100]. With `scale=1.0`, the value 55 (a typical RSI)
maps to `55/1.0 = 55` rotations — 55 full cycles around the circle. The
vector for RSI=55 is in a completely unpredictable location relative to RSI=56.
The encoding is **aliased into meaninglessness**.

The correct encoding is one of:
- `Linear { value: rsi / 100.0, scale: 1.0 }` — normalize first
- `Linear { value: rsi, scale: 100.0 }` — set scale to the natural range

The test passes because it only checks that the output value is 55.0 — it
never checks that RSI=55 and RSI=54 produce more similar vectors than RSI=55
and RSI=5. The test is insufficient to catch this bug.

**This is a geometric corruption.** RSI carries no distance-preserving signal
in the current encoding.

### `cci`
```
value = cci / 300.0   → Linear, scale=1.0
```
**Type:** Correct. CCI is nominally bounded [−100, +100] for normal markets,
with extreme values extending to ±300 in strong trends. Dividing by 300
maps the extreme range to [−1, +1], which is a reasonable normalization.

**Scale:** `1.0`. The discriminant region is [−0.5, +0.5], which corresponds
to CCI [−150, +150]. Normal market conditions fall within this region. Values
beyond ±150 compress toward ±0.5 and start losing resolution, but this is
acceptable behavior for extreme values. **No issues.**

### `mfi`
```
value = mfi / 100.0   → Linear, scale=1.0
```
**Type:** Correct. Money Flow Index is bounded [0, 100]. Normalized to [0, 1].

**Scale:** `1.0`. **No issues.**

### `williams-r`
```
value = (williams_r + 100.0) / 100.0   → Linear, scale=1.0
```
Williams %R is bounded [−100, 0]. Adding 100 maps to [0, 100]. Dividing
by 100 maps to [0, 1].

**Type:** Correct.

**Scale:** `1.0`. **No issues.**

### `roc-1`, `roc-3`, `roc-6`, `roc-12`
```
value = 1.0 + roc_N   → Log
```
Rate of Change is a return: `(close_t - close_{t-N}) / close_{t-N}`. Adding
1.0 converts it to a growth factor: `close_t / close_{t-N}`.

**Type:** Correct and elegant. Growth factors are ratio quantities —
a 2% gain and a 2% loss are symmetric in log space (both 2% from 1.0),
which is exactly what we want. Log encoding is the right choice.

**1.0 floor issue:** The code computes `1.0 + roc_N` but does not floor it
before passing to the Log encoder. If `roc_N < −1.0` (a −100%+ drop), the
growth factor is ≤ 0.0, and the Log encoder returns the zero vector
(geometrically invisible). In crypto this is extremely rare but not
impossible. A floor like `.max(0.001)` would be defensive.

**Note on near-1.0 behavior:** The log encoder uses `log10`. For growth
factors near 1.0 (small returns), `log10(1.01) ≈ 0.004` — a very small
angle. The Linear encoder at scale=10.0 will quantize these to near the
origin of the rotation. Small returns produce near-identical vectors. This
is geometrically correct: small returns *are* similar. The reckoner learns
to distinguish them by accumulation across many candles.

---

## Module: `market/flow.rs`

**Atoms:** obv-slope, vwap-distance, buying-pressure, selling-pressure,
volume-ratio, body-ratio

### `obv-slope`
```
value = obv_slope_12.exp()   → Log
```
The OBV slope (presumably the rate of OBV change normalized somehow) is
exponentiated before log-encoding. This means:
`log10(exp(obv_slope_12)) = obv_slope_12 / ln(10) ≈ 0.434 * obv_slope_12`

So the effective encoding is Linear with scale `10.0 / 0.434 ≈ 23`. This is
a composition: if `obv_slope_12` is already a log-slope (i.e., a value in
log-return space), then `exp(obv_slope_12)` is a multiplicative factor, and
`log10(exp(...))` recovers a linearly-spaced representation. This is
internally consistent *if* `obv_slope_12` is indeed the slope of log(OBV).

**Type:** The roundtrip `exp → log10` is algebraically clean when the
input is in natural log space. Correct, assuming `obv_slope_12` is in
natural log units.

### `vwap-distance`
```
value = vwap_distance   → Linear, scale=0.1
```
VWAP distance is presumably `(close - vwap) / close` — a fractional
deviation. Scale=0.1 means ±10% VWAP deviation fills the rotation. BTC
can deviate significantly from VWAP on high-volatility days.

**Type:** Correct (fractional, additive deviation).

**Scale:** `0.1` is reasonable for intraday VWAP on a 5-minute timeframe.
Over longer lookback windows, deviations can exceed 10%. **Acceptable.**

### `buying-pressure`, `selling-pressure`
```
value = (close - low) / (high - low)   → Linear, scale=1.0
value = (high - close) / (high - low)  → Linear, scale=1.0
```
Both are bounded [0, 1]. Linear is correct.

**Redundancy observation:** `buying-pressure + selling-pressure = 1.0`
always. They are linearly dependent: `selling-pressure = 1 - buying-pressure`.
This is a linear combination of other encoded atoms, which means the bundle
algebra will include this relationship. However, these are *not* expressed
as linear combinations in the encoding — they are encoded as separate atoms
with separate role vectors.

Encoding both separately adds a second signal to the bundle, but the second
signal carries zero additional information beyond the first (they sum to 1).
This is not a correctness error — the bundle can hold redundant signals —
but it wastes 1 atom worth of geometric budget with a signal that commutes
with the first under any cosine probe. **Recommend encoding only
`buying-pressure`; `selling-pressure` is algebraically derivable.**

### `volume-ratio`
```
value = volume_accel.exp().max(0.001)   → Log
```
Same exp→log pattern as obv-slope. Volume acceleration in log space
exponentiated to a multiplicative factor, then log-encoded. Correct for
ratio quantities.

**0.001 floor:** Prevents zero-vector invisibility. **Correct.**

### `body-ratio`
```
value = |close - open| / (high - low)   → Linear, scale=1.0
```
Bounded [0, 1]. Linear is correct. **No issues.**

---

## Module: `market/persistence.rs`

**Atoms:** hurst, autocorrelation, adx

### `hurst`
```
value = hurst   → Linear, scale=1.0
```
Hurst exponent: H < 0.5 (mean-reverting), H = 0.5 (random walk),
H > 0.5 (trending). Range approximately [0, 1].

**Type:** Correct. Differences in Hurst are additive.

**Scale:** `1.0`. The meaningful signal lives in [0.3, 0.7] for most
financial time series. The encoding allocates equal geometric budget to
[0, 0.3] and [0.7, 1.0] even though Hurst rarely visits those extremes.
Not wrong; the reckoner learns the relevant range empirically.

### `autocorrelation`
```
value = autocorrelation   → Linear, scale=1.0
```
Lag-1 autocorrelation: bounded [−1, +1] by definition.

**Type:** Correct.

**Scale:** `1.0`. Full range fills the rotation. **No issues.**

### `adx`
```
value = adx / 100.0   → Linear, scale=1.0
```
ADX is bounded [0, 100], normalized to [0, 1].

**Type:** Correct.

**Scale:** `1.0`. **No issues.**

---

## Module: `market/price_action.rs`

**Atoms:** range-ratio, gap, consecutive-up, consecutive-down, body-ratio-pa,
upper-wick, lower-wick

### `range-ratio`
```
value = range_ratio.max(0.001)   → Log
```
Range ratio is presumably the current candle's range as a multiple of some
reference range. Ratio quantity → Log is correct.

**0.001 floor:** Prevents zero-vector. **Correct.**

### `gap`
```
value = (gap / 0.05).max(-1.0).min(1.0)   → Linear, scale=1.0
```
Gap (as fraction of price) normalized so that a 5% gap maps to ±1.0.

**Type:** Correct. Gaps are additive fractional quantities.

**Scale:** `1.0`. Values are clamped to [−1, +1]. The clamping means any gap
larger than 5% is represented as the same vector as a 5% gap. On 5-minute BTC
candles, gaps > 5% are extremely rare. **Acceptable.**

### `consecutive-up`, `consecutive-down`
```
value = (1.0 + consecutive_N).max(1.0)   → Log
```
Count of consecutive up/down candles. Adding 1 ensures the value is ≥ 1
(avoiding log(0)). Log encoding is correct — the first consecutive candle vs.
the second is as significant as the 9th vs. the 10th (multiplicative reasoning
about momentum persistence).

**Type:** Correct.

**Redundancy concern:** Like buying-pressure/selling-pressure, these two atoms
are anti-correlated. If consecutive-up = 5, consecutive-down is likely 0 (or 1
at most). They are not algebraically derivable from each other (unlike
buying/selling pressure), but they carry heavily overlapping information.
The bundle algebra handles this gracefully; redundancy here is a signal
amplification choice, not a defect. **Acceptable.**

### `body-ratio-pa`, `upper-wick`, `lower-wick`
All bounded [0, 1], all Linear with scale=1.0.

**Redundancy observation:** `body-ratio-pa + upper-wick + lower-wick ≈ 1.0`
(they partition the candle range). Three atoms whose sum is a constant is a
2-dimensional manifold encoded in 3-dimensional space. You are encoding
one degree of freedom as zero. The bundle will include three atoms' worth
of geometric signal for what is essentially 2 degrees of freedom. This wastes
one atom's geometric budget. **Recommend dropping one** (upper-wick or
lower-wick; keep body-ratio-pa plus one wick as they capture the most
interpretable decomposition).

---

## Module: `market/ichimoku.rs`

**Atoms:** cloud-position, cloud-thickness, tk-cross-delta, tk-spread,
tenkan-dist, kijun-dist

### `cloud-position`
```
value = (close - cloud_mid) / max(cloud_width, close * 0.001)   → Linear, scale=1.0
```
Clamped to [−1, +1]. Measures how far price is above/below the cloud center,
normalized by cloud width.

**Type:** Correct.

**Scale:** `1.0`. Clamped values respect the scale. **No issues.**

**Precision:** `round_to(..., 2)` — 200 distinct states in [−1, +1].
Appropriate for a coarse structural indicator.

### `cloud-thickness`
```
value = (cloud_width / close).max(0.0001)   → Log
```
Cloud width as fraction of price. Ratio quantity. Log is correct.

**0.0001 floor:** More conservative than the 0.001 used elsewhere. This may
create a longer "zero-regime" where cloud-thickness variation below 0.0001
maps to a constant vector. BTC cloud widths rarely fall below 0.01% of price
on 5-minute data, so this floor is safe.

### `tk-cross-delta`, `tk-spread`, `tenkan-dist`, `kijun-dist`
All clamped to [−1, +1], Linear with scale=1.0.

**Type:** Correct for bounded fractional deviations.

**Redundancy observation:** `tk-spread` is `(tenkan - kijun) / (close * 0.01)`.
`tenkan-dist` is `(close - tenkan) / (close * 0.01)`.
`kijun-dist` is `(close - kijun) / (close * 0.01)`.

Note: `tenkan-dist - kijun-dist = (close - tenkan - close + kijun) / (close * 0.01)
= (kijun - tenkan) / (close * 0.01) = -tk-spread`.

So `tk-spread = -(tenkan-dist - kijun-dist)`. The tk-spread atom is a linear
combination of tenkan-dist and kijun-dist. The bundle algebra handles linear
combinations automatically — but here you are encoding the combination
*explicitly as a separate atom*, which means it contributes a duplicate
signal. **tk-spread is algebraically redundant given tenkan-dist and kijun-dist.**
Consider removing it.

---

## Module: `market/keltner.rs`

**Atoms:** bb-pos, bb-width, kelt-pos, squeeze, kelt-upper-dist, kelt-lower-dist

### `bb-pos`, `kelt-pos`
Bollinger Band position and Keltner Channel position — both bounded [0, 1]
(or [−1, +1] depending on definition). Linear, scale=1.0. **Correct.**

### `bb-width`
```
value = bb_width.max(0.001)   → Log
```
Bollinger Band width as fraction of price. Ratio quantity. Log is correct.
Floor is appropriate. **No issues.**

### `squeeze`
```
value = squeeze   → Linear, scale=1.0
```
Squeeze is a ratio: BB width / Keltner width. Values near 0 = compressed
(squeeze on); values > 1 = expanded (squeeze off).

**WRONG TYPE.** Squeeze is a ratio quantity — `bb_width / keltner_width`.
Equal ratios (squeeze at 0.5 vs. 1.0 vs. 2.0) should encode as equal geometric
distances. The correct encoding is **Log**. With Linear at scale=1.0, a squeeze
at 0.1 and 0.2 look equally far apart as 0.8 and 0.9, but the first pair
represents a 2× compression change while the second represents a 1.125×
change. The geometry does not match the market semantics.

**Recommend:** `Log { name: "squeeze", value: squeeze.max(0.001) }`

### `kelt-upper-dist`, `kelt-lower-dist`
```
value = (close - kelt_upper_or_lower) / close   → Linear, scale=0.1
```
Fractional distance from channel bands. Additive, bounded. Linear is correct.
Scale=0.1 means ±10% from the channel bounds fills the rotation.

**Note:** `kelt-upper-dist` is always negative (close < upper band in normal
conditions) and `kelt-lower-dist` is always positive (close > lower band).
The signs encode which side of the bands the price is on. This is useful
signal. **No issues.**

---

## Module: `market/stochastic.rs`

**Atoms:** stoch-k, stoch-d, stoch-kd-spread, stoch-cross-delta

### `stoch-k`, `stoch-d`
```
value = stoch_k / 100.0   → Linear, scale=1.0
value = stoch_d / 100.0   → Linear, scale=1.0
```
Bounded [0, 1]. Linear. **Correct.**

**Redundancy observation:** Stochastic %K and %D are the same quantity at
different smoothing levels. Their information is highly correlated. The
`stoch-kd-spread` atom (K − D) is the incremental information. Encoding
all three means the common signal in K and D is weighted twice in the bundle.
This is a design choice, not a defect. The reckoner can learn to downweight
the common component. **Acceptable, but note the redundancy.**

### `stoch-kd-spread`
```
value = k - d   → Linear, scale=1.0
```
Values in [−1, +1] (since both K and D are in [0, 1]).

**Type:** Correct.

**As noted above:** this is a linear combination of stoch-k and stoch-d
(`spread = k - d`). The bundle algebra handles linear combinations
automatically. Encoding it explicitly adds the linear combination as an
additional geometric signal. Whether this is useful is an empirical question.
Mathematically, it is redundant — the reckoner could learn this combination
from the k and d vectors alone.

### `stoch-cross-delta`
```
value = stoch_cross_delta.max(-1.0).min(1.0)   → Linear, scale=1.0
```
Clamped to [−1, +1]. **Correct.**

---

## Module: `market/fibonacci.rs`

**Atoms:** range-pos-12, range-pos-24, range-pos-48, fib-dist-236,
fib-dist-382, fib-dist-500, fib-dist-618, fib-dist-786

### `range-pos-12`, `range-pos-24`, `range-pos-48`
Position within the N-period high-low range. Bounded [0, 1]. Linear. **Correct.**

**Redundancy observation:** These three atoms encode the same quantity
(position within range) at different lookback windows. They carry overlapping
information. The 48-period high-low range contains the 24-period range which
contains the 12-period range. This is intentional — multi-scale structure is
a genuine signal. **No issues with the type choice.**

### `fib-dist-236` through `fib-dist-786`
```
value = range_pos_48 - fib_level   → Linear, scale=1.0
```
Distance from specific Fibonacci retracement levels.

**CRITICAL ALGEBRAIC REDUNDANCY.** All five fib-dist atoms are linear functions
of `range-pos-48`:
- `fib-dist-236 = range-pos-48 - 0.236`
- `fib-dist-382 = range-pos-48 - 0.382`
- ...

The VSA primer states explicitly: "The bundle algebra handles linear combinations
automatically." These five atoms are not linear combinations of each other in
a nontrivial way — they are each a *shift* of the same underlying signal.
Shifts by constants do not help the encoding because the Linear encoder
already provides a smooth similarity gradient: points near 0.618 are already
similar to each other in the `range-pos-48` encoding.

**What you wanted:** A signal that "price is near the 0.618 level" is more
significant than "price is near 0.619." But Linear encoding with scale=1.0
already produces that signal — `range-pos-48 = 0.618` and `range-pos-48 =
0.617` are nearly identical vectors.

**What you got:** Five additional atoms, each a constant shift of range-pos-48.
These do not add orthogonal information. They add five copies of
essentially the same vector (shifted by a constant), which in the bundle
appears as amplification of the range-pos-48 signal with a fixed offset.
The reckoner sees "strong range-pos-48 signal with a Fibonacci-flavored DC
bias" — not "price is near a specific level."

**Recommendation:** Replace the five fib-dist atoms with a single categorical
atom: `fib-level-nearest`, encoded as a string atom from the set
`{"236", "382", "500", "618", "786", "none"}`. This gives the reckoner a
discrete, orthogonal signal for which Fibonacci level is nearest, with a
cosine distance that doesn't falsely imply continuity between Fibonacci levels.

Or, keep only `range-pos-48` and discard all fib-dist atoms — the reckoner
can learn that 0.618 is meaningful without being explicitly told.

---

## Module: `market/divergence.rs`

**Atoms:** rsi-divergence-bull, rsi-divergence-bear, divergence-spread

### `rsi-divergence-bull`, `rsi-divergence-bear`
```
value in (0.0, 1.0]   → Linear, scale=1.0   (conditional emission)
```
**Type:** Correct given the bounded range.

**Conditional emission pattern:** Only emitted when non-zero. This is correct
behavior — a zero divergence is not the same as a weak divergence; it is the
absence of the signal. Omitting the atom from the bundle when zero means the
bundle vector does not include that bound pair, which is geometrically correct:
the presence of a field in the bundle encodes "this signal is active," not
"this signal is zero."

### `divergence-spread`
```
value = bull - bear   → Linear, scale=1.0
```
Values in [−1, +1] (since both are in [0, 1]).

Same redundancy observation as stoch-kd-spread: this is a linear combination
of the two individual atoms. The bundle algebra will naturally produce a
signal reflecting their difference. Encoding it explicitly amplifies
the directional divergence signal. Defensible design choice.

---

## Module: `market/timeframe.rs`

**Atoms:** tf-1h-trend, tf-1h-ret, tf-4h-trend, tf-4h-ret, tf-agreement,
tf-5m-1h-align

### `tf-1h-trend`, `tf-4h-trend`
```
value = tf_Nh_body (clamped?)   → Linear, scale=1.0
```
The candle body of the 1h/4h candle. If this is an absolute price change
(not normalized), the scale is wrong — price in BTC terms is enormous.
If it is already a fractional return (normalized), scale=1.0 may be correct.

**UNVERIFIED ASSUMPTION.** The comment says "atoms: tf-1h-trend, tf-1h-ret"
and the code reads `c.tf_1h_body`. If `tf_1h_body` is the raw body in BTC
price units (e.g., close − open in dollars), then encoding with scale=1.0
produces `value/1.0 = value`, and a 200-dollar body movement would complete
200 full rotations, aliasing completely. **Must verify that `tf_1h_body` is
a normalized return, not an absolute price change.**

### `tf-1h-ret`, `tf-4h-ret`
```
value = tf_Nh_ret   → Linear, scale=0.1
```
Higher timeframe returns. Scale=0.1 implies these are fractional returns
in the ±10% range. Plausible for 1h and 4h BTC returns.

**Type:** Returns could be Log (as multiplicative growth factors), but Linear
is defensible for small returns where the approximation `log(1+r) ≈ r` holds.
For 4h returns that can reach ±5%, the approximation is adequate.

### `tf-agreement`
```
value = tf_agreement   → Linear, scale=1.0
```
Bounded [0, 1] (or [−1, +1]). Linear. **Correct if bounded.**

### `tf-5m-1h-align`
```
value = sign(tf_1h_body) * (close - open) / close   → Linear, scale=0.1
```
A signed 5-minute return, where the sign is determined by the 1-hour
trend direction. Bounded approximately [−1, +1] for extreme cases.
Scale=0.1 means ±10% fills the rotation. **Correct.**

---

## Module: `market/standard.rs`

**Atoms:** since-rsi-extreme, since-vol-spike, since-large-move,
dist-from-high, dist-from-low, dist-from-midpoint, dist-from-sma200,
session-depth

### `since-rsi-extreme`, `since-vol-spike`, `since-large-move`
```
value = count.max(1.0)   → Log
```
Count of candles since the last event. Ratio quantity — the difference between
1 candle ago and 2 candles ago is as significant as the difference between
10 and 20 candles ago. Log is correct.

**Floor at 1.0:** Prevents the zero-vector (count=0 means the event is happening
now, which maps to log10(1) = 0, at the base of the rotation). Correct behavior.

### `dist-from-high`, `dist-from-low`, `dist-from-midpoint`, `dist-from-sma200`
```
value = (price - reference) / price   → Linear, scale=0.1
```
Fractional price deviations. Additive. Linear is correct. Scale=0.1. **No issues.**

**Redundancy observation:** `dist-from-midpoint = (dist-from-high + dist-from-low) / 2`
approximately (not exactly, due to the close-price normalization, but approximately).
This is a near-linear combination of the other two. The bundle will represent
the midpoint information redundantly. Minor issue; the reckoner can learn to
weight accordingly.

### `session-depth`
```
value = (1.0 + n).max(1.0)   → Log
```
Number of candles processed in the current session. Log encoding — correct,
as the distinction between candle 1 and candle 2 is as significant as between
candle 100 and candle 200 in terms of information accumulation. **No issues.**

---

## Exit Modules

### `exit/volatility.rs`

**Redundancy with market/momentum.rs:** `atr-ratio` is encoded identically in
both modules (same computation: `atr_r.max(0.001)`, Log). The exit observer
includes both its own exit-volatility facts and the market thoughts, so `atr-ratio`
appears twice in the broker's input bundle. Same for `squeeze` and `bb-width`.
This is not a correctness error — it amplifies these signals in the broker's
view — but it is implicit duplication. Whether this is intentional emphasis
or accidental redundancy should be explicit in the design.

**`atr-r`** (raw ATR value in price units):
```
value = atr.max(0.001)   → Log
```
If this is ATR in BTC price units (e.g., $500), then the Log encoding
compresses the range `log10(500) ≈ 2.7`. The encoder uses scale=10.0
internally for log, so 2.7 maps to 27% of a full rotation. This is
distinguishable from ATR=$100 (log10=2.0, 20% of rotation). **Correct.**

However, `atr-r` and `atr-ratio` encode very similar information: ATR absolute
vs. ATR normalized by price. Their correlation is extremely high. Encoding both
is redundant. The normalized version (atr-ratio) is strictly more informative
across different price levels. **Recommend removing `atr-r` from the exit
vocabulary; `atr-ratio` already captures the volatility signal.**

**`atr-roc-6`, `atr-roc-12`**:
```
value = atr_roc_N   → Linear, scale=1.0
```
Rate of change of ATR. If defined as `(atr_t - atr_{t-N}) / atr_{t-N}`, this
is a fractional change. Linear at scale=1.0 means ±100% ATR change fills the
rotation. Reasonable.

**WRONG TYPE if atr-roc is a ratio of ratios.** If atr-roc is defined as
`atr_{ratio,t} / atr_{ratio,t-N}`, then it is a multiplicative quantity and
should be Log-encoded. **Must verify the definition of `atr_roc_N` in the Candle struct.**

### `exit/structure.rs`

**`trend-consistency-6`, `trend-consistency-12`, `trend-consistency-24`**:
All Linear, scale=1.0. Assuming these are bounded [0, 1] (fraction of candles
moving in the same direction). **Correct type and scale.**

**Redundancy observation:** Three trend-consistency atoms at different lookback
windows are correlated. This is intentional multi-scale encoding. The
reckoner benefits from seeing the same signal at different time horizons.
**Acceptable.**

**`exit-kama-er`** duplicates `kama-er` from `market/regime.rs` with the same
encoding. Same comment as the volatility duplication — intentional emphasis
or accidental redundancy?

### `exit/timing.rs`

**RSI appears here again** as `Linear { value: rsi, scale: 1.0 }`.

**SAME CRITICAL DEFECT as market/oscillators.rs.** RSI in [0, 100] encoded
with scale=1.0 produces 100 full rotations. The signal is geometrically
corrupted. **Must normalize: `rsi / 100.0` with scale=1.0, or `rsi` with
scale=100.0`.**

**`macd-hist`** here is also `Linear` with `scale=0.01` (after normalization
by close). Same encoding as in momentum.rs. **No additional issues.**

**`cci`** here is `Linear, scale=1.0` after dividing by 300. Same as in
oscillators.rs. **No issues.**

### `exit/regime.rs`

Exact duplicate of `market/regime.rs` encoding logic. All the same findings
apply. The `variance-ratio` Log is correct. The kama-er/choppiness/aroon
analyses carry over identically.

### `exit/time.rs`

`Circular { period: 24.0 }` for hour and `Circular { period: 7.0 }` for
day-of-week. **Correct. The canonical examples of circular encoding.**

### `exit/self_assessment.rs`

**`exit-grace-rate`**: Linear, scale=1.0, bounded [0, 1]. **Correct.**

**`exit-avg-residue`**: Log, floored at 0.001.
Residue is a positive magnitude (some measure of trade outcome). Log is
correct — the difference between a 0.001% and 0.002% residue is as
significant as between 1% and 2%. **Correct.**

---

## Broker Modules

### `broker/self_assessment.rs`

**`grace-rate`**: Linear, scale=1.0, bounded [0, 1]. **Correct.**

**`paper-duration-avg`**: Log. Count of candles. Same as session-depth — Log
is correct for count quantities. **Correct.**

**`paper-count`**: Log. Count of open papers. Log is correct — having 2 papers
vs. 4 is as significant as having 10 vs. 20. **Correct.**

**`trail-distance`, `stop-distance`**: Log, floored at 0.001. These are
fractional price distances (e.g., 1.5% = 0.015). Log is correct — a 1.5%
stop and 3% stop represent a 2× structural difference, same as 3% vs. 6%.
**Correct.**

**`recalib-freshness`**: Log. Candle count since recalibration. Log is correct.

**`excursion-avg`**: Log, floored at 0.001. Fractional excursion. Log is correct
for ratio quantities. **Correct.**

### `broker/opinions.rs`

**`market-direction`**: Linear, scale=1.0, range [−1, +1]. **Correct.**

**`market-conviction`**: Linear, scale=1.0, range [0, 1]. **Correct.**

**`market-edge`**: Linear, scale=1.0, range [0, 1]. **Correct.**

**`exit-trail`, `exit-stop`**: Log, floored at 0.001. Fractional distances.
**Correct.** Same reasoning as broker self-assessment.

**`exit-grace-rate`**: Linear, scale=1.0. **Correct.**

**`exit-avg-residue`**: Log, floored at 0.001. **Correct.**

---

## Cross-Cutting Mathematical Concerns

### 1. The RSI Bug: Unscaled Bounded Quantities

**Severity: High.** Found in two places:
- `market/oscillators.rs`: `Linear { value: rsi, scale: 1.0 }` where RSI ∈ [0, 100]
- `exit/timing.rs`: same

RSI ranges over [0, 100]. With scale=1.0, the angle is `rsi/1.0 * 2π`, which
completes 100 full rotations as RSI goes from 0 to 100. The similarity function
is `cos(angle_a - angle_b)` which is periodic in the difference. RSI=5 and
RSI=105 (impossible, but illustratively) would be identical. More concretely,
RSI=55 and RSI=54 produce vectors that differ by `cos(2π) − cos(2π * 54/55)` —
a 1/55 rotation, which still produces a small but non-zero cosine difference.
But RSI=55 and RSI=105 would be *identical*, and RSI=55 and RSI=5 would be
*nearly identical* (both near the `55/1.0 = 55`-rotation mark). The geometry
is scrambled.

Fix: `Linear { value: rsi / 100.0, scale: 1.0 }` or `Linear { value: rsi, scale: 100.0 }`.

### 2. The Squeeze Bug: Ratio Quantity Encoded as Linear

**Severity: Medium.** Found in `market/keltner.rs`:
- `squeeze = bb_width / kelt_width` is a ratio
- Encoded as `Linear, scale=1.0`

The squeeze compresses from above 1.0 (expanded) toward 0 (maximum compression).
The meaningful comparison is multiplicative: squeeze=0.5 and squeeze=0.25 are
as different as squeeze=1.0 and squeeze=0.5. Linear encoding treats 0.5→0.25
as the same distance as 0.75→0.5. Log encoding would correctly represent the
multiplicative structure.

### 3. The Fibonacci Redundancy: Shifts Are Not Information

**Severity: Medium.** Found in `market/fibonacci.rs`:
- `fib-dist-236` through `fib-dist-786` are all `range_pos_48 - constant`
- These are not additional information; they are constant shifts of the same signal
- The Linear encoder's smooth gradient already captures "proximity to any value"
- These five atoms add geometric weight to range_pos_48 without adding orthogonal structure

### 4. Systematic Linear Combination Redundancy

**Severity: Low (design choice, not defect).** Multiple modules encode
quantities that are linear combinations of other encoded quantities:
- `selling-pressure = 1 - buying-pressure`
- `stoch-kd-spread = stoch-k - stoch-d`
- `divergence-spread = bull - bear`
- `tk-spread = -(tenkan-dist - kijun-dist)` (approximately)
- `body-ratio-pa + upper-wick + lower-wick ≈ 1`
- `dist-from-midpoint ≈ (dist-from-high + dist-from-low) / 2`

The bundle algebra handles linear combinations automatically. Encoding them
explicitly amplifies the signal but does not add new orthogonal information.
The mathematical consequence: these quantities influence the reckoner's noise
subspace — they contribute to the "what we always see" baseline and may
crowd out weaker orthogonal signals.

### 5. The 0.001 Floor: When Is It Wrong?

All Log-encoded atoms with a `.max(0.001)` floor produce identical vectors
for any value ≤ 0.001. This is appropriate when values near zero represent
"negligible" (e.g., ATR near zero means no volatility — a legitimate,
if rare, market state). But consider:

**`exit-avg-residue`**: If residue = 0.0001 (very good exit performance) is
clamped to 0.001, it is indistinguishable from residue = 0.0008 (mediocre
performance). Both look like 0.001 to the encoder. If residue varies in the
range [0.0001, 0.01], the floor at 0.001 cuts off the most precise performance
information. Consider lowering the floor to 0.0001, or more carefully defining
the expected range before flooring.

### 6. Unverified Candle Field Definitions

Several encoding choices depend on whether the raw candle field is already
normalized. The review flagged:
- `tf_1h_body` / `tf_4h_body`: are these fractional returns or raw price deltas?
- `entropy_rate`: is this pre-normalized to [0, 1]?
- `atr_roc_N`: is this a fractional change or a multiplicative factor?

If any of these are raw price-level quantities encoded with small scales, the
periodicity aliasing problem applies.

### 7. The atr-r vs. atr-ratio Duplication in Exit Vocab

`exit/volatility.rs` encodes both `atr-ratio` (ATR/close, Log) and `atr-r`
(raw ATR, Log). These are `ratio = raw_atr / close`, so `raw_atr = ratio * close`.
Given that `close` varies slowly relative to `ratio`, these two atoms are
highly correlated. Encoding both means the exit observer's volatility signal
is geometrically doubled. The raw ATR in price units adds no structural
information beyond what the ratio already captures. **Remove `atr-r`.**

---

## Summary Table: Defects by Severity

| Module | Atom | Issue | Severity |
|--------|------|-------|----------|
| oscillators, exit/timing | rsi | scale=1.0 for [0,100] → 100 rotations, aliased | **High** |
| keltner | squeeze | ratio quantity, needs Log not Linear | **Medium** |
| fibonacci | fib-dist-* | 5 atoms = constant shifts of range-pos-48, no new information | **Medium** |
| exit/volatility | atr-r | highly correlated with atr-ratio, redundant | **Low** |
| price_action | body+upper+lower wicks | 3 atoms for 2 degrees of freedom | **Low** |
| ichimoku | tk-spread | = -(tenkan-dist - kijun-dist), algebraically redundant | **Low** |
| flow | buying+selling pressure | sum = 1.0, one is redundant | **Low** |
| momentum | close-sma200 | scale=0.1 may alias in strong trends (>10% from MA) | **Low** |
| All Log atoms | 0.001 floor | may hide meaningful sub-0.001 signal in exit-avg-residue | **Minor** |

---

*Does it compose? Mostly. The critical defects (RSI scale, squeeze type) corrupt
the geometry for two of the most commonly used oscillators. The redundancies
are design choices, but encoding linear combinations explicitly wastes geometric
budget that could be orthogonal signal. Fix the scale defects first.*
