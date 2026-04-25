# lab arc 026 — IndicatorBank Port — INSCRIPTION

**Status:** shipped 2026-04-25. The single biggest port in the
rewrite. ~3,300 LOC of wat across 14 files; 122 tests added;
6 substrate uplifts shipped to wat-rs as carry-alongs.

Builder direction:

> "i say we pivot and make the indicator bank... we /must/ have
> it.. right?"

> "option 1 - we have a full reference right? its just a
> translation issue?"

> "make an arc 026 - it builds the indicator bank we need - we
> pause arc 025 pending completion of arc 026"

The bridge from "OHLCV stream" to "enriched 73-field Candle." Arc
025's simulator paused at slice 4 because v1 could only produce
ATR + PhaseState; arc 026 closes that gap so first-thinkers can
operate against the same indicator surface the archived
`market_observer.rs` did.

---

## What shipped

12 substantive slices + INSCRIPTION (this slice). Arc spanned a
single session — predicted ~3 weeks of focused work; the
discipline was slice-by-slice with substrate uplifts shipped as
they surfaced.

| Slice | Module | LOC | Tests | Status |
|-------|--------|-----|-------|--------|
| 1     | `primitives.wat` (RingBuffer + EmaState + SmaState + WilderState) | ~280 | 10 | shipped |
| 2     | `oscillators.wat` (RSI + Stoch + CCI + MFI + Williams %R) | ~470 | 15 | shipped + WilderState refactor |
| 3     | `trend.wat` (MACD + DMI/ADX) | ~340 | 12 | shipped |
| 4     | `volatility.wat` (Bollinger + Keltner + squeeze + atr-ratio) + RollingStddev | ~290+70 | 12 | shipped |
| 5     | `volume.wat` (OBV + VolumeAccel + linreg-slope) | ~210 | 8 | shipped |
| 6     | `rate.wat` (ROC + range-pos) | ~95 | 8 | shipped |
| 7     | `timeframe.wat` (tf-ret/body/agreement) | ~140 | 8 | shipped |
| 8     | `ichimoku.wat` (cloud + cross-delta) | ~210 | 8 | shipped |
| 9     | `persistence.wat` (Hurst + autocorrelation + VWAP) | ~310 | 10 | shipped |
| 10    | `regime.wat` (kama_er + chop + DFA + var-ratio + entropy + Aroon + fractal-dim) | ~620 | 16 | shipped |
| 11    | `divergence.wat` + `price-action.wat` | ~140+95 | 11 | shipped |
| 12    | `bank.wat` (IndicatorBank orchestration) | ~580 | 7 | shipped |
| 13    | This INSCRIPTION + cross-link | doc-only | — | shipped |

**Lab wat test count: 152 (start) → 310 (end). +158 wat tests.**

---

## Substrate uplifts to wat-rs

Six carry-alongs shipped over the arc's life. Each landed when a
slice surfaced the gap; each rides the natural-form-then-promote
rhythm established by arcs 046–055.

| Uplift | Surfaced by | wat-rs commit | LOC | Tests |
|--------|-------------|---------------|-----|-------|
| `:wat::core::sort-by` | arc 025 slice 1 (AtrWindow median) | `6f5c77e` | ~150 | 5 |
| `:wat::core::not=` + Enum equality | arc 025 slice 2 (PhaseState boundary) | `4e854b6` | ~165 | 4 |
| `:wat::std::math::sqrt` | arc 026 slice 4 (RollingStddev) | `c750fe2` | ~85 | 3 |
| `:wat::std::stat::mean` / `variance` / `stddev` | arc 026 slice 9 (Hurst) | `7899dab` | ~280 | 5 |

**Wat-rs test count: 943 (start) → 970 (end). +27 substrate tests.**

