# Resolution v2: Proposal 044 — Pivot Biography (Final)

**Decision: APPROVED. All five designers converged.**

## Strategy designers — unanimous

Seykota: APPROVED (strengthened). Van Tharp: APPROVED (caps
rejection accepted). Wyckoff: APPROVED (volume condition met).

The pivot biography, gap thoughts, pivot series scalars, and
portfolio biography are all approved as vocabulary. No hard caps
on concurrent trades. The reckoner learns from portfolio-heat.
The treasury manages aggregate risk when built.

## Architecture designers — tension dissolved

Beckman said Sequential is a genuine seventh generator. Hickey
said keep the AST at six — Sequential is a derived operation.

The datamancer found the resolution: **holon-rs already has this.**

`encode_walkable_list` in the kernel encoder (line 340):
- Walks items in order with `enumerate()`
- Creates position atom `[0]`, `[1]`, `[2]`
- **Binds** position with item — queryable, unbindable
- Bundles all bound pairs

This IS Hickey's `Bind(pos-N, thought)` — already implemented.
Position is known from the walk. The bind preserves queryability.
The AST stays at six generators. The pivot series is a LIST
that the existing encoder walks with automatic position binding.

Beckman's category argument was correct — ordered lists ARE a
different source functor than multisets. The implementation
already handles this through `WalkType::List`. The algebra
didn't need to change. It already supported it.

Hickey's architectural note adopted: `permute` sacrifices
queryability. `Bind(pos, thought)` preserves it. The existing
list encoder uses bind. If extraction ever needs per-position
access — "what was at pivot 3?" — it works.

Beckman's caching note adopted: cache each child independently.
The list recomputation (bind + bundle over cached children) is
trivially cheap at N≤20.

## The complete vocabulary

### Pivot thought (per active pivot period)

```scheme
(bundle
  (bind (atom "pivot-direction") (atom "up"|"down"))
  (linear "pivot-conviction" conviction 1.0)
  (log "pivot-duration" candles)
  (linear "pivot-close-avg" relative-close-avg 1.0)
  (linear "pivot-volume-ratio" vol/avg-vol 1.0)
  (linear "pivot-effort-result" range/volume 1.0))
```

### Gap thought (per silence between pivots)

```scheme
(bundle
  (bind (atom "gap") (atom "pause"))
  (log "gap-duration" candles)
  (linear "gap-drift" price-drift-pct 1.0)
  (linear "gap-volume" avg-vol-ratio 1.0))
```

### Pivot series (ordered list — walked by existing encoder)

The series alternates pivot and gap thoughts. The encoder
binds each with its position and bundles. One vector holds
the full rhythm. Bounded at ~20 entries (10 pivots + 10 gaps).

### Pivot series scalars (explicit summaries)

```scheme
(linear "pivot-low-trend" ...)        ;; low-to-low
(linear "pivot-high-trend" ...)       ;; high-to-high
(linear "pivot-range-trend" ...)      ;; range expansion/compression
(linear "pivot-spacing-trend" ...)    ;; spacing acceleration
(log "candles-since-pivot" ...)       ;; current pause duration
(log "pivot-count-in-trade" ...)      ;; structure depth
(linear "pivot-volume-ratio" ...)     ;; effort at pivot
(linear "pivot-effort-result" ...)    ;; effort vs result
```

### Trade biography (per-trade, to exit observer)

```scheme
(log "pivots-since-entry" ...)        ;; temporal age in pivots
(log "pivots-survived" ...)           ;; resilience
(linear "entry-vs-pivot-avg" ...)     ;; where entered vs recent pivots
```

### Portfolio biography (aggregate, on broker)

```scheme
(log "active-trade-count" ...)
(log "oldest-trade-pivots" ...)
(log "newest-trade-pivots" ...)
(log "portfolio-excursion" ...)
(linear "portfolio-heat" ...)
(linear "pivot-price-trend" ...)
(linear "pivot-regularity" ...)
(linear "pivot-entry-ratio" ...)
(log "pivot-avg-spacing" ...)
(linear "pivot-price-vs-avg" ...)
```

## What changes

1. Broker gains `pivot_memory: VecDeque<PivotRecord>` (bounded ~20)
2. Broker detects pivots from market observer conviction
3. Pivot series encoded as a list (existing `WalkType::List` encoder)
4. Pivot series scalars computed from pivot memory (8 atoms)
5. Trade biography atoms (3) added to trade update chain
6. Portfolio biography atoms (10) composed with broker thought
7. Gap thoughts recorded between pivots
8. No new AST variant. Six generators stay six.
9. No hard caps on concurrent trades.

## What doesn't change

- The ThoughtAST enum (six variants)
- The holon-rs kernel (already supports list encoding)
- The pipeline, observers, chains, telemetry
- Papers register every candle (043)
- The three primitives. The architecture just is.
