# Backlog — The Phases

What remains between where we are and the machine that trades.

## Done

- [x] **043: Broker survival** — papers never stop, per-broker
  rolling percentile, market observer learns from direction.
  22/22 alive. IMPLEMENTED.

- [x] **049: Phase labeler** — valley/peak/transition on the
  indicator bank. 1.0 ATR smoothing. Fields on Candle. IMPLEMENTED.

- [x] **050: Position observer** — exit→position rename. Ships
  with 049. IMPLEMENTED.

- [x] **044: Sequential ThoughtAST** — seventh generator.
  permute(child, i) + bundle. IMPLEMENTED.

## Phase 2 — Position observer consumes phases

The phase labeler produces labels. Nobody reads them yet.

- [ ] **Position observer reads phase from Candle.** The phase
  label, direction, duration become atoms in the position
  observer's vocabulary. The position observer THINKS about
  which phase it's in.

- [ ] **Phase series as Sequential thought.** The bounded phase
  history (20 records) on the Candle is encoded as a Sequential
  thought. The position observer bundles it with trade atoms
  and market extraction. The reckoner sees the full rhythm.

- [ ] **Phase-aware distance prediction.** The position observer
  predicts wider trail in transition-up (let it run), tighter
  trail in peak zone (protect), wider stop in valley zone
  (give room to accumulate). The phase context shapes distances.

- [ ] **Resolve 049 smoothing tension.** Seykota: 1.0 ATR.
  Van Tharp: 1.5 ATR. Wyckoff: adaptive percentile of recent
  swings. Currently 1.0 ATR. Run 100k. Measure phase rates
  per regime. The data decides.

## Phase 3 — Pivot biography integration (044)

The pivot biography atoms from 044 need the phase labeler.

- [ ] **Trade biography atoms (3).** pivots-since-entry,
  pivots-survived, entry-vs-pivot-avg. "Pivots" become
  "phase transitions" — how many phase changes has this
  trade survived?

- [ ] **Portfolio biography atoms (10).** active-trade-count,
  oldest-trade-phases, portfolio-excursion, portfolio-heat,
  phase-price-trend, phase-regularity, phase-entry-ratio,
  phase-avg-spacing, phase-price-vs-avg.

- [ ] **Pivot series scalars (8).** valley-to-valley trend,
  peak-to-peak trend, range compression, spacing trend,
  candles-since-phase-change, phase-count-in-trade,
  volume-ratio at phase boundary, effort-result at boundary.

- [ ] **Phase-type-specific atoms (Wyckoff).** Valley: test
  count, supply-drying-up. Peak: upthrust count,
  effort-without-result. Transition: acceleration, retracement
  depth, duration ratio to prior zone.

## Phase 4 — Market observer grading from phases

The phase labeler enables grading market observers against
structural truth.

- [ ] **Phase-boundary grading.** Market observer fires high
  conviction → did a phase boundary actually occur? The
  indicator bank knows. Delayed feedback — the boundary is
  confirmed AFTER the conviction fired.

- [ ] **False alarm rate.** How many high-conviction candles
  occur mid-transition (no phase change)? This is a direct
  measure of market observer quality.

- [ ] **Missed boundary rate.** How many phase changes occurred
  without high conviction from the market observer? Another
  quality measure.

## Phase 5 — Treasury

The last program. The brokers propose. The treasury funds.

- [ ] **Treasury program.** Receives proposals from proven
  brokers. Funds proportionally to edge. Manages capital.
  The accumulation model: deploy, recover principal, keep
  residue. Both directions.

- [ ] **Funding predicate.** `resolved >= 200 && ev > 0.0`
  (from 043). The treasury reads this and decides.

- [ ] **Capital allocation.** Kelly or fractional-Kelly. The
  treasury distributes across proven brokers based on their
  curves.

- [ ] **Simultaneous buy/sell.** Different brokers propose
  buy and sell at the same moment. The treasury funds both
  independently. The capital recycles. The residue stays.

## Phase 6 — Measurement

- [ ] **100k benchmark.** The standard test. All phases
  integrated. Measure everything.

- [ ] **Phase rate per regime.** Van Tharp's recommendation.
  How many phases per 1000 candles in trending vs choppy?
  Does the Sequential length vary wildly?

- [ ] **Discriminant decode.** Which atoms predict? The
  glass box opens. The machine explains its own predictions.

## Principles

- The main thread is ONLY a kernel for programs.
- Papers never stop (043).
- The position observer observes the position (050).
- The phase labeler is ground truth on the indicator bank (049).
- The Sequential encodes order. ABC ≠ CBA (044).
- Leaves to root. Always.
- The database is the debugger.
- Commit and push often.
