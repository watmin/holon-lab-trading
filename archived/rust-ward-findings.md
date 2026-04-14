# Rust Ward Findings — Ninth Inscription

Findings from five wards across three Rust tiers. None are blockers.
All are coordinates for refinement. The organism compiles and tests pass.

## Forge findings (craft)

### broker.edge predicts on zero vector
`broker.rs` `edge()` calls `self.reckoner.predict(&Vector::zeros(...))`.
A zero vector has no contextual meaning — it asks "what's my edge in
general?" but the zero vector is a lie. Should take the composed thought
as input, or rename to `baseline_edge`.

### treasury.settle_triggered — 170 lines, three paths welded
Safety-stop, trail/tp/runner, and runner-transition are three distinct
settlement paths in one method. Capital accounting repeated with slight
variations. Extract `settle_one(&trade, price, cost_rate) -> Settlement`
as a pure function. The capital invariant becomes testable in isolation.

### market_thoughts_cache — place where return value would be cleaner
Enterprise writes market-thoughts in step 2, reads in step 3c. An explicit
field on the struct. Threading as a return value would eliminate the cache
and make the fold body purer. Hickey's coordinate from the designer review.

### post.on_candle — loop body does four things
Compose, recommend, propose, register — a pipeline pretending to be one
step. The borrow checker allows it (different fields), but the complexity
is higher than necessary.

## Assay findings (test gaps)

### Lifecycle tests missing on complex methods
- `enterprise.on_candle` — untested (construction test only)
- `treasury.fund_proposals` — untested
- `treasury.settle_triggered` — zero test coverage, most complex function
- `post.on_candle` — untested
- `broker.propagate` — untested
- `broker.tick_papers` — untested

These functions compile and their component parts (reckoner, distances,
etc.) are individually tested. But the lifecycle — fund a trade, tick it,
settle it, propagate — has no end-to-end test at the Rust level.

### indicator_bank test density
42 pub functions but only 13 tests (0.31 ratio). The most complex module
is the least proportionally tested.

## Scry findings (Rust adaptations)

### scalar_accumulator + thought_encoder — extra fields
Both add `dims` and `scalar_encoder`/`ScalarEncoder` as Rust implementation
details. The wat's primitives are ambient; Rust needs explicit objects.
Not behavioral divergence. Consistent across inscriptions.

### engram_gate — EngramGateState struct
Bundles three bare params into a struct. Same data, better Rust ergonomics.
Consistent across inscriptions.

### HashMap<String> for Asset keys
Treasury uses `HashMap<String, f64>` instead of `HashMap<Asset, f64>`.
Keyed by name string, not the Asset struct. Works because Asset is
compared by name. Type-level loosening.

## Vocab gap analysis
See `docs/vocab-gap-analysis.md` for the full catalog:
- 20 facts lost between inscription 5 and inscription 9
- 14 scalar facts from pre-007 with no equivalent
- 2 dissolved modules (harmonics, standard)
- The guide's vocab section needs specific atom lists per module
