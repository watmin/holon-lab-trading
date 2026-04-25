# lab arc 026 — IndicatorBank port — BACKLOG

**Shape:** 13 slices. Slice 1 ships streaming primitives; slices
2-11 ship indicator families; slice 12 ties everything into the
orchestrating IndicatorBank struct; slice 13 closes with
INSCRIPTION + cross-link.

Slices 2-11 are independent of each other (each consumes only
slice 1's primitives + arc 025's already-shipped ATR/Phase). They
can ship in any order; recommended order below is
risk-progressing (mechanical first, statistical last) so the
substrate uplifts surface in increasing complexity.

Slice 12 depends on every prior slice — it's the integrating
chunk, mostly orchestration boilerplate.

---

## Slice 1 — Streaming primitives

**Status: shipped 2026-04-25.** ~280 LOC delivered as
`wat/encoding/indicator-bank/primitives.wat` — RingBuffer (struct +
fresh/push/len/sum/mean/min/max/get/full?), EmaState (alpha =
2/(period+1), warmup-via-SMA-then-EMA, ready? gate), SmaState
(RingBuffer + rolling sum, peek-and-subtract on eviction). 10
tests in `wat-tests/encoding/indicator-bank/primitives.wat` (budget
8; added test-sma-rolling-sum-after-eviction + test-ring-get-out-
of-range as edge cases). Lab wat tests 185 → 195. No substrate
uplifts surfaced.

**Decisions held:**
- WilderState **not re-exported** as a separate type. Arc 025's
  AtrState already wraps Wilder semantics; if a non-ATR Wilder
  consumer surfaces (DMI's plus_di / minus_di in slice 3), we'll
  factor a WilderState struct out then. Doesn't block slice 1.
- RingBuffer's `get i` indexes 0=most-recent (inverts substrate's
  0=front). Matches archive's `[len-1-i]` convention; archive's
  Rust ring-buffer accessors all work this way.
- `SmaState::update` peek-and-subtract uses substrate's
  `feedback_shim_panic_vs_option` pattern — match-with-impossible-
  None (sentinel 0.0) on the get-oldest call, gated by `full?`.

`wat/encoding/indicator-bank/primitives.wat`:

```scheme
;; RingBuffer — bounded sliding window over f64.
(:wat::core::struct :trading::encoding::RingBuffer
  (values   :Vec<f64>)        ; current window contents
  (capacity :i64))             ; max length; oldest evicted on push past

;; Push — append; trim to capacity. Returns updated buffer.
(:trading::encoding::ring-buffer-push  buf x → buf)
;; Length, sum, mean, min, max, get-at-offset (most recent = 0).
(:trading::encoding::ring-buffer-len   buf → i64)
(:trading::encoding::ring-buffer-sum   buf → f64)
(:trading::encoding::ring-buffer-mean  buf → f64)
(:trading::encoding::ring-buffer-min   buf → :Option<f64>)
(:trading::encoding::ring-buffer-max   buf → :Option<f64>)
(:trading::encoding::ring-buffer-get   buf i → :Option<f64>)
(:trading::encoding::ring-buffer-full? buf → bool)

;; EmaState — exponential moving average. Wilder's variant
;; (alpha = 1/period) lives in arc 025's atr.wat; this is the
;; standard EMA (alpha = 2/(period+1)).
(:wat::core::struct :trading::encoding::EmaState
  (period :i64)
  (alpha  :f64)
  (value  :f64)
  (count  :i64))

(:trading::encoding::ema-fresh  period → state)
(:trading::encoding::ema-update state x → state)
(:trading::encoding::ema-value  state → f64)
(:trading::encoding::ema-ready? state → bool)

;; SmaState — simple moving average over a RingBuffer.
(:wat::core::struct :trading::encoding::SmaState
  (period :i64)
  (buffer :trading::encoding::RingBuffer)
  (sum    :f64))             ; rolling sum maintained alongside buffer for O(1) value

(:trading::encoding::sma-fresh  period → state)
(:trading::encoding::sma-update state x → state)
(:trading::encoding::sma-value  state → f64)
(:trading::encoding::sma-ready? state → bool)
```

