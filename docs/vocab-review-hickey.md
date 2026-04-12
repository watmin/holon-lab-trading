# Vocabulary Review — Rich Hickey Edition

*Written from the perspective of a designer who thinks in values, not places. Who asks "is it simple?" before "does it work?" Who rejects complecting distinct concerns.*

---

## What I Am Evaluating

Every atom in every module. For each: encoding type, scale, name honesty, duplication, missing signal, useless signal. Then cross-cutting patterns.

The machinery: Linear interpolates between two orthogonal basis vectors proportional to value's position in [-scale, +scale]. Log does the same but on a logarithmic axis — for ratios and quantities that span orders of magnitude. Circular encodes periodicity. Use the wrong one and you have corrupted geometry, not wrong logic.

Total atoms across all modules: approximately 100+. I will go module by module, then summarize.

---

## Market Vocabulary

### `momentum.rs` — 6 atoms

**`close-sma20`** — `(close - sma20) / close`, Linear, scale 0.1
- Encoding type: correct. This is a bounded ratio, approximately in [-0.3, +0.3] for BTC.
- Scale: 0.1 means saturation at ±10% deviation. BTC can diverge from its 20-period SMA by more than 10% in trending markets. Consider 0.2. Currently, values beyond ±10% get collapsed to the same geometry as ±10%. The scale is too tight for a trending asset.
- Name: honest. "close relative to its 20-period moving average."
- Note: All three SMA-distance atoms share the same scale=0.1. This is wrong — sma200 deviation is structurally larger than sma20 deviation. A 10% deviation from the 200-period average is a major macro regime signal; a 10% deviation from the 20-period average is a routine momentum swing. They should have different scales.

**`close-sma50`** — Linear, scale 0.1
- Same critique as close-sma20. Scale should be ~0.15.

**`close-sma200`** — Linear, scale 0.1
- Scale should be ~0.3. The 200-SMA is a macro trend anchor; BTC routinely runs 20-30% away from it in bull markets. Scale=0.1 collapses all "far above the 200MA" states into the same geometry, which destroys discriminative power at the regime boundary most worth learning.

**`macd-hist`** — `macd_hist / close`, Linear, scale 0.01
- Encoding type: correct for a signed difference that can go negative.
- Scale: macd_hist normalized by close — this is a dimensionless ratio. The natural range depends on MACD parameters (12/26/9 standard). Typical values are tiny fractions (0.001 to 0.003 of price). Scale=0.01 seems calibrated. Verify against actual data. If the typical range is ±0.003, scale=0.01 is loose (uses ~30% of the scale range). Tighter would be more discriminative.
- Name: "macd-hist" — honest. This is the MACD histogram.

**`di-spread`** — `(plus_di - minus_di) / 100.0`, Linear, scale 1.0
- Encoding type: correct. The DI spread is bounded [-1, +1] after this normalization.
- Scale: 1.0 matches the range. Correct.
- Name: "di-spread" — honest. +DI minus -DI measures directional dominance.
- Note: plus_di and minus_di individually are discarded. Only the spread is kept. The spread tells you dominance but not absolute directional strength. ADX captures overall strength. This is likely fine but note that a di-spread of +0.2 means something different when ADX=50 (strong trend) vs ADX=15 (choppy). The modules don't compose this for you.

**`atr-ratio`** — `c.atr_r.max(0.001)`, Log
- Encoding type: correct. ATR as a ratio to price is an unbounded positive ratio. Spans orders of magnitude from low-volatility to crisis.
- Name: "atr-ratio" — honest.
- **DUPLICATION ALERT**: `atr-ratio` appears identically in `exit/volatility.rs` with the same computation `c.atr_r.max(0.001)` and Log encoding. This is the same atom with two names that happen to be the same. When both are in the composed vector (market + exit), the atom appears twice. Bundling the same atom with itself doubles its weight relative to other atoms. This is likely unintentional. Either (a) move it to shared and reference once, or (b) distinguish what the market observer is measuring vs what the exit observer is measuring.

---

### `regime.rs` — 8 atoms

**`kama-er`** — `c.kama_er`, Linear, scale 1.0
- Encoding type: correct. Efficiency ratio is in [0, 1] by definition.
- Scale: 1.0 matches the range.
- Name: "kama-er" — "kama efficiency ratio" — honest enough.
- **DUPLICATION**: Appears identically in `exit/structure.rs` as `exit-kama-er`. Same field, same computation, different name. The name distinction is honest — it acknowledges the duplication — but the cost is that the reckoner sees two slightly different atoms encoding the same information. That's probably fine for the exit observer (it's learning a different thing) but worth noting.

**`choppiness`** — `c.choppiness / 100.0`, Linear, scale 1.0
- Encoding type: correct. Choppiness index is bounded [0, 100], normalized to [0, 1].
- Scale: 1.0. Correct.
- Name: "choppiness" — speaks. A low value means trending; high means choppy.

**`dfa-alpha`** — `c.dfa_alpha / 2.0`, Linear, scale 1.0
- Encoding type: The DFA (Detrended Fluctuation Analysis) alpha naturally lives in [0.5, 1.5] approximately. Dividing by 2 maps it to [0.25, 0.75] — only using half the scale range. The midpoint (0.5 = 1.0/2.0) represents Brownian motion; values above indicate persistence, below mean-reversion.
- **Bug**: The scale should be centered. DFA alpha of 0.5 (pure random walk) should map to the midpoint of the encoding space, not 0.25. The transformation should be `(dfa_alpha - 0.5) / 0.5` or similar, mapping [0, 1] range centered at 0.5 (random walk). As written, pure randomness maps to 0.25, persistence maps to 0.75, and the geometry is off-center.
- Name: "dfa-alpha" — honest.

**`variance-ratio`** — `c.variance_ratio.max(0.001)`, Log
- Encoding type: Log is correct. The variance ratio is a positive ratio that can span a meaningful range around 1.0.
- Name: "variance-ratio" — honest.
- **DUPLICATION**: Identical in `exit/regime.rs` as "variance-ratio" — same name, same encoding, same candle field. The exit regime module is a literal copy of the market regime module. This is complecting "market characterization for prediction" with "market characterization for exit timing." The distinction may be real but the identical naming makes the two atoms collision candidates when composed. The atom names in the composed vector will match — "variance-ratio" from market and "variance-ratio" from exit — and bundling them doubles the weight of this signal.

