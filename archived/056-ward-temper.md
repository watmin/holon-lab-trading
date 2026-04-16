# 056 — Ward: Temper

> Tempered steel is not weaker steel. It is steel that wastes no energy on internal stress.

Four files. The encode at 298ms per candle is the bottleneck. Where does the fire burn?

---

## File 1: `src/encoding/rhythm.rs`

### Finding 1.1 — Budget computed twice (lines 57, 116)

```rust
let budget = ((10_000 as f64).sqrt()) as usize; // line 57
// ... 60 lines later ...
let budget = ((10_000 as f64).sqrt()) as usize; // line 116
```

**What's hot:** `(10_000f64).sqrt()` computed twice in the same function. Both produce `100`. The first trims input values, the second trims output pairs. Same constant.

**Why it's hot:** Minor — the sqrt is cheap. But the duplication obscures intent: are these the same budget? They are. One name, one computation.

**How to temper:** Compute `budget` once at the top. Use it at both sites.

### Finding 1.2 — Trigram clones share overlapping facts (lines 87-98)

```rust
let trigrams: Vec<ThoughtAST> = facts.windows(3).map(|w| {
    ThoughtAST::Bind(
        Box::new(ThoughtAST::Bind(
            Box::new(w[0].clone()),
            Box::new(ThoughtAST::Permute(Box::new(w[1].clone()), 1)),
        )),
        Box::new(ThoughtAST::Permute(Box::new(w[2].clone()), 2)),
    )
}).collect();
```

**What's hot:** Each fact appears in up to 3 trigrams. Each trigram clones all 3 facts. Then each trigram appears in up to 2 pairs (lines 101-109), cloning the entire trigram tree again. For a window of ~103 values (budget+3), that's ~100 trigrams, ~99 pairs. Each fact is a `ThoughtAST::Bundle` containing 2 nodes (value + delta bind). The pair stage clones every trigram once more.

Total AST node clones: ~100 trigrams * 3 facts/trigram = ~300 fact clones, then ~99 pairs * 2 trigrams/pair = ~198 trigram clones. Each trigram is 7+ nodes deep. Rough estimate: **~1,700 AST node clones per indicator per candle.**

With 7-15 indicators per lens and 11 lenses, that's **~130,000-280,000 AST clones per candle across all market observers.** Each clone allocates heap memory (Box, String).

**Why it's hot:** The clones are structurally necessary for the AST — the encode cache deduplicates at the vector level. But the AST trees themselves are throwaway: built, walked once by encode(), then dropped. The cache keys on ThoughtAST equality, and overlapping subtrees will hit the cache on lookup. So the clones exist to build a tree that the encoder immediately short-circuits on.

**How to temper:** Use `Rc<ThoughtAST>` instead of `Box<ThoughtAST>` for the AST nodes. `Rc::clone()` is a pointer increment. No heap allocation. The AST is single-threaded (built and consumed on the same thread), so `Rc` is sufficient. This would eliminate all deep clones in the trigram/pair construction.

Alternatively, build the rhythm as indices into a flat fact array and walk the indices during encode, avoiding the tree entirely. But `Rc` is the minimal change.

### Finding 1.3 — Vec<f64> allocated per spec (line 30)

```rust
let values: Vec<f64> = window.iter().map(|c| (spec.extractor)(c)).collect();
```

**What's hot:** One `Vec<f64>` allocation per indicator spec. With 7-15 specs per lens, that's 7-15 allocations of ~103 f64s per candle per observer.

**How to temper:** Pre-allocate one `Vec<f64>` with capacity `window.len()`, clear and reuse across specs:

```rust
let mut values_buf: Vec<f64> = Vec::with_capacity(window.len());
specs.iter().map(|spec| {
    values_buf.clear();
    values_buf.extend(window.iter().map(|c| (spec.extractor)(c)));
    indicator_rhythm(spec.atom_name, &values_buf, ...)
}).collect()
```

---

