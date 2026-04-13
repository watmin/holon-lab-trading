# Resolution v2: Proposal 044 — Pivot Biography (Final)

**Decision: APPROVED. All five designers converged. Sequential
is the seventh generator. Beckman wins.**

## Strategy designers — unanimous

Seykota: APPROVED (strengthened). Van Tharp: APPROVED (caps
rejection accepted). Wyckoff: APPROVED (volume condition met).

The pivot biography, gap thoughts, pivot series scalars, and
portfolio biography are all approved as vocabulary. No hard caps
on concurrent trades. The reckoner learns from portfolio-heat.
The treasury manages aggregate risk when built.

## Architecture designers — Beckman wins

Beckman: Sequential IS a genuine seventh generator. Ordered
lists are a different source functor than multisets. The
permutation automorphism is not expressible from the existing
six generators. Sequential deserves first-class status.

Hickey: CONDITIONAL — wanted to keep AST at six. Concerned
about queryability: `permute` sacrifices the ability to unbind
a position.

**Resolution: Beckman wins. Sequential is the seventh variant.**

Hickey's queryability concern is addressed by the AST itself.
The position is known from the tree — `children[3]` IS
position 3. You never need to unbind the vector to know the
position. The AST is the queryable form. The vector is the
geometric form. The reckoner cosines the whole vector. The
extraction reads named atoms via cosine. Neither needs
positional unbinding.

holon-rs already has `encode_walkable_list` which uses
`Bind(pos, item)` for JSON/walkable data. The ThoughtAST's
Sequential uses `permute(item, i)` — which Beckman correctly
identifies as the algebraically proper operation for ordered
composition. The walkable list encoder is for generic data.
Sequential is for thoughts. Different source categories,
different encoding strategies, same algebra underneath.

```rust
pub enum ThoughtAST {
    Atom(String),
    Linear { name: String, value: f64, scale: f64 },
    Log { name: String, value: f64 },
    Circular { name: String, value: f64, period: f64 },
    Bind(Box<ThoughtAST>, Box<ThoughtAST>),
    Bundle(Vec<ThoughtAST>),
    Sequential(Vec<ThoughtAST>),  // NEW — seventh generator
}
```

The encoder:

```rust
ThoughtAST::Sequential(items) => {
    let mut vecs = Vec::new();
    let mut all_misses = Vec::new();
    for (i, item) in items.iter().enumerate() {
        let (v, misses) = self.encode(item);
        vecs.push(Primitives::permute(&v, i as i32));
        all_misses.extend(misses);
    }
    let refs: Vec<&Vector> = vecs.iter().collect();
    (Primitives::bundle(&refs), all_misses)
}
```

Caching (Beckman adopted): cache each child independently.
The Sequential recomputes from cached children — permute +
bundle is trivially cheap at N≤20.

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

### Pivot series (Sequential — the seventh generator)

```scheme
(sequential
  pivot-thought-0    ;; permute(thought, 0) — oldest
  gap-thought-0      ;; permute(thought, 1)
  pivot-thought-1    ;; permute(thought, 2)
  gap-thought-1      ;; permute(thought, 3)
  pivot-thought-2)   ;; permute(thought, 4) — most recent
```

Left to right. Position 0 is the oldest. New pivots append at
the end. Existing positions don't shift — cached children keep
their permutation. The series reads like a chart: the story
unfolds in the order it was lived. One vector holds the full
rhythm. Bounded at ~20 entries. The order IS the geometry.

### Pivot series scalars (explicit summaries)

```scheme
(linear "pivot-low-trend" ...)
(linear "pivot-high-trend" ...)
(linear "pivot-range-trend" ...)
(linear "pivot-spacing-trend" ...)
(log "candles-since-pivot" ...)
(log "pivot-count-in-trade" ...)
(linear "pivot-volume-ratio" ...)
(linear "pivot-effort-result" ...)
```

### Trade biography (per-trade, to exit observer)

```scheme
(log "pivots-since-entry" ...)
(log "pivots-survived" ...)
(linear "entry-vs-pivot-avg" ...)
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

1. **ThoughtAST gains Sequential** — seventh variant. `permute` + `bundle`.
2. Broker gains `pivot_memory: VecDeque<PivotRecord>` (bounded ~20)
3. Broker detects pivots from market observer conviction
4. Pivot series encoded as Sequential thought
5. Pivot series scalars computed from pivot memory (8 atoms)
6. Trade biography atoms (3) added to trade update chain
7. Portfolio biography atoms (10) composed with broker thought
8. Gap thoughts recorded between pivots
9. No hard caps on concurrent trades

## What doesn't change

- The holon-rs kernel (permute and bundle already exist)
- The pipeline, observers, chains, telemetry
- Papers register every candle (043)
- The three primitives. The architecture just is.