**`entropy-rate`** — `c.entropy_rate`, Linear, scale 1.0
- Encoding type: depends on the range of entropy_rate. If it's bounded [0, 1] (normalized), Linear is correct. If unbounded, Log is needed. The code does no clamping, suggesting it's assumed bounded. This is an assumption worth verifying.
- Name: "entropy-rate" — honest.

**`aroon-up`** — `c.aroon_up / 100.0`, Linear, scale 1.0
- Encoding type: correct. Aroon is bounded [0, 100], normalized to [0, 1].
- Scale: 1.0. Correct.
- Name: "aroon-up" — honest.

**`aroon-down`** — `c.aroon_down / 100.0`, Linear, scale 1.0
- Same as above. Correct.
- Note: aroon-up and aroon-down together encode directional momentum via time since extremes. They are complementary, not redundant — keep both. The *spread* (aroon-up minus aroon-down) is also a useful derived signal. It currently doesn't appear as its own atom, though the two individual values let the learner construct this implicitly.

**`fractal-dim`** — `c.fractal_dim - 1.0`, Linear, scale 1.0
- Encoding type: Fractal dimension lives in [1.0, 2.0] for a 1D time series. Subtracting 1.0 gives [0.0, 1.0]. Linear with scale 1.0 is correct.
- **Centering question**: FD=1.0 means a smooth trend; FD=2.0 means space-filling noise. FD=1.5 is Brownian. After the transform, FD=1.5 maps to 0.5 — the midpoint. This is correctly centered.
- Name: "fractal-dim" — honest.

**Summary for regime**: The module has a copy-paste duplication problem. `exit/regime.rs` is essentially identical. The same atom names appearing in both market and exit composed vectors will collide and double-weight those signals without intent. This is the most important structural issue in the vocab.

---

### `oscillators.rs` — 8 atoms

**`rsi`** — `c.rsi`, Linear, scale 1.0
- **Wrong scale**. RSI lives in [0, 100]. Linear with scale 1.0 means the interpolation runs from -100 to +100. But RSI=0 is extreme oversold and RSI=100 is extreme overbought. The encoding treats RSI=50 as the midpoint geometrically — but in VSA linear encoding, the "zero" of the interpolation isn't the midpoint of the value range.

Wait. Let me re-examine. Linear encoding in holon-rs: `value / scale` determines where you sit between the two basis vectors. A value of `scale` gives one basis vector; `-scale` gives the other; `0` gives their midpoint. So for RSI with scale=1.0: RSI=1.0 would be fully at one pole, RSI=-1.0 at the other. But RSI is always positive [0,100]. This means all RSI values cluster in one half of the geometry.

- **Bug**: RSI should either be (a) normalized to [0,1] first with scale=1.0, meaning `c.rsi / 100.0` with scale=1.0, or (b) left as raw [0,100] with scale=100.0. As written, `c.rsi` with scale=1.0 means an RSI of 70 is encoding the value 70 on a scale of ±1. The encoder will probably clamp or saturate. This needs investigation, but the normalization is clearly inconsistent with how other bounded [0,100] indicators are handled (CCI uses /300, MFI uses /100, stoch uses /100 — all normalize first).

**`cci`** — `c.cci / 300.0`, Linear, scale 1.0
- CCI lives roughly in [-200, +200] in normal conditions, with extremes to ±300. Dividing by 300 gives [-0.67, +0.67] typical, [-1.0, +1.0] extreme. Scale 1.0 is approximately correct.
- Name: "cci" — honest.

**`mfi`** — `c.mfi / 100.0`, Linear, scale 1.0
- MFI [0, 100], normalized to [0, 1]. Scale 1.0. Correct.
- Name: "mfi" — honest.

**`williams-r`** — `(c.williams_r + 100.0) / 100.0`, Linear, scale 1.0
- Williams %R lives in [-100, 0]. After +100 and /100, it becomes [0, 1]. Scale 1.0 correct.
- Name: "williams-r" — honest.

**`roc-1`, `roc-3`, `roc-6`, `roc-12`** — `1.0 + c.roc_N`, Log
- Rate of change + 1.0 gives a ratio around 1.0. Log encoding is exactly right for ratios — the geometry correctly treats +2% and -2% as symmetric around neutral.
- Names: "roc-1" etc — honest, clear period.
- Note: Four ROC atoms at different periods is a lot of correlated signal. ROC-1 and ROC-3 will be highly correlated in trending markets. The learner's noise subspace will discover this, but it costs representation budget. Consider whether ROC-3 and ROC-6 carry marginal information beyond ROC-1 and ROC-12. In practice, the cross-period structure (fast vs slow) is the useful information, so having multiple is probably correct. But examine the pair correlations.

**Summary for oscillators**: The RSI encoding is suspect — not normalized before applying scale=1.0 unlike all other bounded [0,100] indicators. All other normalizations in this module are careful. RSI stands out.

---

### `flow.rs` — 6 atoms

**`obv-slope`** — `c.obv_slope_12.exp()`, Log
- `obv_slope_12` is presumably the slope of OBV (a log-space slope, i.e., the coefficient). Taking exp() converts it to a ratio around 1.0. Log encoding then handles ratios symmetrically. This chain is correct.
- Name: "obv-slope" — tells you what it is but not the time horizon. "obv-slope-12" would be more honest given the 12-period window.

**`vwap-distance`** — `c.vwap_distance`, Linear, scale 0.1
- VWAP distance as a fraction of price. If this is `(close - vwap) / close`, it's a signed ratio bounded roughly [-0.05, +0.05] in normal markets. Scale 0.1 gives saturation at ±10%, which is loose but safe.
- Name: "vwap-distance" — honest.

**`buying-pressure`** — `(close - low) / range`, Linear, scale 1.0
- This is the normalized close position in the range — the "position within candle" metric. Range [0, 1]. Scale 1.0. Correct.
- Name: "buying-pressure" — this is a name that tells a story rather than what it is. The formula is "how high in the range did we close." It implies buying pressure only if you accept the price action interpretation. The name is a theory embedded in a fact. Consider "close-in-range" for honesty. But it's evocative enough to be useful — the observer can learn whether this theory holds.

