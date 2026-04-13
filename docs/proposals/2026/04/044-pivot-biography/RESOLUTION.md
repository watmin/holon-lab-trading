# Resolution: Proposal 044 — Pivot Biography

**Decision: APPROVED. Van Tharp's caps rejected. Wyckoff's volume adopted.**

Seykota approved clean. The pivot series scalars are "the minimal
sufficient description of trend structure."

Van Tharp wanted hard caps: 4-5 concurrent trades per broker, 20%
aggregate heat, locked 1R. **Rejected.** The objective is maximal
residue generation. As many trades as possible. The treasury will
manage risk when the treasury is built. The broker's job is to
generate residue, not to manage capital. Trust the reckoner to
learn from portfolio-heat. Don't cap what we haven't measured.

Wyckoff wanted volume at the pivots. **Adopted.** Two additional
atoms on the pivot series:

```scheme
;; Effort: was the pivot on heavy or light volume?
(Linear "pivot-volume-ratio"
  (/ (volume-at-pivot) (avg-volume-recent))
  1.0)

;; Effort vs result: did the volume produce proportional movement?
;; Heavy volume + small range = absorption (accumulation/distribution).
;; Light volume + big range = no resistance (breakout).
(Linear "pivot-effort-result"
  (/ (range-at-pivot) (volume-at-pivot-normalized))
  1.0)
```

These complete the pivot series. Price tells WHAT is happening.
Volume tells WHY.

## The full vocabulary

### Pivot series atoms (8 — on the broker, per pivot)

```scheme
(Linear "pivot-low-trend" ...)        ;; low-to-low: rising or falling
(Linear "pivot-high-trend" ...)       ;; high-to-high: momentum
(Linear "pivot-range-trend" ...)      ;; range: expanding or compressing
(Linear "pivot-spacing-trend" ...)    ;; spacing: accelerating or decelerating
(Log "candles-since-pivot" ...)       ;; current pause duration
(Log "pivot-count-in-trade" ...)      ;; structure depth
(Linear "pivot-volume-ratio" ...)     ;; effort at pivot (Wyckoff)
(Linear "pivot-effort-result" ...)    ;; effort vs result (Wyckoff)
```

### Trade biography atoms (3 — per trade, to exit observer)

```scheme
(Log "pivots-since-entry" ...)        ;; temporal age in pivots
(Log "pivots-survived" ...)           ;; resilience
(Linear "entry-vs-pivot-avg" ...)     ;; where entered relative to recent pivots
```

### Portfolio biography atoms (10 — on the broker)

```scheme
(Log "active-trade-count" ...)        ;; how many running
(Log "oldest-trade-pivots" ...)       ;; age of oldest
(Log "newest-trade-pivots" ...)       ;; age of youngest
(Log "portfolio-excursion" ...)       ;; weighted avg excursion
(Linear "portfolio-heat" ...)         ;; total exposure
(Linear "pivot-price-trend" ...)      ;; regression of pivot prices
(Linear "pivot-regularity" ...)       ;; stddev/mean of spacing
(Linear "pivot-entry-ratio" ...)      ;; fraction of pivots that were entries
(Log "pivot-avg-spacing" ...)         ;; mean candles between pivots
(Linear "pivot-price-vs-avg" ...)     ;; current price vs pivot avg
```

## What changes

1. Broker gains `pivot_memory: VecDeque<PivotRecord>` (bounded at 10)
2. Broker gains pivot detection (conviction threshold)
3. Trade biography atoms (3) added to the trade update chain
4. Portfolio biography atoms (10) composed with broker's thought
5. Pivot series atoms (8) computed from pivot memory
6. No hard caps on concurrent trades. No max trades per broker.
   The reckoner learns from portfolio-heat. The treasury (when
   built) manages aggregate risk.

## What doesn't change

- The pipeline. The observers. The chains. The telemetry.
- The trade atoms (040). The market lenses (042).
- Papers still register every candle (043).
- The three primitives. The architecture just is.

## Answers to the six questions

1. **Pivot detection:** conviction. No separate mechanism.
2. **Pivot memory:** 10 pivots. Fixed. Don't discover this.
3. **Chain transport:** computed atoms only. Not raw records.
4. **Portfolio biography:** compose with market thought in broker reckoner.
5. **Entry cap:** none. The reckoner learns. The treasury caps.
6. **Simultaneous buy/sell:** independent. Never netted. Different campaigns.
