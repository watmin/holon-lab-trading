# lab arc 026 — IndicatorBank Port

**Status:** opened 2026-04-25.

**Scope:** large. The single biggest port in the rewrite. ~1,900
LOC of archived Rust → ~3,000 LOC of wat across ~70 indicators.
13 slices. Estimate ~3 weeks of focused work; substrate uplifts
will surface and ride along as carry-alongs.

Builder direction:

> "i say we pivot and make the indicator bank... we /must/ have
> it.. right?"

> "option 1 - we have a full reference right? its just a
> translation issue?"

> "make an arc 026 - it builds the indicator bank we need - we
> pause arc 025 pending completion of arc 026"

Cross-references:
- [`archived/pre-wat-native/src/domain/indicator_bank.rs`](../../../archived/pre-wat-native/src/domain/indicator_bank.rs) — 2,365 LOC; the spec.
- [`archived/pre-wat-native/src/types/candle.rs`](../../../archived/pre-wat-native/src/types/candle.rs) — Candle struct with all 73 indicator fields (already shipped to wat in Phase 1.6).
- [`docs/arc/2026/04/025-paper-lifecycle-simulator/`](../025-paper-lifecycle-simulator/) — arc 025 (paused pending arc 026); slice 1 + slice 2 already ship ATR + AtrWindow + PhaseState which arc 026 inherits.
- [`docs/rewrite-backlog.md`](../../rewrite-backlog.md) — Phase 5 (`indicator_bank.rs (2,365L)... The monster.`).
- Lab arc 002 (Wilder helper inheritance via slice-1 of arc 025).

---

## Why this arc, why now

Arc 025 surfaced the gap honestly: the simulator's Thinker
signature wanted `:trading::types::Candles` (the enriched form),
but v1 could only produce raw OHLCV + ATR + PhaseState. Three
options were considered (raw Ohlcvs, SimCandle stub, NaN-default
Candle); the user picked **Option I — port the full IndicatorBank
now.** The pivot is honest: a yardstick measuring impoverished
thinkers (operating on 3 fields instead of 73) is hollow. The
archived `market_observer.rs` produced 59% directional accuracy
on rhythms drawing from ~15-20 indicators across the enriched
Candle; v1 of the lab simulator must measure against thinkers
operating in the same space.

The work is **translation, not design.** The archive is the
spec — every indicator has a correct Rust implementation with
tests. wat-rs has accumulated the math primitives most indicators
need (`f64::min/max/abs/clamp`, `math::exp/log/sin/cos/sqrt`).
What remains is mechanical with two exception families:

1. **A few statistical estimators with subtle algorithms** —
   Hurst exponent, DFA-alpha, fractal-dim, entropy-rate. Port
   line-by-line carefully; the math has windowing behavior that
   doesn't survive sloppy translation.
2. **Substrate uplifts that will surface** — slice 1 of arc 025
   surfaced `sort-by`; slice 2 surfaced `not=` + Enum equality.
   IndicatorBank will surface more — likely statistical helpers
   (variance, stddev), `Vec` accessors not yet promoted, and
   possibly autocorrelation kernels. Each ships as a carry-along
   to wat-rs the same way; same pattern.

When this arc closes, arc 025 resumes against the real
`:trading::types::Candle`. SimCandle is officially dead; never
shipped.

---

## What ships

A streaming pipeline at `wat/encoding/indicator-bank/` (new
sub-tree) that ticks once per OHLCV candle and produces a fully-
populated `:trading::types::Candle`. Composed of:

### Helper primitives (slice 1)

`wat/encoding/indicator-bank/primitives.wat` — the reusable
streaming machinery archived `indicator_bank.rs` factors out:

```scheme
(:wat::core::struct :trading::encoding::RingBuffer
  (values   :Vec<f64>)
  (capacity :i64))
;; push, get-at-offset, length, full?, sum, mean, min, max, slice

(:wat::core::struct :trading::encoding::EmaState
  (period :i64)
  (alpha  :f64)
  (value  :f64)
  (count  :i64)
  (ready? :bool))
;; new(period), update(state, x), value, ready?

(:wat::core::struct :trading::encoding::SmaState
  (period :i64)
  (buffer :trading::encoding::RingBuffer)
  (sum    :f64))
;; new(period), update(state, x), value, ready?

;; WilderState already shipped in arc 025 slice 1; re-export from
;; that location.
```