**`selling-pressure`** — `(high - close) / range`, Linear, scale 1.0
- Symmetric complement to buying-pressure. Range [0, 1].
- Name: "selling-pressure" — same critique. Call it "upper-wick-relative" or "how far close is from high."
- **Dependency**: buying-pressure + selling-pressure = 1.0 - body_ratio. These three are not independent. If you know buying-pressure and selling-pressure, you know body_ratio. Including all three adds no information but costs vector budget. One of these three is redundant.

**`volume-ratio`** — `c.volume_accel.exp().max(0.001)`, Log
- Same pattern as obv-slope: exp of a log-ratio, then Log encoding. Correct for a ratio.
- Name: "volume-ratio" — honest.

**`body-ratio`** — `abs_body / range`, Linear, scale 1.0
- Fraction of the range that's body. [0, 1]. Scale 1.0. Correct.
- Name: "body-ratio" — honest.
- **Redundancy noted above**: body-ratio, buying-pressure, selling-pressure are collinear. Consider dropping selling-pressure (the rarest signal of the three).

---

### `persistence.rs` — 3 atoms

**`hurst`** — `c.hurst`, Linear, scale 1.0
- Hurst exponent [0, 1] approximately. H > 0.5 = trending, H < 0.5 = mean-reverting, H = 0.5 = random. Linear scale 1.0. Correct.
- **Centering note**: H=0.5 maps to 0.5 in the value, not to 0.0. The "neutral" of the geometry (value=0) doesn't correspond to the "neutral" of the indicator (random walk). This is a consistent pattern in this codebase — many indicators [0,1] are not centered at neutral. Whether this matters depends on how Linear encoding handles the midpoint, but it means "random walk" doesn't have a privileged geometric position.
- Name: "hurst" — honest.

**`autocorrelation`** — `c.autocorrelation`, Linear, scale 1.0
- Autocorrelation [-1, +1]. Scale 1.0. Correctly centered at zero.
- Name: "autocorrelation" — honest.
- **Redundancy with hurst**: Both measure serial dependency in the price series. Hurst is a long-range dependence measure; autocorrelation (at lag 1?) is a short-range measure. They are not redundant but they are correlated. At lag 1, they'll often agree. What lag does `c.autocorrelation` use? The name is ambiguous — "autocorrelation at lag 1" vs "mean autocorrelation across lags" carry different information.

**`adx`** — `c.adx / 100.0`, Linear, scale 1.0
- ADX [0, 100], normalized to [0, 1]. Correct.
- Name: "adx" — honest.
- **DUPLICATION**: Appears in `exit/structure.rs` as "adx" with identical computation. Same atom, same candle field, same encoding. When the exit observer's facts are composed with market facts, this atom will be present twice if the market observer is Regime lens (which includes persistence, which has adx). Actually: market Regime lens gets persistence (adx) + regime; exit gets structure (adx) + ... So the broker's composed vector has adx from two sources. Doubled weight.

---

### `price_action.rs` — 7 atoms

**`range-ratio`** — `c.range_ratio.max(0.001)`, Log
- If range_ratio is current candle range / rolling average range, it's a positive ratio centered near 1.0. Log encoding is exactly right.
- Name: "range-ratio" — honest.

**`gap`** — `(c.gap / 0.05).max(-1.0).min(1.0)`, Linear, scale 1.0
- Gap normalized by 5% reference scale and clamped to [-1, +1]. For a 5-minute BTC candle, gaps are near zero almost always — BTC trades 24/7 continuously. A gap here would mean the data feed has holes, not an open-above-close pattern.
- **Possibly useless**: On a 5-minute continuous 24/7 market, gaps are almost never present. This atom will be near zero essentially always. It provides no discrimination. If the candle series is complete (no missing bars), this is dead signal.
- Name: "gap" — honest, but encoding something that doesn't exist.

**`consecutive-up`** — `(1.0 + c.consecutive_up).max(1.0)`, Log
- Count of consecutive up candles + 1. Log encodes the ratio — a run of 4 vs 1 is geometrically different from 8 vs 4. Correct for count data.
- Name: "consecutive-up" — honest.

**`consecutive-down`** — symmetric. Same analysis.

**`body-ratio-pa`** — same as `body-ratio` in flow.rs
- **DUPLICATION**: This is explicitly "body-ratio in price-action module." The comment suffix "-pa" exists to avoid name collision with flow.rs's "body-ratio." But they compute identically: `|close - open| / range`. Two different atom names encoding the exact same function of the same candle fields. This is not a thoughtful distinction — it's a workaround for module-level naming. The underlying thought is the same thought. Use one name.

**`upper-wick`** — `upper_wick / range`, Linear, scale 1.0
- Fraction of range that's upper wick. [0, 1]. Scale 1.0. Correct.
- Name: "upper-wick" — honest.

**`lower-wick`** — `lower_wick / range`, Linear, scale 1.0
- Same. Correct.
- **Dependency again**: upper-wick + lower-wick + body-ratio-pa = 1.0 (within a candle). All three are perfectly collinear. You have two redundant atoms here (or rather: three atoms, only two are independent). Drop one. The reckoner's noise subspace will discover this eventually, but it wastes vector budget.

---

### `ichimoku.rs` — 6 atoms

**`cloud-position`** — `(close - cloud_mid) / cloud_width`, Linear, scale 1.0, clamped [-1, +1]
- When inside the cloud, this is a fractional position. When outside, it saturates to ±1. Correct design — cloud position is a bounded qualitative state.
- Name: "cloud-position" — honest.
- Note: the degenerate case (zero-width cloud) uses a fallback: `(close - cloud_mid) / (close * 0.01)`. This means a zero-width cloud is treated as if it has 1% width. This is reasonable engineering but means the atom can't encode "we are at a Senkou B cross" distinctly — it just reports position relative to a point.

**`cloud-thickness`** — `cloud_width / close`, Log
- Cloud thickness as fraction of price. Positive ratio. Log encoding correct.
- Name: "cloud-thickness" — honest.

**`tk-cross-delta`** — `clamp(c.tk_cross_delta, -1.0, 1.0)`, Linear, scale 1.0
- This encodes the TK cross — presumably the difference in Tenkan and Kijun, normalized. Clamped to [-1, +1]. Correct.
- Name: "tk-cross-delta" — honest.

**`tk-spread`** — `(tenkan - kijun) / (close * 0.01)`, Linear, scale 1.0, clamped
- Spread as fraction of price (using 1% of close as unit). Clamped to [-1, +1].
- Name: "tk-spread" — honest.
- **Relationship with tk-cross-delta**: tk-spread and tk-cross-delta are measuring the same thing from different angles. tk-spread is the current spread; tk-cross-delta is presumably the change in the spread (momentum of the TK relationship). These are complementary and distinct. Keep both.