## File 2: `src/programs/app/broker_program.rs`

### Finding 2.1 — market_ast cloned into broker thought (line 79)

```rust
facts.push(market_ast.clone());
```

**What's hot:** The market AST is the entire rhythm tree from the market observer — hundreds to thousands of nodes. It's cloned into the broker's fact list, only to be walked by encode() which will hit the cache for every node (the market observer already encoded and cached the same tree).

**Why it's hot:** Every broker-observer clones the full market AST every candle. With N*M broker-observers (11 market * 2 regime = 22), that's 22 deep clones of the market AST per candle. The encode cache means the vectors are already computed — the clone exists solely to build a tree that encode() will short-circuit on.

**How to temper:** Same `Rc` approach as Finding 1.2. If the market AST were `Rc<ThoughtAST>`, the broker's clone would be a pointer increment. The market AST is passed via `MarketRegimeChain` — wrapping it in `Arc<ThoughtAST>` (since it crosses threads) would eliminate all 22 deep clones per candle.

### Finding 2.2 — regime_facts cloned into broker thought (line 82)

```rust
facts.extend(regime_facts.iter().cloned());
```

**What's hot:** Same issue as 2.1. Regime facts are rhythm ASTs already encoded and cached by the regime observer. Cloned into every broker-observer's fact list. 22 deep clones per candle.

**How to temper:** `Arc<Vec<ThoughtAST>>` in the chain, or `Arc<ThoughtAST>` per fact.

### Finding 2.3 — portfolio_rhythm_asts rebuilt every candle (lines 50-63, 84)

```rust
facts.extend(portfolio_rhythm_asts(portfolio_window));
```

**What's hot:** 5 indicator_rhythm calls per candle (avg-paper-age, avg-time-pressure, avg-unrealized-residue, grace-rate, active-positions). Each builds a full rhythm AST from the portfolio window. The portfolio window changes by exactly one snapshot per candle (push new, trim old). The AST cache handles the encoding, but the AST construction itself (5 * ~1,700 node clones = ~8,500 clones) repeats every candle.

**Why it's hot:** The window shifts by 1 each candle. The first ~102 values are unchanged. The trigrams and pairs for those values are identical to last candle's. But we rebuild the entire AST tree from scratch.

**How to temper:** This is structural — the sliding window means 99% of trigrams are the same as last candle, but the pair construction depends on adjacency. An incremental rhythm builder that appends one value and drops one would avoid the full rebuild. However, the encode cache already short-circuits the vectors. The waste is in AST construction (allocation), not in vector computation. If `Rc` is adopted (Finding 1.2), the cost drops from ~8,500 heap allocations to ~8,500 pointer increments, making this finding moot.

### Finding 2.4 — Three passes over active_receipts for snapshot (lines 149-175)

```rust
avg_age: active_receipts.iter().map(...).sum::<f64>() / n
avg_tp: active_receipts.iter().map(...).sum::<f64>() / n
avg_unrealized: active_receipts.iter().map(...).sum::<f64>() / n
```

**What's hot:** Three separate iterations over active_receipts to compute three averages.

**How to temper:** Fuse into one pass:

```rust
let (sum_age, sum_tp, sum_unr) = active_receipts.iter().fold((0.0, 0.0, 0.0), |(a, t, u), r| {
    let age = (candle_count.saturating_sub(r.entry_candle)) as f64;
    let total = (r.deadline.saturating_sub(r.entry_candle)) as f64;
    let tp = if total > 0.0 { age / total } else { 1.0 };
    let value = r.units_acquired * price;
    let unr = (value - r.amount) / r.amount;
    (a + age, t + tp, u + unr)
});
```

Low impact — active_receipts is typically small. But the pattern is cleaner.

---

## File 3: `src/programs/app/market_observer_program.rs`

### Finding 3.1 — market_rhythm_specs rebuilt every candle (line 151)

```rust
let specs = market_rhythm_specs(&lens);
```