### Per-indicator state structs (slices 2-11)

Grouped by indicator family. Each family slice ships:
- one wat file per indicator (or per cohesive family)
- struct + new + update + value/component accessors
- per-indicator tests (3-4 each: construction, update mechanics,
  ready? gate, convergence/edge-case)

Family breakdown matches archive's grouping:

- **Slice 2 (oscillators):** RsiState, StochState, CciState, MfiState, Williams%R (compute fn).
- **Slice 3 (trend):** SmaState consumers (sma20/50/200 via shared SmaState; not separate types), MacdState, DmiState (plus_di, minus_di, ADX).
- **Slice 4 (volatility):** Bollinger (computed from SmaState + stddev helper), Keltner (EMA + ATR), squeeze (BB inside Keltner), atr-ratio.
- **Slice 5 (volume):** ObvState (with slope helper over RingBuffer), volume_accel (SMA-of-volume + ratio).
- **Slice 6 (rate-of-change + range positions):** compute_roc (1, 3, 6, 12), compute_range_pos (12, 24, 48). Pure functions over RingBuffer.
- **Slice 7 (multi-timeframe):** compute_tf_ret/body/agreement over hour-aligned RingBuffers (60- and 240-period at 5-min resolution).
- **Slice 8 (Ichimoku):** IchimokuState — tenkan_sen, kijun_sen, cloud_top, cloud_bottom, tk_cross_delta. Multi-window state machine.
- **Slice 9 (persistence):** Hurst exponent, autocorrelation, vwap_distance. The first statistical-estimator slice.
- **Slice 10 (regime):** kama_er, choppiness, dfa_alpha, variance_ratio, entropy_rate, aroon_up/down, fractal_dim. The biggest slice; multiple statistical estimators.
- **Slice 11 (divergence + cross-deltas + price-action):** rsi_divergence_bull/bear, stoch_cross_delta, range_ratio, gap, consecutive_up/down.

### IndicatorBank orchestration (slice 12)

`wat/encoding/indicator-bank/bank.wat` — the integrating struct.
Owns all per-indicator states. `tick(ohlcv) -> (state', candle)`
returns a fully-populated `:trading::types::Candle` plus updated
state.

```scheme
(:wat::core::struct :trading::encoding::IndicatorBank
  ;; All per-indicator states as fields. ~30+ fields.
  (sma20    :trading::encoding::SmaState)
  (sma50    :trading::encoding::SmaState)
  (sma200   :trading::encoding::SmaState)
  (rsi      :trading::encoding::RsiState)
  (atr      :trading::encoding::AtrState)        ; from arc 025
  (atr-window :trading::encoding::AtrWindow)     ; from arc 025
  (phase    :trading::encoding::PhaseState)      ; from arc 025 (in pivot.wat)
  (macd     :trading::encoding::MacdState)
  (dmi      :trading::encoding::DmiState)
  (stoch    :trading::encoding::StochState)
  (cci      :trading::encoding::CciState)
  (mfi      :trading::encoding::MfiState)
  (obv      :trading::encoding::ObvState)
  (ichimoku :trading::encoding::IchimokuState)
  ;; Plus RingBuffers for ROC/range-pos/timeframe/persistence/regime.
  ...)

(:wat::core::define
  (:trading::encoding::indicator-bank-fresh
    -> :trading::encoding::IndicatorBank)
  ...)

(:wat::core::define
  (:trading::encoding::indicator-bank-tick
    (bank :trading::encoding::IndicatorBank)
    (ohlcv :trading::types::Ohlcv)
    -> :(trading::encoding::IndicatorBank, trading::types::Candle))
  ;; Update every indicator's state with the new OHLCV.
  ;; Build a populated Candle from updated states.
  ;; Return (new-bank, candle).
  ...)
```

The tick is values-up: input bank → output bank + candle. No
mutation. Per-candle work is bounded; archive ran ~1k candles/s,
wat will likely do 200-500/s (5-10x slower); 6-year stream
finishes in tens of minutes — bounded but not interactive.

### INSCRIPTION + cross-link (slice 13)