**`tenkan-dist`** and **`kijun-dist`** — both `(close - X) / (close * 0.01)`, Linear, scale 1.0
- Distance from Tenkan/Kijun as fraction of 1% of price. Clamped.
- These are conceptually the same as close-smaX atoms in momentum.rs but using Ichimoku lines.
- **Potential redundancy with cloud-position**: cloud-position already encodes where price is relative to the cloud. Tenkan and Kijun are the components of the cloud (shifted). So tenkan-dist and kijun-dist are partially redundant with cloud-position. However, they add information about the relationship to the individual lines, not just the aggregate cloud region.
- Names: "tenkan-dist" and "kijun-dist" — honest.

---

### `keltner.rs` — 6 atoms

**`bb-pos`** — `c.bb_pos`, Linear, scale 1.0
- Bollinger Band position — presumably normalized position within the band. If it's [(close - lower_band) / band_width], range is [0, 1]. If it's signed, range is [-1, +1]. Need to know the raw value range to evaluate scale.
- Name: "bb-pos" — short but honest enough.

**`bb-width`** — `c.bb_width.max(0.001)`, Log
- Band width as fraction of price (presumably). Positive, spans orders of magnitude (low vol to high vol). Log correct.
- Name: "bb-width" — honest.
- **DUPLICATION**: bb-width appears in exit/volatility.rs with identical encoding. Same atom, same name, same candle field. In the composed vector, when a market observer on Structure lens (keltner) is paired with any exit observer (which all get volatility), bb-width appears twice.

**`kelt-pos`** — `c.kelt_pos`, Linear, scale 1.0
- Keltner channel position. Similar to bb-pos but for Keltner channels.
- Name: "kelt-pos" — honest.

**`squeeze`** — `c.squeeze`, Linear, scale 1.0
- The squeeze indicator measures BB/Keltner relationship. [0, 1] presumably.
- **DUPLICATION**: squeeze appears in exit/volatility.rs with identical encoding. Same name, same field. When market Structure lens + any exit lens compose, squeeze appears twice.
- Name: "squeeze" — honest.

**`kelt-upper-dist`** and **`kelt-lower-dist`** — `(close - kelt_upper/lower) / close`, Linear, scale 0.1
- Signed distances to channel boundaries as fraction of price. Scale 0.1 means saturation at 10% from channel — is this calibrated?
- Names: "kelt-upper-dist" and "kelt-lower-dist" — honest.
- **Dependency**: kelt-upper-dist and kelt-lower-dist are not independent given kelt-pos. If you know where you are in the channel (kelt-pos) and the channel width (not directly encoded but derivable from the two distances), the two distances are functions of one another. Again, collinear atoms cost budget.

---

### `stochastic.rs` — 4 atoms

**`stoch-k`** — `c.stoch_k / 100.0`, Linear, scale 1.0
- Stochastic %K [0, 100], normalized to [0, 1]. Scale 1.0. Correct.
- Name: "stoch-k" — honest.

**`stoch-d`** — same normalization. Correct.
- **Relationship with stoch-k**: %D is the moving average of %K. Highly correlated. Including both vs. just the spread is the question.

**`stoch-kd-spread`** — `k - d`, Linear, scale 1.0
- The spread between fast and slow stochastic. Range approximately [-1, +1]. Correct.
- **Dependency again**: if you know stoch-k and stoch-d, you know stoch-kd-spread. Three atoms, two degrees of freedom. The spread is the interesting quantity for crossover detection; the individual values tell you absolute zone (overbought/oversold). If you keep all three, the spread is redundant given the other two. Consider: keep stoch-k and stoch-kd-spread, drop stoch-d.

**`stoch-cross-delta`** — clamped to [-1, +1]. Linear, scale 1.0.
- Presumably the rate of change of the %K/%D relationship. Distinct from the spread — it's momentum of the cross. Correct to include separately.
- Name: "stoch-cross-delta" — honest.

---

### `fibonacci.rs` — 8 atoms

**`range-pos-12`, `range-pos-24`, `range-pos-48`** — `c.range_pos_N`, Linear, scale 1.0
- Position within the N-candle range. Range [0, 1]. Scale 1.0. Correct.
- Names: honest. Clear period.
- **Collinearity**: These three are measuring the same structural concept at different lookbacks. In a sustained trend, all three will be near 1.0 simultaneously. The variance between them encodes "how recently the trend started." This is a reasonable multi-scale structure encoding. Keep all three.

**`fib-dist-236` through `fib-dist-786`** — `range_pos_48 - fibonacci_level`
- These are the signed distances from current position to each Fibonacci retracement level. Range approximately [-1, +1].
- **Problem**: These five atoms are all deterministic functions of `range-pos-48`. If you know `range-pos-48`, you can compute all five by subtracting the known Fibonacci constants. No information is added beyond `range-pos-48` itself. These five atoms encode zero additional information.
- The rationale must be that the *particular* distances matter — being near 0.618 (the golden ratio) should have geometric proximity to a known retracement level. But in Linear encoding, "close to Fib level X" and "close to Fib level Y" differ by a constant offset. The geometry doesn't know what 0.618 means. It's just five linear transforms of the same value.
- **Recommendation**: Drop all five fib-dist atoms. They are redundant with range-pos-48 up to a linear transform. If Fibonacci levels are hypothesized to be special, encode proximity to the nearest Fibonacci level as a categorical feature (atom) plus the distance to it — one atom for which level, one for how far. That would be semantically honest.

---

### `divergence.rs` — 0 to 3 atoms (conditional)

**`rsi-divergence-bull`**, **`rsi-divergence-bear`**, **`divergence-spread`** — conditional emission
- Encoding type: Linear, scale 1.0 for all.
- The conditional emission design is the most interesting structural decision in the vocab. When no divergence is detected, these atoms don't appear. The vector is structurally different on divergence candles vs. non-divergence candles — different atom sets.
- **Problem**: The noise subspace learns from both divergence and non-divergence candles. When the atom is absent, it contributes nothing to the thought vector. When present, it suddenly introduces a new direction. This means divergence facts pull the thought vector in unpredictable directions at prediction time. The subspace can't learn "divergence present" as a stable direction because the atom isn't always there to learn against.
- **Alternative**: Always emit all three atoms. Use 0.0 for non-divergence candles. This way the geometry consistently encodes "no divergence" as a value at a known position, and the learner can discriminate divergence from non-divergence geometrically.
- **Name**: "divergence-spread" encodes `bull - bear`, which is net divergence direction. Honest.
- **Dependent atom**: If you know bull and bear individually, you know the spread. Three atoms, two degrees of freedom. Prefer bull + spread, drop bear (bear can be derived as bull - spread).