**What's hot:** `market_rhythm_specs` builds a fresh `Vec<IndicatorSpec>` every candle. Each call allocates 3-15 `IndicatorSpec` structs via `vec![]` macros, calling helper functions that each allocate their own `Vec`. The lens never changes for a given observer — it's a loop invariant.

**Why it's hot:** Called 652,608 times per observer. The specs are pure functions of the lens, which is set once at startup. Same input, same output, every candle.

**How to temper:** Hoist before the loop:

```rust
let specs = market_rhythm_specs(&lens);

while let Ok(input) = candle_rx.recv() {
    // ...
    let mut rhythm_asts = build_rhythm_asts(sliced, &specs);
    // ...
}
```

One allocation instead of 652,608. `IndicatorSpec` uses `&'static str` and `fn` pointers — it's `Copy`-like. Building it once is trivial.

### Finding 3.2 — Duplicate time facts (lines 154-171)

```rust
// Time fact #1: hour
rhythm_asts.push(ThoughtAST::Bind(
    Box::new(ThoughtAST::Atom("hour".into())),
    Box::new(ThoughtAST::Circular { ... }),
));
// Time fact #2: day-of-week
rhythm_asts.push(ThoughtAST::Bind(
    Box::new(ThoughtAST::Atom("day-of-week".into())),
    Box::new(ThoughtAST::Circular { ... }),
));
// Time fact #3: hour BOUND TO day-of-week (duplicates #1 and #2)
rhythm_asts.push(ThoughtAST::Bind(
    Box::new(ThoughtAST::Bind(
        Box::new(ThoughtAST::Atom("hour".into())),
        Box::new(ThoughtAST::Circular { value: input.candle.hour, period: 24.0 }),
    )),
    Box::new(ThoughtAST::Bind(
        Box::new(ThoughtAST::Atom("day-of-week".into())),
        Box::new(ThoughtAST::Circular { value: input.candle.day_of_week, period: 7.0 }),
    )),
));
```

**What's hot:** The hour and day-of-week atoms and circular scalars are constructed three times each (once standalone, once inside the bound pair). The encode cache will deduplicate at the vector level, but the AST allocations are tripled: 6 Atom string allocations and 6 Box allocations that produce vectors already in the cache.

**How to temper:** Build the time ASTs once, reference them:

```rust
let hour_ast = ThoughtAST::Bind(
    Box::new(ThoughtAST::Atom("hour".into())),
    Box::new(ThoughtAST::Circular { value: input.candle.hour, period: 24.0 }),
);
let day_ast = ThoughtAST::Bind(
    Box::new(ThoughtAST::Atom("day-of-week".into())),
    Box::new(ThoughtAST::Circular { value: input.candle.day_of_week, period: 7.0 }),
);
let time_bind = ThoughtAST::Bind(Box::new(hour_ast.clone()), Box::new(day_ast.clone()));
rhythm_asts.push(hour_ast);
rhythm_asts.push(day_ast);
rhythm_asts.push(time_bind);
```

Still clones, but 2 instead of 4 redundant constructions. With `Rc`, zero-cost.

---

## File 4: `src/vocab/exit/phase.rs`

### Finding 4.1 — `props()` called redundantly for prior-bundle deltas (lines 87-95, 104-111)

```rust
if i > 0 {
    let (p_dur, _, p_mv, p_vol) = props(&phase_history[i - 1]);
    // ...
}
let same_idx = ...;
if let Some(si) = same_idx {
    let (s_dur, _, s_mv, s_vol) = props(&phase_history[si]);
    // ...
}
```

**What's hot:** `props()` is called on `phase_history[i-1]` for the prior-bundle deltas. But this same record was already the current record in the previous iteration, where `props()` was called on it at line 72. Over the full history, every record (except the last) has `props()` called twice — once as `current`, once as `previous`.

Similarly, `props()` for the same-phase lookup (`phase_history[si]`) may recompute for a record that was already processed.