INSCRIPTION.md captures the substrate uplifts that surfaced
over the arc's life, the LOC delta per slice, the test count
delta. Cross-link `rewrite-backlog.md` Phase 5's IndicatorBank
row → "shipped under lab arc 026."

---

## Decisions resolved

### Q1 — One big arc, or split into batches?

**One big arc.** The user picked this explicitly. Reasoning:
no "what's populated, what isn't" question; the Candle struct's
73 fields all get populated honestly; thinkers can read any
field without runtime nan-checks; arc 025 resumes against a real
data source.

Cost: ~3 weeks. Slice cadence (1.5-2 days each) keeps the work
ledger honest. Each slice ships green before the next opens.

### Q2 — Inherit arc 025's already-shipped slices

Three modules are already in wat from arc 025:

- `wat/encoding/atr.wat` (AtrState + Wilder)
- `wat/encoding/atr-window.wat` (AtrWindow median)
- `wat/encoding/phase-state.wat` (PhaseState + TrackingState)

Arc 026's slice 12 (IndicatorBank orchestration) imports these.
The structs are referenced by their existing paths; no
re-shipping. The slice 1 streaming-primitives module re-exports
WilderState's helper for use by other Wilder consumers (e.g.,
DmiState's `step_dmi` uses a Wilder-smoothed plus_di / minus_di).

### Q3 — Where does the IndicatorBank live?

**`wat/encoding/indicator-bank/`** — new sub-tree. Justified:
the bank IS encoding (it produces the Candle that vocab modules
encode into HolonAST); it's a heavy enough piece to deserve its
own directory (10+ wat files); it's not a vocab (Phase 2),
not a learner (Phase 4 — the future Reckoner+Engram), and not a
domain entity (Phase 5 — observers, broker, treasury). Sibling
to `wat/encoding/round.wat`, `scale-tracker.wat`, `rhythm.wat`,
`atr.wat`, `phase-state.wat`.

When the IndicatorBank's tick runs, the result feeds
`wat/encoding/rhythm.wat` (already shipped) which turns Candles
into rhythms. Encoding ships the data; vocab speaks against it.

### Q4 — NaN vs ready? gates

**Per-indicator ready? gates, not NaN sentinels.** Each indicator
state has a `(ready? :bool)` field. During warmup (RSI period,
ATR period, etc.), ready? is false; consumer code checks the
gate before using the value. The Candle's field carries whatever
the indicator computed (which during warmup might be bootstrap
or default), but the IndicatorBank also produces a "candle is
ready?" composite gate — true once all indicators have warmed
up.

Why: NaN propagation in wat would force every consuming
expression to handle the NaN case; ready? gates push the check
to one site (the consumer that knows whether it cares). Matches
archive convention.