---

### `timeframe.rs` — 6 atoms

**`tf-1h-trend`** — `c.tf_1h_body`, Linear, scale 1.0
- This is the signed body of the most recent 1h candle. What is the natural range? Depends on how it's normalized. The comment just says `c.tf_1h_body` — is this raw price difference? If so, scale 1.0 would saturate for any candle with a body larger than $1. This is likely normalized by close price, but the naming doesn't say.
- **Missing normalization documentation**: Without knowing the units of `tf_1h_body`, I can't evaluate the scale. This is an opacity in the candle struct. If it's already normalized (fraction of price), Linear scale 1.0 is reasonable. If it's raw, it's badly wrong.

**`tf-1h-ret`** — `c.tf_1h_ret`, Linear, scale 0.1
- 1-hour return. Scale 0.1 means saturation at ±10% return in 1 hour — loose but safe for BTC.
- Name: "tf-1h-ret" — honest.

**`tf-4h-trend`**, **`tf-4h-ret`** — symmetric analysis.

**`tf-agreement`** — `c.tf_agreement`, Linear, scale 1.0
- Presumably measures how much 5m, 1h, and 4h trends agree. Range [-1, +1] or [0, 1]. Scale 1.0 is correct for either.
- Name: "tf-agreement" — honest.

**`tf-5m-1h-align`** — `signum(tf_1h_body) * five_m_ret`, Linear, scale 0.1
- Sign of hourly trend multiplied by 5-minute return. This is positive when 5-minute move agrees with hourly direction, negative when it disagrees. Scale 0.1.
- **Encoding question**: The value is bounded by the 5-minute return magnitude. For BTC 5-minute candles, typical returns are ±0.5%, so the range is approximately [-0.005, +0.005]. Scale 0.1 means saturation at ±10% — massively over-scaled. The actual signal uses perhaps 5% of the encoding range. This is lossy — values of -0.005 and +0.005 will map to very similar geometric positions.
- Name: "tf-5m-1h-align" — descriptive and honest.
- **Scale bug**: Should be `scale: 0.005` or at most `scale: 0.01` to use the full encoding range for this signal.

---

### `standard.rs` — 8 atoms (window-based)

**`since-rsi-extreme`** — count of candles since last RSI extreme, Log
- A time count: 1 means just happened, N means N candles ago. Log is correct — the difference between 1 and 2 candles ago is qualitatively larger than between 50 and 51.
- Name: "since-rsi-extreme" — honest.
- **Window boundary**: if no RSI extreme occurred in the window, the index is 0, giving `since = n - 0 = n`. The count is capped at the window size. This means "never happened in window" and "happened exactly n candles ago" produce the same value. This is a subtle bug — "never happened" should be distinct from "happened at the very start of the window."

**`since-vol-spike`** — same pattern, same analysis. Same boundary issue.

**`since-large-move`** — same pattern. Same boundary issue.