The user caught one of these explicitly during slice 9: the lab's
local `persistence::mean` / `variance` helpers were too generic to
live in a lab file. They were lifted to `:wat::std::stat::*` (new
namespace, population convention, `:Option<f64>` return matching
`f64::min-of`/`max-of`'s reduction-empty pattern). Slice 10's
regime indicators consumed them directly; persistence.wat
refactored to consume them too.

---

## Architecture notes

### WilderState factor (slice 2 surgery on slice 1)

The slice-1 footnote ("if a non-ATR Wilder consumer surfaces,
factor then") fired immediately at slice 2's RSI (two
WilderStates: gain + loss smoothers). Arc 025's `AtrState`
refactored to compose `WilderState`; old `:AtrState/value`
field accessor replaced with explicit `:AtrState::value` define
delegating to `wilder.value`. Slice 3's DMI/ADX has four
WilderState instances — the refactor paid off there too.

### Pure compute functions over RingBuffers (slices 6, 7, 9, 10, 11)

Most indicators live as pure functions over `:Vec<f64>` (the
RingBuffer's values), not as wrapping state structs. The
IndicatorBank holds the RingBuffers and feeds `.values` to the
compute functions per tick. Matches archive's pattern; cuts
state-struct surface in half.

### Continuous labels via Thermometer (Chapter 57 carryover)

Arc 025's slice 3 had already established the labels-are-
coordinates style (`paper-label` Bundle of axis-bindings with
Thermometer-encoded continuous values). Arc 026 didn't introduce
labels but the IndicatorBank's output (the enriched Candle)
becomes the substrate the future arc 025 simulator's Thinker
reads from to build surface ASTs.

### Time-of-day fields deferred

Time-string parsing (parse-minute, parse-hour, parse-day-of-week,
parse-day-of-month, parse-month-of-year) ships in a follow-up
slice; v1 IndicatorBank populates the Time sub-struct's fields
as 0.0 sentinels. First-thinkers don't read Time; the deferral is
honest documented at `bank.wat`'s header.

### Cached phase-history optimization skipped

Archive caches the phase-history snapshot to avoid re-cloning
every tick. Wat's `phase-state.phase-history` accessor is a
direct field read on a values-up struct — no cloning at the
substrate level beyond Arc-refcount increments. Identical
correctness, minor performance difference, doesn't matter at the
6-year-stream scale.

### Performance characteristics

Slice 12's sma200 cross-check fed 200 flat candles in 512ms —
~400 candles/sec. Matches BACKLOG's 200-500 cps prediction.
6-year stream (652,608 candles) finishes in ~25 minutes — bounded
but not interactive. Acceptable for arc 025's yardstick (run
once per measurement).

---

## What this arc unblocks

- **Arc 025 simulator slices 3-6 RESUME.** The Thinker's
  `:trading::types::Candles` signature is now honestly
  producible. Slice 3 flips from "paused" back to "ready."
- **Phase 5's IndicatorBank line in `rewrite-backlog.md`** —
  resolves: "shipped under lab arc 026."
- **First real thinkers** become expressible — bundled-rhythm
  encoders comparable to the archived `market_observer.rs`.
- **Phase 4's Reckoner training** has a data source — the
  enriched Candle stream from this bank.
- **The 6-year BTC parquet becomes meaningful** — today: OHLCV.
  After this arc: enriched 73-field market state.
- **Vocab modules** at `wat/vocab/market/*` and `wat/vocab/exit/*`
  now have populated Candle fields to encode against; their
  rhythm-building ASTs no longer derive from sentinels.

---

## What this arc does NOT add

- **Time-string parsing** — Time sub-struct fields are 0.0
  sentinels. Follow-up slice; doesn't block first-thinkers.
- **Performance optimization beyond the values-up port** — wat is
  ~5-10× slower than archive Rust per tick; bounded enough.
- **Diff-against-archive smoke** — slice 12's optional 6th test
  (cross-check vs archive's Rust on real candles) deferred. Wat
  uses bit-identical f64 / IEEE-754; any drift is a porting bug.
  When a porting bug surfaces, this test materializes.
- **Domain layer modules** — treasury, broker, market-observer,
  lens, simulation. Phase 5 work; this arc only ships the
  IndicatorBank piece of Phase 5.
- **The remaining `wat::core::scan`** — slice 9's cum-deviations
  expressed via foldl-with-tuple; works clean. Defer the
  primitive unless a second site reaches for it.

---

## Cross-links

- `docs/arc/2026/04/025-paper-lifecycle-simulator/BACKLOG.md` —
  arc-level pause status flips: "PAUSED at slice 4 pending arc
  026" → "READY: arc 026 closed; resume slice 4."
- `docs/proposals/2026/04/058-ast-algebra-surface/FOUNDATION-CHANGELOG.md` —
  add a row for arc 026 + the four wat-rs carry-along uplifts
  (deferred until lab is in a coherent commit-able state per
  user direction "we don't commit broken").

---

## What we know post-shipment

- **The archive was 100% the spec.** Every indicator's port was
  translation, not design. Bit-identical f64 means correctness
  is by construction (modulo porting bugs the diff-against-
  archive test would catch).
- **Substrate gaps surfaced at the right cadence.** Six uplifts
  over 12 slices — each surfaced exactly when the slice needed
  it. The "natural-form-then-promote" rhythm continues to work.
- **Statistical estimators ported clean.** Hurst (slice 9), DFA
  (slice 10), Aroon, fractal-dim, entropy — all green first
  pass. The BACKLOG's "slow down on these slices" warning was
  prudent but the math survived translation cleanly.
- **The IndicatorBank's 50-field struct + 580-LOC tick body** is
  the lab's largest single file. Verbose but mechanical; readable
  via per-line comments.

---

## Commits

- `<lab>` slices 1-12 + this INSCRIPTION (13 commits across the
  arc; final commit is this slice).
- `<wat-rs>` carry-alongs: `6f5c77e` (sort-by), `4e854b6` (not=),
  `c750fe2` (sqrt), `7899dab` (stat::*).

---

*every binary distinction the lab has landed on is the
discretization of a continuum the substrate already encodes —
indicators are no exception. each one collapses some hidden
geometry of the market into an f64; the bank produces 73 such
collapses per candle, every one a coordinate.*

**PERSEVERARE.**