For the arc-025 simulator's smoke test, the ready? gate's first
true is the candle from which the simulator can start running
papers. Practically: ~200-2016 candles of warmup before the
slowest indicator (regime's autocorrelation, persistence's Hurst,
phase-state's median-week) is ready. v1 simulator skips the
warmup region; the 6-year stream has 650k candles after warmup.

### Q5 — Test strategy

Each indicator state ships with **3-4 wat tests** mirroring
archive's Rust unit tests:

- Construction round-trip (struct + plurals + accessors).
- Update mechanics on a known-input case (e.g., RSI on the
  archive's textbook test vector).
- Ready? gate behavior at the warmup boundary.
- Convergence or edge-case (RSI converges to 50 on flat input;
  ATR converges to TR on constant TR; etc.).

Plus per-slice integration tests (~2 each) that drive a small
synthetic OHLCV sequence and assert the Candle field is in a
sensible range.

Plus slice 12's orchestration tests: full IndicatorBank tick on
a known synthetic stream; cross-check several Candle fields
match the archive's Rust output for the same input. Reproduces
the archive's `prove_indicator_rhythm.rs`-style spot checks.

Total test budget: ~280 tests across slices 1-12. Lab wat tests
go from ~172 (post arc-025 slice 2) to ~450.

### Q6 — Substrate uplifts: anticipated

Likely surfacings (every one ships as a carry-along like slices
1 and 2 of arc 025 did):

- `:wat::std::math::sqrt` — probably exists; used by stddev.
- A `variance` / `stddev` helper for Bollinger and CCI.
- `:wat::std::list::sum` over `:Vec<f64>` — probably exists.
- An autocorrelation kernel (or its components: cross-product
  + lag) for persistence's autocorrelation indicator.
- `f64::ln` — already shipped (arc 046).
- `f64::powi` / `f64::powf` — likely needed for entropy-rate's
  log² and for fractal-dim's box-counting algorithm.

We'll surface them mid-slice and ship the carry-alongs as we go.
Estimate: 5-10 substrate uplifts over the arc's life.

### Q7 — Performance

Wat is slower than Rust. Estimated 200-500 candles/s for the
full pipeline (Rust archive: ~1000-2000 cps). 6-year stream
(652,608 candles) finishes in ~20-30 minutes — bounded but not
interactive. Acceptable for arc 025's yardstick (run over the
full stream once per measurement). If hot, a successor arc
optimizes.

### Q8 — Arc 025 dependency

Arc 025's slices 3-6 wait on arc 026's completion. Specifically:

- **Arc 026 slice 12 must close** before arc 025 slice 3 (types)
  can finalize its `Thinker` signature against
  `:trading::types::Candles` (plural). The signature change is
  one line; the wait is for the data to actually be producible.
- Arc 025's `wat/main.wat` will load arc 026's pipeline at the
  encoding section — `(:wat::load-file! "encoding/indicator-bank/bank.wat")`
  alongside the existing rhythm/scale-tracker loads.

When arc 026 closes, arc 025 BACKLOG.md's slice-3 status
flips from "paused" back to "ready." Arc 025 INSCRIPTION (when
it lands) cross-links arc 026 as the unblocker.

---

## Implementation sketch — slice list

See BACKLOG.md for slice-by-slice detail. Summary:

1. **Streaming primitives** — RingBuffer, EmaState, SmaState, re-export WilderState. (1 day)
2. **Oscillators** — RSI, Stochastic, CCI, MFI, Williams %R. (2 days)
3. **Trend** — SMA20/50/200 (via shared SmaState), MACD, DMI/ADX. (2 days)
4. **Volatility** — Bollinger, Keltner, squeeze, atr-ratio. (1.5 days)
5. **Volume** — OBV (+ slope), volume_accel. (1 day)
6. **Rate of Change + Range positions** — ROC-1/3/6/12, range_pos_12/24/48. (1 day)
7. **Multi-timeframe** — tf-1h-ret/body, tf-4h-ret/body, tf-agreement. (1.5 days)
8. **Ichimoku** — tenkan, kijun, cloud_top/bottom, tk_cross_delta. (2 days)
9. **Persistence** — Hurst, autocorrelation, vwap_distance. (2.5 days; first statistical slice)
10. **Regime** — kama_er, choppiness, dfa, variance_ratio, entropy, aroon_up/down, fractal_dim. (3 days; biggest slice)
11. **Divergence + cross-deltas + price-action** — rsi_divergence_bull/bear, stoch_cross_delta, range_ratio, gap, consecutive_up/down. (1.5 days)
12. **IndicatorBank orchestration** — full struct + tick + integration tests. (2.5 days)
13. **INSCRIPTION + cross-link** — close the arc; mark arc 025 unblocked. (~1 hour)

**Total estimate: ~21 days = ~3 weeks** of focused work.

---

## Sub-fogs

### 5a — The first ready candle

The IndicatorBank's `candle-ready?` is true once every per-
indicator gate is true. Slowest gates:

- ATR-window-median (PhaseState's smoothing source) — needs 2016
  candles.
- Regime indicators (Hurst, fractal-dim, DFA) — typically 200-500
  candle windows.
- Multi-timeframe indicators — 240 candles for 4h alignment.

Practical first-ready-candle: ~2016 (the median-week dominates).
Arc 025's simulator will skip candles 0..2015 in its smoke run;
real-data smoke at 10k candles starts measurement at 2016.

### 5b — Floating-point parity with archive

Wat-rs runs on Rust's f64. Same IEEE-754. Bit-identical to the
archive on identical input. No drift expected; any drift is a
porting bug.

A diff-test could compare wat IndicatorBank output to a one-shot
archive run on the same OHLCV input — but that requires the
archive to still be runnable, which it is (it's in
`archived/pre-wat-native/`). Slice 12 can include a
diff-against-archive smoke test if we want extra rigor.

### 5c — Handling `compute_*` free functions

Archive has several free `compute_*` functions (compute_roc,
compute_range_pos, compute_williams_r, etc.). These don't have
state; they're pure over a RingBuffer + scalar inputs. In wat,
each becomes a `:trading::encoding::compute-*` define. No
struct, no state field; just a function.

Slice 6's ROC + range_pos functions are the canonical examples.

### 5d — Memory characteristics

IndicatorBank state is bounded:
- ~30 RingBuffers, each at most ~250 f64 entries (longest is
  sma200 + multi-timeframe 240) → ~30 × 250 × 8 bytes = 60 KB.
- ~15 small state structs → negligible.
- PhaseState's phase-history (already shipped) — bounded by
  2016-candle age; typically <100 records → small.

Per-tick allocation: a fresh IndicatorBank struct (values-up).
That's a deep clone in naive wat semantics; substrate may
optimize. If hot, slice 12's orchestration adds in-place
optimization patterns. Not pre-optimized.

---

## What this arc does NOT add

- **Arc 025 simulator slices 3-6.** Paused until arc 026 closes.
- **The Reckoner-backed Predictor.** Arc 025's Q2 deferral; not
  this arc's concern.
- **`#[wat_dispatch]` shims for indicators.** Pure wat all the
  way down; the lab repo's existing approach.
- **Per-tick optimization.** Values-up is honest first; optimize
  if hot.
- **A new substrate primitive design.** All substrate uplifts
  ship as carry-alongs to wat-rs (`sort-by`, `not=` style); no
  new primitive families.
- **The remaining `domain/*.rs` files** — `treasury.rs`,
  `broker.rs`, `market_observer.rs`, `lens.rs`, `simulation.rs`.
  Phase 5 work; this arc only ships the IndicatorBank piece of
  Phase 5.

---

## Non-goals

- **Performance parity with archive Rust.** Wat will be 5-10×
  slower per tick. Acceptable for the yardstick's measurement
  cadence.
- **Visualization / plotting.** Out of scope.
- **Live data feeds.** Out of scope; arc 025's `:lab::candles::Stream`
  reads parquet only.
- **Cross-pair indicators.** Single-pair (BTC) for v1; multi-pair
  is post-Phase-5.

---

## What this unblocks

- **Arc 025 resumes.** Slice 3's Thinker signature finalizes
  against `:trading::types::Candles`. Slices 4-6 ship as planned.
- **Real first-thinkers can ship.** A thinker reading
  `(rsi, macd-hist, adx, atr-ratio, kama-er, choppiness, hour,
  phase-label)` becomes expressible — comparable to archived
  market_observer.rs's signature reach.
- **Phase 5's IndicatorBank entry resolves.** rewrite-backlog's
  "the monster (2,365L)" line can mark "shipped under lab arc 026."
- **Phase 5's other domain files (treasury, broker, observers)
  have data to consume.** Each subsequent Phase 5 port reads
  Candle fields populated by this arc.
- **Phase 4 (Reckoner + OnlineSubspace + WindowSampler) has a
  data source.** When Phase 4 ports begin, the IndicatorBank-
  produced Candle stream is what they train on.
- **The 6-year BTC parquet becomes useful.** Today the lab can
  read OHLCV; after this arc, the lab can read enriched market
  state. The data was always there; the encoding was the gate.

---

## What we know going in

- **The archive is 100% the spec.** Every indicator has a tested
  Rust impl. We translate, not design.
- **Two-thirds is mechanical.** EMA/SMA-derived indicators (RSI,
  MACD, Stoch, CCI, MFI, Bollinger, Keltner) are state machines
  with simple update rules.
- **A few are subtle.** Hurst, DFA, fractal-dim, entropy-rate.
  Port carefully; the math has windowing behavior.
- **Substrate uplifts will ship as we go.** ~5-10 expected over
  the arc's life. Each rides as a carry-along to wat-rs.
- **The work ends with arc 025 unblocked.** That's the deliverable.

PERSEVERARE.