WilderState is **inherited from arc 025's `wat/encoding/atr.wat`**;
no re-shipment. Slice 1 simply imports and re-uses.

**Tests** (`wat-tests/encoding/indicator-bank/primitives.wat`):

1. **RingBuffer push under capacity** — three pushes, length=3.
2. **RingBuffer push past capacity** — capacity=2, three pushes; oldest evicted; length=2; values reflect last two.
3. **RingBuffer get-at-offset** — get(0) is most recent, get(1) is one prior.
4. **RingBuffer mean** — known input → known mean.
5. **EMA convergence** — feed constant 100 for 50 candles; EMA value → 100.
6. **EMA alpha computed correctly** — period=10 → alpha=2/11.
7. **SMA matches mean** — SMA value over a full window equals ring-buffer mean.
8. **SMA ready? gate** — false until full; true thereafter.

**Estimated cost:** ~150 LOC + 8 tests. **1 day.**

---

## Slice 2 — Oscillators

**Status: shipped 2026-04-25.** ~470 LOC delivered as
`wat/encoding/indicator-bank/oscillators.wat` — RSI (two
WilderState smoothers + prev-close), Stochastic (three RingBuffers:
high/low/k), Williams %R (pure compute over Stoch's high/low),
CCI (RingBuffer + SmaState over typical price + foldl mean
deviation), MFI (two RingBuffers for pos/neg money flow). 15
tests in `wat-tests/encoding/indicator-bank/oscillators.wat` (budget
18; shipped 15 — covers fresh/ready/range/convergence per indicator
plus Williams %R bounds at high/low). Lab wat tests 195 → 210.

**Refactor as planned: WilderState factored out of arc 025's
AtrState.** The slice-1 footnote ("if a non-ATR Wilder consumer
surfaces, factor then") fired immediately. New `WilderState` in
`primitives.wat`; `wat/encoding/atr.wat` rewritten to compose it
(AtrState now holds `(wilder, prev-close, started)`); arc 025 atr
tests updated to use `:AtrState::value` (new explicit delegate)
and `:WilderState/count (:AtrState/wilder s)` for deeper field
access. All 6 arc 025 atr tests still green post-refactor.

**Off-by-one caught in test-stoch-ready-gate.** Initial test
expected ready at candle 8; with k-period=5 + d-period=3 the gate
actually fires at candle 7 (high/low full at 5; k-buf gets one
push per candle from 5 onward; full at 7). Fixed to test 6→false,
7→true.

**No substrate uplifts surfaced.** All five oscillators ran clean
on slice 1's primitives + arc 050's polymorphic arithmetic + arc
056's foldl + the substrate's existing match/Option/and primitives.

Five indicators: RSI, Stochastic (k + d), CCI, MFI, Williams %R.

`wat/encoding/indicator-bank/oscillators.wat`:

```scheme
(:wat::core::struct :trading::encoding::RsiState ...)
(:trading::encoding::rsi-fresh period → state)
(:trading::encoding::rsi-update state close → state)
(:trading::encoding::rsi-value state → f64)

(:wat::core::struct :trading::encoding::StochState ...)
(:trading::encoding::stoch-fresh k-period d-period → state)
(:trading::encoding::stoch-update state high low close → state)
(:trading::encoding::stoch-k state → f64)
(:trading::encoding::stoch-d state → f64)

(:wat::core::struct :trading::encoding::CciState ...)
;; CCI uses a typical price (h+l+c)/3 and mean deviation.

(:wat::core::struct :trading::encoding::MfiState ...)
;; MFI uses money flow over a Wilder-smoothed window.

;; Williams %R — pure compute over StochState's high/low buffers.
(:trading::encoding::compute-williams-r stoch close → f64)
```

**Tests:** RSI on textbook input (Wilder's 1978 example), Stoch on a known oscillation, CCI on flat data (→ 0), MFI on rising volume, Williams %R bounds [-100, 0]. ~3-4 tests per indicator → **15-18 tests.**

**Estimated cost:** ~400 LOC + 18 tests. **2 days.**

---

## Slice 3 — Trend (SMA + MACD + DMI/ADX)

**Status: shipped 2026-04-25.** ~340 LOC delivered as
`wat/encoding/indicator-bank/trend.wat` — MACD (three EmaState
fast/slow/signal) + DMI/ADX (four WilderState plus_dm/minus_dm/
tr/adx + prev high/low/close). 12 tests in
`wat-tests/encoding/indicator-bank/trend.wat` (matching budget).
Lab wat tests 210 → 222.

**SMA20/50/200 not separately shipped** per BACKLOG — they're three
SmaState instances at different periods, held as IndicatorBank
fields in slice 12. SmaState mechanics are tested by slice 1.

**Slice 2's WilderState refactor pays off.** DMI's four Wilder
instances compose cleanly; no extra factoring needed.

**No substrate uplifts surfaced.** Existing primitives covered:
EmaState/WilderState/RingBuffer (slice 1 + arc 025), polymorphic
arithmetic (arc 050), `f64::max`/`f64::abs`, `:wat::core::and`/`or`/
`not`. The DMI's chained dependency (TR-smoother gates DX-smoother
gates ADX-smoother) all expressed via let* + nested if branches.

Three families:
- SMA20/50/200 — three SmaState instances at different periods.
  Stored as separate `IndicatorBank` fields, not a separate type.
- MACD — fast EMA - slow EMA, plus signal line (EMA of MACD). Hist = MACD - signal.
- DMI — plus_di, minus_di, ADX. Wilder-smoothed over period 14.

`wat/encoding/indicator-bank/trend.wat`:

```scheme
(:wat::core::struct :trading::encoding::MacdState
  (fast      :trading::encoding::EmaState)
  (slow      :trading::encoding::EmaState)
  (signal    :trading::encoding::EmaState))
(:trading::encoding::macd-fresh fast-period slow-period signal-period → state)
(:trading::encoding::macd-update state close → state)
(:trading::encoding::macd-hist state → f64)
(:trading::encoding::macd-line state → f64)
(:trading::encoding::macd-signal state → f64)

(:wat::core::struct :trading::encoding::DmiState
  (atr        :trading::encoding::WilderState)
  (plus-dm    :trading::encoding::WilderState)
  (minus-dm   :trading::encoding::WilderState)
  (adx        :trading::encoding::WilderState)
  (prev-high  :f64)
  (prev-low   :f64)
  (prev-close :f64)
  (started    :bool))
(:trading::encoding::dmi-fresh period → state)
(:trading::encoding::dmi-update state high low close → state)
(:trading::encoding::dmi-plus  state → f64)
(:trading::encoding::dmi-minus state → f64)
(:trading::encoding::dmi-adx   state → f64)
```

**Tests:** MACD line/signal/hist on a synthetic trend; DMI on
sustained trend (ADX rises); SMA at multiple periods on the same
input (each ready at its own period). **~12 tests.**

**Estimated cost:** ~350 LOC + 12 tests. **2 days.**

---

## Slice 4 — Volatility (Bollinger + Keltner + squeeze + ATR-ratio)

**Status: shipped 2026-04-25.** ~290 LOC delivered as
`wat/encoding/indicator-bank/volatility.wat` + RollingStddev added
to primitives.wat (~70 LOC). 12 tests in
`wat-tests/encoding/indicator-bank/volatility.wat`. Lab wat tests
222 → 234.

**Substrate uplift surfaced — `:wat::std::math::sqrt`.** The BACKLOG
anticipated this. Shipped as carry-along to wat-rs (commit
`c750fe2`); same shape as the existing math unaries (ln/exp/sin/
cos) — one dispatch arm + `"sqrt"` in the for-loop's name list.
3 new wat-rs tests; 962 → 965.

**RollingStddev added to primitives.wat** (rather than a separate
file) — it's a general utility likely consumed by future
statistical estimators (slices 9-10). Maintains both `sum` and
`sum-sq` for O(1) updates via peek-and-subtract on eviction
(matches archive convention exactly).

**Bollinger composes SmaState + RollingStddev.** Same period for
both; archive duplicates the windows similarly. Keltner wraps
EmaState only — ATR is passed in at compute time (matches
IndicatorBank's atr-once policy; the bank holds one AtrState that
multiple consumers query).

**Squeeze + atr-ratio are pure scalar computes.** No struct, no
state — just `compute-squeeze` and `compute-atr-ratio` defines.
Both use `:wat::core::if (= 0.0)` defensive fallbacks for
degenerate denominators (matches archive).

Bollinger uses SMA + stddev (substrate uplift candidate: a `stddev`
helper, or write inline). Keltner uses EMA + ATR (already shipped
arc 025 slice 1). Squeeze is BB-width vs Keltner-width.

`wat/encoding/indicator-bank/volatility.wat`:

```scheme
;; Bollinger: SMA + 2-stddev band.
(:wat::core::struct :trading::encoding::BollingerState
  (sma     :trading::encoding::SmaState)
  (buffer  :trading::encoding::RingBuffer))   ; needed for stddev
(:trading::encoding::bollinger-fresh period → state)
(:trading::encoding::bollinger-update state close → state)
(:trading::encoding::bollinger-upper state → f64)
(:trading::encoding::bollinger-lower state → f64)
(:trading::encoding::bollinger-width state close → f64)   ; (upper-lower)/sma
(:trading::encoding::bollinger-pos   state close → f64)   ; (close-lower)/(upper-lower)

;; Keltner: EMA + 2*ATR band.
(:wat::core::struct :trading::encoding::KeltnerState
  (ema :trading::encoding::EmaState))
(:trading::encoding::keltner-fresh period → state)
(:trading::encoding::keltner-update state close → state)
;; Bands derived from EMA + ATR (passed in at compute time, not stored).
(:trading::encoding::keltner-upper state atr → f64)
(:trading::encoding::keltner-lower state atr → f64)
(:trading::encoding::keltner-pos   state atr close → f64)

;; Squeeze: ratio of BB-width to Keltner-width.
(:trading::encoding::compute-squeeze bb-width kelt-width → f64)

;; ATR-ratio: atr / close. Scalar compute.
(:trading::encoding::compute-atr-ratio atr close → f64)
```

**Tests:** Bollinger on flat input (width → 0), Keltner on
trend, squeeze threshold behavior, atr-ratio range. **~10 tests.**

**Estimated cost:** ~250 LOC + 10 tests. **1.5 days.**

**Likely substrate uplift:** `stddev` over `:Vec<f64>` if not
already shipped. ~30 LOC carry-along to wat-rs.

---

## Slice 5 — Volume (OBV + volume_accel)

**Status: ready (after slice 1).**

OBV is a running cumulative balance plus a slope over a RingBuffer.
Volume_accel is short-SMA / long-SMA volume.

`wat/encoding/indicator-bank/volume.wat`:

```scheme
(:wat::core::struct :trading::encoding::ObvState
  (obv        :f64)
  (prev-close :f64)
  (history    :trading::encoding::RingBuffer)   ; for slope
  (started    :bool))
(:trading::encoding::obv-fresh history-len → state)
(:trading::encoding::obv-update state close volume → state)
(:trading::encoding::obv-value state → f64)
(:trading::encoding::obv-slope state → f64)   ; over history

(:wat::core::struct :trading::encoding::VolumeAccelState
  (short :trading::encoding::SmaState)
  (long  :trading::encoding::SmaState))
(:trading::encoding::volume-accel-fresh short-period long-period → state)
(:trading::encoding::volume-accel-update state volume → state)
(:trading::encoding::volume-accel-value state → f64)
```

**Tests:** OBV direction on rising/falling close, OBV slope
positive/negative, volume_accel ratio behavior. **~6 tests.**

**Estimated cost:** ~150 LOC + 6 tests. **1 day.**

---

## Slice 6 — Rate of Change + Range positions

**Status: ready (after slice 1).**

Pure-compute functions over a RingBuffer; no state structs of
their own. Each is N-period close-vs-N-ago (ROC) or close-vs-
range (range_pos).

`wat/encoding/indicator-bank/rate.wat`:

```scheme
;; (close - close[N-ago]) / close[N-ago].
(:trading::encoding::compute-roc buf n → f64)

;; (close - low) / (high - low) over an N-window.
(:trading::encoding::compute-range-pos high-buf low-buf close → f64)

;; The IndicatorBank holds RingBuffers at periods 1, 3, 6, 12 for
;; ROC; periods 12, 24, 48 for range_pos.
```

**Tests:** ROC on monotonic rise (all positive), range_pos
center/edge behavior. **~6 tests.**

**Estimated cost:** ~100 LOC + 6 tests. **1 day.**

---

## Slice 7 — Multi-timeframe

**Status: ready (after slice 1).**

5-minute candles aggregated to 1-hour and 4-hour windows. tf-1h
needs a 12-period RingBuffer; tf-4h needs a 48-period RingBuffer.

`wat/encoding/indicator-bank/timeframe.wat`:

```scheme
;; (last - first) / first over the buffer.
(:trading::encoding::compute-tf-ret buf → f64)
;; (close - open) / (high - low) over the buffer; body strength.
(:trading::encoding::compute-tf-body buf → f64)
;; agreement: signum(5m-ret) == signum(1h-ret) ? 1 : -1; weighted.
(:trading::encoding::compute-tf-agreement
  prev-close close tf-1h-buf tf-4h-buf → f64)
```

**Tests:** tf-ret on rising buffer (positive), tf-body bounds,
tf-agreement directional cases. **~6 tests.**

**Estimated cost:** ~150 LOC + 6 tests. **1.5 days.**

---

## Slice 8 — Ichimoku

**Status: ready (after slice 1).**

Multi-window state machine. Tenkan-sen (9-period high+low/2),
Kijun-sen (26-period), cloud_top/bottom (max/min of tenkan/kijun
over 26-period lookahead), tk_cross_delta.

`wat/encoding/indicator-bank/ichimoku.wat`:

```scheme
(:wat::core::struct :trading::encoding::IchimokuState
  (high-buf :trading::encoding::RingBuffer)   ; covers max(tenkan, kijun)
  (low-buf  :trading::encoding::RingBuffer)
  (prev-tenkan :f64)
  (prev-kijun  :f64))

(:trading::encoding::ichimoku-fresh tenkan-period kijun-period → state)
(:trading::encoding::ichimoku-update state high low → state)
(:trading::encoding::ichimoku-tenkan state → f64)
(:trading::encoding::ichimoku-kijun  state → f64)
(:trading::encoding::ichimoku-cloud-top    state → f64)
(:trading::encoding::ichimoku-cloud-bottom state → f64)
(:trading::encoding::ichimoku-tk-cross-delta state → f64)
```

**Tests:** tenkan/kijun computed correctly on known input, cloud
ordering, tk-cross-delta direction. **~8 tests.**

**Estimated cost:** ~250 LOC + 8 tests. **2 days.**

---

## Slice 9 — Persistence (Hurst + autocorrelation + vwap_distance)

**Status: ready (after slice 1).** First statistical-estimator
slice; the math is non-trivial. Port the archive carefully.

`wat/encoding/indicator-bank/persistence.wat`:

```scheme
(:wat::core::struct :trading::encoding::HurstState
  (return-buf :trading::encoding::RingBuffer))   ; log returns
(:trading::encoding::hurst-update state log-return → state)
(:trading::encoding::hurst-value  state → f64)
;; Rescaled range over multiple sub-windows; classic Hurst R/S.

(:trading::encoding::compute-autocorrelation buf lag → f64)

(:wat::core::struct :trading::encoding::VwapState
  (cum-pv  :f64)         ; cumulative price × volume
  (cum-vol :f64))        ; cumulative volume
(:trading::encoding::vwap-fresh → state)
(:trading::encoding::vwap-update state close volume → state)
(:trading::encoding::vwap-distance state close → f64)   ; (close - vwap) / close
```

**Tests:** Hurst on synthetic random walk (~0.5), Hurst on
trending input (~0.7+), autocorrelation lag-1 vs lag-N,
vwap-distance on flat input (→ 0). **~10 tests.**

**Estimated cost:** ~300 LOC + 10 tests. **2.5 days.**

**Likely substrate uplifts:**
- `:wat::std::math::sqrt` — verify exists; needed for Hurst's R/S.
- `f64::powf` for Hurst's least-squares fit (or compute via log-log SMA).

---

## Slice 10 — Regime (kama_er + choppiness + DFA + variance_ratio + entropy + Aroon + fractal-dim)

**Status: ready (after slice 1).** **Biggest slice.** Eight
indicators, several with statistical-estimator algorithms.

`wat/encoding/indicator-bank/regime.wat`:

```scheme
;; Kaufman's Efficiency Ratio: |close[N-ago] - close| / sum(|close[i]-close[i-1]|).
(:trading::encoding::compute-kama-er buf → f64)

;; Choppiness index: log10(ATR_sum / range_max-min) / log10(N) * 100.
(:trading::encoding::compute-choppiness atr-sum high-buf low-buf → f64)

;; DFA-alpha (Detrended Fluctuation Analysis): least-squares slope
;; over log(window-size) vs log(detrended-fluctuation).
(:wat::core::struct :trading::encoding::DfaState
  (return-buf :trading::encoding::RingBuffer))
(:trading::encoding::dfa-update state log-return → state)
(:trading::encoding::dfa-alpha  state → f64)

;; Variance ratio: var(N-period returns) / (N * var(1-period returns)).
(:wat::core::struct :trading::encoding::VarRatioState ...)

;; Entropy rate: information-theoretic measure of return predictability.
(:wat::core::struct :trading::encoding::EntropyState ...)

;; Aroon up/down: time-since-N-period-high/low normalized to N.
(:trading::encoding::compute-aroon-up   high-buf → f64)
(:trading::encoding::compute-aroon-down low-buf  → f64)

;; Fractal dimension via box-counting estimator.
(:wat::core::struct :trading::encoding::FractalState ...)
```

**Tests:** kama-er on trending (high) / choppy (low) input,
choppiness opposite, DFA-alpha range [0.5, 1.5+], variance_ratio
behavior, entropy on random vs predictable, Aroon-up at N-high,
fractal-dim on smooth (→ 1) vs noisy (→ 2). **~16 tests.**

**Estimated cost:** ~600 LOC + 16 tests. **3 days.**

**Likely substrate uplifts:**
- `f64::powf` (entropy uses log²).
- `:wat::std::list::variance` / `stddev` if needed.
- Possibly an autocorrelation kernel beyond what slice 9 ships.

---

## Slice 11 — Divergence + cross-deltas + price-action

**Status: ready (after slices 2, 3).**

Compose existing oscillators (RSI from slice 2, Stoch from
slice 2, MACD from slice 3) with simple price-action checks.

`wat/encoding/indicator-bank/divergence.wat`:

```scheme
;; rsi-divergence-bull: price made lower-low but RSI made higher-low.
(:trading::encoding::compute-rsi-divergence-bull
  rsi rsi-buf close-buf → f64)
(:trading::encoding::compute-rsi-divergence-bear
  rsi rsi-buf close-buf → f64)

;; tk-cross-delta lives in slice 8 (Ichimoku); cross-reference here.
;; stoch-cross-delta: stoch-k - stoch-d.
(:trading::encoding::compute-stoch-cross-delta stoch → f64)
```

`wat/encoding/indicator-bank/price-action.wat`:

```scheme
;; range_ratio: high/low.
(:trading::encoding::compute-range-ratio high low → f64)
;; gap: (open - prev_close) / prev_close.
(:trading::encoding::compute-gap open prev-close → f64)
;; consecutive_up: count of consecutive close > prev-close candles.
(:wat::core::struct :trading::encoding::ConsecutiveState
  (up-count   :i64)
  (down-count :i64)
  (prev-close :f64)
  (started    :bool))
(:trading::encoding::consecutive-update state close → state)
```

**Tests:** divergence on synthetic divergent input, gap
behavior, consecutive_up streak. **~10 tests.**

**Estimated cost:** ~200 LOC + 10 tests. **1.5 days.**

---

## Slice 12 — IndicatorBank orchestration

**Status: ready (after every prior slice).** **Load-bearing.**

`wat/encoding/indicator-bank/bank.wat`:

```scheme
;; The integrating struct. Owns every per-indicator state +
;; every supporting RingBuffer. ~30+ fields.
(:wat::core::struct :trading::encoding::IndicatorBank
  (sma20 :trading::encoding::SmaState)
  (sma50 :trading::encoding::SmaState)
  (sma200 :trading::encoding::SmaState)
  (rsi   :trading::encoding::RsiState)
  (atr   :trading::encoding::AtrState)
  (atr-window :trading::encoding::AtrWindow)
  (phase :trading::encoding::PhaseState)
  (macd  :trading::encoding::MacdState)
  (dmi   :trading::encoding::DmiState)
  (stoch :trading::encoding::StochState)
  (cci   :trading::encoding::CciState)
  (mfi   :trading::encoding::MfiState)
  (obv   :trading::encoding::ObvState)
  (volume-accel :trading::encoding::VolumeAccelState)
  (bollinger :trading::encoding::BollingerState)
  (keltner   :trading::encoding::KeltnerState)
  (ichimoku  :trading::encoding::IchimokuState)
  (hurst     :trading::encoding::HurstState)
  (vwap      :trading::encoding::VwapState)
  (dfa       :trading::encoding::DfaState)
  ;; ... regime states, RingBuffers for ROC/range-pos/timeframe,
  ;;     consecutive-up/down state, divergence ring-buffers ...
  (prev-close :f64)
  (prev-high  :f64)
  (prev-low   :f64)
  (started    :bool)
  (count      :i64))

(:trading::encoding::indicator-bank-fresh → bank)

;; The big one — values-up tick.
(:trading::encoding::indicator-bank-tick bank ohlcv → :(bank, candle))
```

The tick body sequences every indicator's update (mostly
parallelizable; archive does it sequentially). Then constructs
the Candle from updated states. Returns (new-bank, candle).

**Tests:**
- 27. **Fresh bank → first tick** — ready? false on every gate.
- 28. **Bank ticks past every gate** — after sufficient candles, every gate true.
- 29. **Cross-check sma20** — bank tick produces candle.sma20 matching SmaState.value.
- 30. **Cross-check rsi** — bank tick produces candle.rsi matching RsiState.value.
- 31. **Cross-check phase-label** — bank tick produces candle.phase-label matching PhaseState.current-label.
- 32. **(Optional) diff-against-archive** — run wat bank vs archive Rust on first 1000 candles of `data/btc_5m_raw.parquet`; assert key fields match within 1e-9.

**Estimated cost:** ~500 LOC + 6 tests. **2.5 days.**

---

## Slice 13 — INSCRIPTION + cross-link

**Status: blocked on slice 12.**

- **INSCRIPTION.md** — record per-slice LOC delta, test count
  delta, substrate uplifts that surfaced (every carry-along
  shipped to wat-rs over the arc's life), the "first ready candle"
  number from real data.
- **`docs/rewrite-backlog.md`** — Phase 5's IndicatorBank entry
  resolves: "shipped under lab arc 026."
- **`docs/arc/2026/04/025-paper-lifecycle-simulator/BACKLOG.md`** —
  slice 3-6 status flips from "paused on arc 026" back to "ready."
- **CLAUDE.md** — leave alone per backlog directive.

**Estimated cost:** ~1 hour. Doc only.

---

## Verification end-to-end

After all slices land:

```scheme
(:wat::core::let*
  (((stream :lab::candles::Stream)
    (:lab::candles::open "data/btc_5m_raw.parquet"))
   ((bank-fresh :trading::encoding::IndicatorBank)
    (:trading::encoding::indicator-bank-fresh)))
  ;; Loop: pull ohlcv from stream; tick bank; extract candle.
  ;; After ~2016 candles, every indicator is ready;
  ;; subsequent candles are fully-populated :trading::types::Candle
  ;; values consumable by vocab modules and the future arc-025
  ;; simulator's Thinker.
  ...)
```

That's the unblock. Arc 025 resumes against this.

---

## Out of scope

- **Arc 025 simulator slices.** Paused; resume after this arc.
- **Domain layer (treasury, broker, observers, lens, simulation).**
  Phase 5 work; this arc only ships IndicatorBank.
- **Performance optimization beyond honest values-up port.**
- **Live data feeds.** Parquet-only.
- **Cross-pair indicators.** Single-pair (BTC).
- **ML-based indicators.** None in archive; none here.

---

## Risks

**Statistical-estimator subtlety (slices 9, 10).** Hurst, DFA,
fractal-dim, entropy-rate have algorithms that don't survive
sloppy translation. Mitigate: port line-by-line; cross-check
against archive's Rust output on a synthetic test stream;
slow down on these slices.

**Substrate uplift cadence.** Each surfaced primitive needs to
ship to wat-rs as a carry-along before the dependent slice can
close. If wat-rs work blocks, the arc stalls. Mitigate: surface
uplifts as soon as they're identified (not at slice's end);
ship them in parallel with continuing slice work.

**Floating-point drift.** Slice 12's diff-against-archive is the
canary. Bit-identical f64 means any drift is a porting bug, not
a substrate issue.

**Per-tick performance.** Wat is 5-10× slower than archive Rust.
6-year stream tick is ~30-90 minutes. Mitigate: run on smaller
windows during testing; full-stream runs are intentional and
bounded.

---

## Total estimate

- Slice 1: 1 day (primitives)
- Slice 2: 2 days (oscillators)
- Slice 3: 2 days (trend)
- Slice 4: 1.5 days (volatility)
- Slice 5: 1 day (volume)
- Slice 6: 1 day (ROC + range-pos)
- Slice 7: 1.5 days (multi-timeframe)
- Slice 8: 2 days (Ichimoku)
- Slice 9: 2.5 days (persistence — first statistical slice)
- Slice 10: 3 days (regime — biggest slice)
- Slice 11: 1.5 days (divergence + cross-deltas + price-action)
- Slice 12: 2.5 days (orchestration)
- Slice 13: 1 hour (docs)

**~21 days end-to-end** = **~3 weeks of focused work.**

Slice ordering: 1 first (everyone depends); 2-11 in any order
(each depends only on slice 1); 12 last (depends on every prior);
13 closes the arc.

Recommended order: by risk-progression — mechanical first
(oscillators, trend, volatility, volume, ROC, multi-timeframe),
moderate next (Ichimoku, divergence, price-action), statistical
last (persistence, regime). Lets substrate uplifts surface in
increasing complexity; the easy slices stabilize the pattern
before the hard slices arrive.

---

## What this unblocks

- **Arc 025 slices 3-6.** Resume against the real Candle.
- **Real first-thinkers.** Bundled-rhythm encoders comparable
  to archived `market_observer.rs`.
- **Phase 5's other domain modules.** Each reads a populated Candle.
- **Phase 4's Reckoner training.** Trained on populated Candle streams.
- **The 6-year BTC parquet becomes meaningful.** Today: OHLCV.
  After arc 026: enriched market state.

PERSEVERARE.