**`dist-from-high`** — `(price - window_high) / price`, Linear, scale 0.1
- Always non-positive (price can't be above window high). Range [-0.1, 0] in normal conditions for a window of 200 candles. Scale 0.1 is calibrated.
- Name: "dist-from-high" — honest.
- **Sign convention**: A value of -0.05 means 5% below the window high. The sign is implied in the name but could be clearer.

**`dist-from-low`** — `(price - window_low) / price`
- Always non-negative. Good complement to dist-from-high.

**`dist-from-midpoint`** — `(price - window_mid) / price`
- Signed. Correct.
- **Dependency**: dist-from-midpoint is the average of dist-from-high and dist-from-low (approximately). These three atoms have two degrees of freedom. Drop one.

**`dist-from-sma200`** — `(price - sma200) / price`, Linear, scale 0.1
- **DUPLICATION with momentum.rs**: momentum's `close-sma200` computes `(close - sma200) / close`. This is identical to `dist-from-sma200`. Same formula, different names in different modules. When both Momentum lens and Standard context are active (all lenses include standard), this atom appears twice with different names but encoding the same signal. Double-weighting by stealth.
- Fix: remove `dist-from-sma200` from standard.rs since momentum.rs already carries it. Or remove close-sma200 from momentum and rely on standard. Pick one owner.

**`session-depth`** — `(1.0 + n).max(1.0)`, Log
- Count of candles in the current window (up to max_window_size). Log encoding is correct for a count.
- Name: "session-depth" — this name implies a trading session context, but what it actually encodes is the window fill level. In a running system after warmup, this will always be at max_window_size. It only varies during the first max_window_size candles. After that, it's a constant and provides no discrimination.
- **Potentially useless after warmup**: Once the window is full, session-depth = max_window_size, a constant. The Log encoding of a constant is a constant position in the vector space — the atom fires identically every candle. This adds a constant shift to every thought vector, which the noise subspace will absorb (as a "background" component), effectively making it invisible. After warmup, it does nothing.

---

## Exit Vocabulary

### `exit/volatility.rs` — 6 atoms

**`atr-ratio`** — same as momentum's atr-ratio. Identical computation, identical name.
- **DUPLICATION**: This is the most clear-cut duplication. When market Momentum lens + any exit lens compose, `atr-ratio` is present twice.

**`atr-r`** — `c.atr.max(0.001)`, Log
- Raw ATR value (not normalized by price). This differs from atr-ratio (which is normalized). The two measure related things but at different scales. atr-r is useful for absolute distance calculations; atr-ratio for relative comparison.
- Name: "atr-r" — honest but the `-r` suffix is shorthand that requires knowing the conventions.

**`atr-roc-6`** and **`atr-roc-12`** — Rate of change of ATR. Linear, scale 1.0.
- The rate of change of volatility. A positive value means volatility is expanding.
- **Encoding question**: What is the natural range of ATR rate of change? If it's a ratio (ATR_now / ATR_6_candles_ago - 1), Log encoding would be more appropriate. If it's already a bounded [-1, +1] normalized measure, Linear is correct.
- Names: "atr-roc-6" and "atr-roc-12" — honest.

**`squeeze`** — identical to keltner.rs's squeeze.
- **DUPLICATION**: Three-way duplication: keltner.rs, exit/volatility.rs, and possibly others.

**`bb-width`** — identical to keltner.rs's bb-width.
- **DUPLICATION**: Two-way.

---

### `exit/structure.rs` — 5 atoms

**`trend-consistency-6`, `trend-consistency-12`, `trend-consistency-24`** — `c.trend_consistency_N`, Linear, scale 1.0
- Trend consistency at three lookbacks. If these are bounded [0, 1] (fraction of candles moving in the dominant direction), scale 1.0 is correct.
- Names: "trend-consistency-N" — honest.
- **Collinearity**: These three are highly correlated in trending markets. They are decorrelated during transitions (consistency at short vs long periods can diverge). The multi-scale structure is intentional and correct. Keep all three.

**`adx`** — same as persistence.rs's adx. Identical.
- **DUPLICATION**: When a market observer on Regime lens (which includes persistence/adx) is paired with exit Structure lens, the composed vector has adx twice.

**`exit-kama-er`** — same as regime's kama-er. Different name, identical field and computation.
- The name prefix "exit-" distinguishes it intentionally. The geometric effect is still two atoms encoding the same candle quantity in the composed vector.

---

### `exit/timing.rs` — 5 atoms

**`rsi`** — `c.rsi`, Linear, scale 1.0
- **Same RSI bug as in oscillators.rs**: RSI [0, 100] encoded with scale=1.0. Either normalize to [0, 1] first, or use scale=100.0.
- **DUPLICATION with oscillators.rs**: When market Momentum lens (which includes rsi from oscillators) + exit Timing lens compose, `rsi` appears twice.

**`stoch-k`** — same as stochastic.rs. `c.stoch_k / 100.0`, Linear, scale 1.0.
- **DUPLICATION**: When market Momentum lens (stochastic.rs) + exit Timing lens compose, stoch-k appears twice.

**`stoch-kd-spread`** — same computation as stochastic.rs's stoch-kd-spread.
- **DUPLICATION**: Same as stoch-k duplication.

**`macd-hist`** — same as momentum.rs's macd-hist. Different scale here (scale 0.01) vs momentum (scale 0.01 also). Same.
- **DUPLICATION**: When market Momentum lens + exit Timing lens compose, macd-hist appears twice.

**`cci`** — same as oscillators.rs's cci. Same computation, same encoding.
- **DUPLICATION**: When market Momentum lens + exit Timing lens compose, cci appears twice.

**Critical observation**: exit/timing.rs shares all five of its atoms with market momentum/oscillators. If the Momentum lens observer is paired with the Timing exit observer, all five timing atoms are doubled in the composed vector. This lens pairing collapses the distinction between market context and exit context into a single doubled-weight signal.

---

### `exit/regime.rs` — 8 atoms

This is a near-exact copy of `market/regime.rs`. Same fields, same encoding, same atom names. The only structural difference is that it lives in a separate module. When any market observer on Regime lens + any exit observer compose, all 8 regime atoms are doubled.

**Why does this exist?** The comment says "same candle fields as market/regime.rs." This is honest documentation of an acknowledged duplication. The rationale for having regime in both market and exit is presumably: "exit observers should also know the market regime." That's correct intuition, but duplicating atoms is the wrong mechanism. A shared vocab module that both lenses reference would produce the same information once, not twice.

---

### `exit/time.rs` — 2 atoms

**`hour`** — Circular, period 24.0
**`day-of-week`** — Circular, period 7.0

These are subsets of `shared/time.rs` (which has 5 atoms). The exit lens deliberately takes only hour and day-of-week, omitting minute, day-of-month, and month-of-year.

- **DUPLICATION with shared/time**: Market lenses all include shared/time (5 atoms: minute, hour, day-of-week, day-of-month, month-of-year). Exit lenses include exit/time (2 atoms: hour, day-of-week). In the composed vector, hour and day-of-week appear twice — once from market's shared time, once from exit's time module.

The intent seems to be giving exit observers temporal context. But because market thought already includes this, the composed vector always has these atoms duplicated.

- Encoding: Circular is exactly right for periodic time. This is the most clearly correct encoding type choice in the entire codebase.

---

### `exit/self_assessment.rs` — 2 atoms

**`exit-grace-rate`** — Linear, scale 1.0. Range [0, 1]. Correct.
- Name: "exit-grace-rate" — honest.

**`exit-avg-residue`** — `avg_residue.max(0.001)`, Log
- Average residue (presumably average distance left on paper at resolution). Positive, spans orders of magnitude (tiny residue = close call; large residue = comfortable win). Log correct.
- Name: "exit-avg-residue" — honest.

---

## Broker Vocabulary

### `broker/self_assessment.rs` — up to 7 atoms

**`grace-rate`** — Linear, scale 1.0. Range [0, 1]. Correct.
- Name: "grace-rate" — honest.
- **DUPLICATION with exit/self_assessment's `exit-grace-rate`**: The broker encodes its own grace rate; exit observer encodes its grace rate as `exit-grace-rate`. When broker self-assessment composes with exit observer facts, both are present. They measure different things (broker's combined Win/Lose vs exit observer's Grace rate) so the distinction is legitimate. But the names should make this clearer. "broker-grace-rate" vs "exit-grace-rate" would be more honest.

**`paper-duration-avg`** — Log. Conditional on avg_paper_duration > 0.
- Positive unbounded count (candles). Log correct.
- Name: "paper-duration-avg" — honest.

**`paper-count`** — Log. Conditional on paper_count > 0.
- Count of open papers. Log correct for counts.
- Name: "paper-count" — honest.

**`trail-distance`** and **`stop-distance`** — Log. Conditional on > 0.
- Small positive fractions. Log correct (ratio-like quantities).
- Names: honest.
- **Redundancy with exit/opinions's `exit-trail` and `exit-stop`**: The broker encodes its own trail/stop distances from self-assessment; the exit opinion also encodes trail and stop. In the composed broker thought, both appear. They're measuring the same underlying distances but from different vantage points (historical average vs current choice). The distinction may carry information (comparing current distance to historical average reveals whether the exit observer is expanding or contracting its stops). This is legitimate if intentional. But if not intentional, it's duplication.

**`recalib-freshness`** — Log. Count of observations since last recalibration.
- Log correct for counts. As staleness grows, a doubling of candles since recalibration is less meaningful than the initial doubling.
- Name: "recalib-freshness" — the name says "freshness" but the value measures staleness (observations since last recalibration). High value = stale, not fresh. Inverted naming. Consider "recalib-staleness" or "candles-since-recalib."

**`excursion-avg`** — Log. Average of buy+sell excursion.
- Log correct for price movements.
- Name: "excursion-avg" — honest.

---

### `broker/opinions.rs` — 7 atoms (3 market + 4 exit)

**`market-direction`** — signed conviction, Linear, scale 1.0. Range [-1, +1]. Correct.
- Name: "market-direction" — the struct field is `signed_conviction` but the atom name is `market-direction`. These are different concepts. Conviction magnitude is how confident; direction is which way. "market-direction" signals direction, but the value also encodes magnitude of conviction (a value of 0.1 means weak Up, 0.9 means strong Up). The name omits the magnitude information. Consider "market-signed-conviction" for honesty.

**`market-conviction`** — absolute conviction, Linear, scale 1.0. Range [0, 1]. Correct.
- **Dependency**: If you know market-direction (signed conviction) and market-conviction (absolute), you have redundant information. |market-direction| == market-conviction by construction. These two are collinear — not independent. The noise subspace will discover this, but you're wasting one atom of budget.

**`market-edge`** — accuracy at this conviction level. Linear, scale 1.0. Range [0, 1]. Correct.
- Name: "market-edge" — honest.

**`exit-trail`** and **`exit-stop`** — Log. Correct for small positive fractions.
- Names: "exit-trail", "exit-stop" — honest.

**`exit-grace-rate`** — Linear, scale 1.0. Range [0, 1]. Correct.
- **DUPLICATION**: This appears in exit/self_assessment.rs also as "exit-grace-rate." When broker opinions compose with the exit thought vector (which already included self-assessment), this atom appears twice.

**`exit-avg-residue`** — Log. Same as exit/self_assessment's "exit-avg-residue."
- **DUPLICATION**: Same atom, same computation, both in exit/self_assessment and broker/opinions. In the composed broker thought, this appears twice.

---

## Cross-Cutting Concerns

### 1. The Duplication Epidemic

This is the most important finding. The architecture builds a composed vector for the broker by bundling market thought + exit thought. Market thought comes from a lens that selects specific modules. Exit thought comes from another lens. The broker's self-assessment adds more. The opinions layer adds more.

The problem: many atoms appear in multiple modules without distinction. When bundled, duplicate atoms accumulate double weight. This is not a small distortion — it systematically amplifies certain signals (ATR, RSI, regime measures) over others without any intentional weighting decision.

Confirmed duplications in the composed broker thought vector:

| Atom | Sources |
|------|---------|
| `atr-ratio` | momentum.rs + exit/volatility.rs |
| `rsi` | oscillators.rs + exit/timing.rs |
| `stoch-k` | stochastic.rs + exit/timing.rs |
| `stoch-kd-spread` | stochastic.rs + exit/timing.rs |
| `macd-hist` | momentum.rs + exit/timing.rs |
| `cci` | oscillators.rs + exit/timing.rs |
| `bb-width` | keltner.rs + exit/volatility.rs |
| `squeeze` | keltner.rs + exit/volatility.rs |
| `adx` | persistence.rs + exit/structure.rs |
| `kama-er` (different names) | regime.rs + exit/structure.rs |
| All regime atoms | market/regime.rs + exit/regime.rs |
| `hour` | shared/time.rs + exit/time.rs |
| `day-of-week` | shared/time.rs + exit/time.rs |
| `close-sma200` / `dist-from-sma200` | momentum.rs + standard.rs |
| `exit-grace-rate` | exit/self_assessment.rs + broker/opinions.rs |
| `exit-avg-residue` | exit/self_assessment.rs + broker/opinions.rs |
| `body-ratio` / `body-ratio-pa` | flow.rs + price_action.rs (same name ≠ same atom!) |

The worst case is the Momentum lens + Timing exit lens pairing: all five timing atoms (rsi, stoch-k, stoch-kd-spread, macd-hist, cci) are doubled. This specific pairing is the most corrupted composition.

### 2. Collinear Atoms (Independent Information Budget)

Several modules encode two or more atoms that are deterministic functions of each other. These are: buying-pressure + selling-pressure + body-ratio (flow.rs), upper-wick + lower-wick + body-ratio-pa (price_action.rs), stoch-k + stoch-d + stoch-kd-spread (stochastic.rs), market-direction + market-conviction (broker/opinions.rs), the five fibonacci distance atoms (fibonacci.rs), dist-from-high + dist-from-low + dist-from-midpoint (standard.rs).

The noise subspace handles this by projecting out the low-variance directions. But collinear atoms consume encoding budget before the subspace gets to work. The vector space has finite capacity. Redundant atoms are not free.

### 3. RSI Encoding Bug (Two Places)

RSI [0, 100] is encoded with scale=1.0 in both oscillators.rs and exit/timing.rs. Every other bounded [0, 100] indicator (MFI, Aroon, Stochastic, CCI) is normalized first. RSI is not. This is either a deliberate special case or an oversight. If special: document why. If oversight: fix by adding `/100.0`.

### 4. Centering and the "Neutral" Problem

Many indicators have a natural neutral point: Hurst=0.5 (random walk), DFA=0.5 (Brownian), autocorrelation=0 (no serial correlation), RSI=50 (neutral momentum), stochastic=50, adx=0 (no trend), choppiness=0.5 (medium).

In Linear encoding, the geometric midpoint occurs at value=0. Most [0,1] indicators don't have their neutral point at 0 — they have it at 0.5. This means the geometric "center" of these atoms is at the edge of their meaningful range, not at neutral. Two thoughts with "no RSI signal" (RSI≈50) will be geometrically displaced from center.

This is a systematic bias in the vocabulary design. Whether it matters depends on how the reckoner uses the learned space. The noise subspace will adapt, but the signal is off-center. The principled fix: normalize each indicator so that its neutral point maps to 0 before encoding.

### 5. The DFA-Alpha Centering Bug

DFA alpha lives in [0.5, 1.5] for real market series (values below 0.5 are mean-reverting, 0.5 is Brownian, above 0.5 is persistent). The current encoding: `dfa_alpha / 2.0`. This maps:
- 0.5 (Brownian) → 0.25
- 1.0 (persistent) → 0.50
- 1.5 (strongly persistent) → 0.75

The neutral (Brownian) value maps to 0.25, not 0.5. The encoding is off-center by 0.25 units. Fix: `(dfa_alpha - 0.5) / 1.0` maps Brownian to 0, persistence to 0.5, and strong persistence to 1.0. Scale=1.0 is then correct.

### 6. Session-Depth: Useless After Warmup

`session-depth` in standard.rs encodes the window fill level. After warmup (max_window_size candles have passed), this is permanently at its maximum value and provides no discrimination. It adds a constant shift to every thought vector. Remove it or replace it with something that actually varies.

### 7. Gap: Useless for Continuous 24/7 Markets

BTC trades continuously, 24/7. On a 5-minute dataset, gaps occur only from missing data (exchange outages, data pipeline failures). This atom is near-zero for essentially every candle in a clean dataset. It discriminates nothing. Remove it.

### 8. Fibonacci Distance Atoms: Zero Information

Five atoms computed as `range_pos_48 - fibonacci_constant`. These are linear transforms of a single value with known offsets. They add zero information beyond range_pos_48 itself. Remove all five. If Fibonacci levels are hypothesized to matter, encode "distance to nearest Fib level" (one atom) and "which Fib level is nearest" (categorical atom — this is where string atomization is correct, not Linear encoding).

### 9. The Regime Duplication Is Architectural

`exit/regime.rs` copying `market/regime.rs` is an architectural smell, not a coding mistake. It reveals that the module decomposition doesn't have a clean story for "shared context." The current design: market lenses include some modules, exit lenses include others, and then everything gets bundled together. But some information (regime, time) is genuinely shared context that both market and exit observers need. The right structure: a "universal context" layer that's added once, not twice.

This is partially acknowledged in `post.rs` where Proposal 026 comments "universal context: regime + time for all lenses." But the mechanism is still additive — it adds regime and time to the exit lens on top of what the market lens already provided. They arrive as separate atoms with the same names, colliding in the composed vector.

### 10. Missing Atoms

What should exist but doesn't:

- **Funding rate**: In perpetual futures markets (what BTC trading on Jupiter would use), the funding rate is a systematic edge signal. High positive funding = crowded longs, fade signal. The market lenses have no funding context.
- **Spread/liquidity**: Bid-ask spread or order book imbalance. Missing entirely.
- **Market cap / dominance**: BTC dominance affects BTC behavior. Missing.
- **Candle direction flag**: Whether the close is above or below open, as a categorical atom (not Linear encoded). The body-ratio encodes magnitude but not direction. There's no clean "is this an up candle?" signal — it's embedded in tf-1h-body and similar, but not for the current candle itself.
- **Volume deviation from session average**: volume-ratio (flow.rs) encodes volume acceleration, but not deviation from a longer baseline. A volume spike in the Asian session is different from one in the NY session.

---

## Summary Rankings

**Correct and clean (keep as-is):**
- exit/time.rs (Circular encoding is exactly right)
- exit/self_assessment.rs (minimal, honest)
- persistence.rs (minimal, mostly correct)
- divergence.rs (conditional emission is interesting; fix scale issue)

**Correct encoding type, wrong scale:**
- momentum.rs: close-sma200 scale too tight (0.1 → 0.3)
- timeframe.rs: tf-5m-1h-align scale wrong (0.1 → 0.005)
- momentum.rs: close-sma200 should differ from close-sma20 in scale

**Encoding type wrong:**
- oscillators.rs: rsi should be `/100.0` before scale=1.0
- exit/timing.rs: rsi same bug
- regime.rs: dfa-alpha centering is wrong

**Name dishonest:**
- broker/self_assessment.rs: "recalib-freshness" measures staleness, not freshness
- broker/opinions.rs: "market-direction" encodes signed conviction (magnitude + direction)
- flow.rs: "buying-pressure" / "selling-pressure" are price-action interpretations, not facts

**Useless atoms (remove):**
- standard.rs: `gap` (24/7 market, always zero)
- standard.rs: `session-depth` (constant after warmup)
- fibonacci.rs: all five `fib-dist-*` atoms (redundant with range-pos-48)

**Redundant atoms (choose one owner):**
- flow.rs: selling-pressure (collinear with buying-pressure + body-ratio)
- price_action.rs: body-ratio-pa (identical to body-ratio in flow.rs)
- price_action.rs: upper-wick or lower-wick (collinear with each other and body-ratio-pa)
- stochastic.rs: stoch-d (derivable from stoch-k and stoch-kd-spread)
- standard.rs: dist-from-midpoint (average of dist-from-high and dist-from-low)
- standard.rs: dist-from-sma200 (identical to momentum's close-sma200)
- broker/opinions.rs: market-conviction (absolute value of market-direction)
- broker/opinions.rs: exit-grace-rate and exit-avg-residue (already in exit/self_assessment)

**Architectural duplications (require lens/composition redesign):**
- exit/regime.rs: entire module is a copy of market/regime.rs
- exit/timing.rs: all five atoms overlap with market momentum/oscillators
- atr-ratio, bb-width, squeeze: appear in both market and exit lenses
- hour, day-of-week: appear in both shared/time and exit/time
- adx: appears in persistence and exit/structure

---

## What I Would Do First

1. Fix the RSI encoding bug. It's wrong in two places and affects core oscillator signal.
2. Fix the DFA-alpha centering. The neutral (Brownian) state should be at the geometric center.
3. Remove the five fibonacci distance atoms. Zero information at real cost.
4. Remove gap and session-depth. Zero discrimination at real cost.
5. Design a "universal context" layer (regime + time, added once to the composed vector, not once per lens). This is the architectural fix for the collision problem.
6. Rename "recalib-freshness" to "recalib-staleness."
7. Audit every Momentum lens + Timing exit lens broker for the five-atom duplication. That pairing has corrupted geometry.

The deeper principle: the vocabulary should be a set of *independent facts about the world*. Each atom should carry a thought no other atom already carries. Right now, many atoms speak the same thought in slightly different accents, and some atoms speak silence. The space is full of noise before the noise subspace even runs.

Simplicity is not the absence of atoms. It is the absence of incidental complexity — the accidental coupling of facts that should be independent. Fix that first.