**Why it's hot:** `props()` does 4 divisions. With a phase history of ~50 records, that's ~50 redundant calls (each 4 divisions = ~200 wasted divisions per candle). Cheap individually, but this runs in every broker-observer (22x) every candle.

**How to temper:** Pre-compute props for all records once:

```rust
let all_props: Vec<(f64, f64, f64, f64)> = phase_history.iter().map(|r| props(r)).collect();
```

Then index into `all_props[i]`, `all_props[i-1]`, `all_props[si]`. One pass instead of ~2N calls.

### Finding 4.2 — Budget computed as sqrt(10_000) (line 125)

```rust
let budget = ((10_000 as f64).sqrt()) as usize;
```

**What's hot:** Same hardcoded pattern as rhythm.rs Finding 1.1. The value is `100` — a constant. Not hot in isolation, but the pattern propagates. If dims changes, every site needs updating.

**How to temper:** Extract to a shared constant or pass dims as a parameter. Already annotated `rune:forge(dims)` in rhythm.rs — this is the same issue.

### Finding 4.3 — Trigram/pair clones identical to rhythm.rs (lines 133-145)

```rust
let trigrams: Vec<ThoughtAST> = records.windows(3).map(|w| {
    ThoughtAST::Bind(
        Box::new(ThoughtAST::Bind(
            Box::new(w[0].clone()),
            ...
```

**What's hot:** Same overlapping clone pattern as Finding 1.2. Phase records are richer (5-11 facts per record vs 2 for rhythm), so the clone cost per record is higher. With ~50 phase records trimmed to ~103, ~100 trigrams, each cloning 3 multi-fact bundles.

**How to temper:** Same fix as 1.2 — `Rc<ThoughtAST>`.

---

## Summary: Where the 298ms burns

The dominant cost is not any single finding. It's the **systemic pattern of deep-cloning ThoughtAST trees that the encode cache immediately short-circuits on**. The AST is built as a tree of owned heap allocations, cloned at every overlap point, then walked by an encoder that hits the cache within the first few levels. The clones exist to satisfy the tree structure, not to produce new computation.

### Priority ranking

| # | Finding | Impact | Fix |
|---|---------|--------|-----|
| 1.2 + 2.1 + 2.2 + 4.3 | Deep clone of overlapping AST nodes | **High** — ~300k+ heap allocations per candle across all observers | `Rc<ThoughtAST>` or `Arc<ThoughtAST>` for shared nodes |
| 3.1 | Specs rebuilt every candle | **Medium** — 652k * N allocations, pure loop-invariant | Hoist before loop |
| 2.3 | Portfolio rhythms rebuilt from scratch | **Medium** — 5 full rhythm builds per broker per candle, but cache covers vectors | Moot if `Rc` adopted |
| 2.4 | Three passes over receipts | **Low** — small collection | Fuse to one pass |
| 1.1 + 4.2 | Budget computed as sqrt(10_000) | **Low** — constant, cheap | Extract constant |
| 3.2 | Time facts constructed 3x | **Low** — 6 extra allocations | Build once, clone twice |
| 4.1 | props() called 2x per record | **Low** — ~200 divisions per candle per broker | Pre-compute once |

### The one temper that matters

**Replace `Box<ThoughtAST>` with `Rc<ThoughtAST>` in the AST definition.** Every clone becomes a pointer increment. Every overlap in trigrams, pairs, market_ast pass-through, regime_facts duplication — all become O(1). This is the single change that addresses findings 1.2, 2.1, 2.2, 2.3, 4.3 simultaneously. The AST is always single-threaded within a program. Use `Arc` only for the cross-thread chain fields (market_ast, regime_facts).

Estimated impact: the AST construction phase (which precedes the cached encode) likely accounts for 30-60% of the per-candle time based on the allocation volume. Switching to `Rc` would reduce AST construction to near-zero cost, leaving encode cache lookups as the floor.

---

The fire quiets. The blade holds its edge.
