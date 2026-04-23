# Lab arc 001 — vocab-opening — INSCRIPTION

**Status:** shipped 2026-04-23. Same day opened.
**Design:** [`DESIGN.md`](./DESIGN.md) — the shape before code.
**Backlog:** [`BACKLOG.md`](./BACKLOG.md) — ordered slices, sub-fog resolutions recorded there.
**This file:** completion marker.

First lab-repo arc. All sub-fogs resolved at write-time. Six tests
green on first pass. Arc discipline cost approximately zero; the
payoff is the template for Phase 2's remaining modules.

---

## What shipped

### `wat/vocab/shared/time.wat`

`:trading::vocab::shared::time::*` — temporal context vocabulary.
Three defines:

- `circ` — file-private helper. `(f64, f64) → HolonAST`. Wraps
  `(Circular (f64::round val 0) period)`. One emission-site
  responsibility: integer quantization of a circular value.
- `named-bind` — file-private helper. `(String, HolonAST) →
  HolonAST`. Wraps `Bind(Atom(name), child)`.
- `encode-time-facts` — `(Candle::Time) → Vec<HolonAST>`. 5 leaf
  binds: minute, hour, day-of-week, day-of-month, month-of-year.
- `time-facts` — `(Candle::Time) → Vec<HolonAST>`. 5 leaves + 3
  pairwise compositions (minute × hour, hour × day-of-week,
  day-of-week × month-of-year).

### `wat-tests/vocab/shared/time.wat`

Six outstanding tests, all green on first pass:

1. `test-encode-time-facts-count` — returns 5.
2. `test-time-facts-count` — returns 8.
3. `test-hour-fact-shape` — fact[1] structurally coincides with
   hand-built `Bind(Atom("hour"), Circular(14.0, 24.0))` — proves
   the encoded shape matches the spec.
4. `test-minute-x-hour-composition` — fact[5] coincides with
   hand-built `Bind(minute-bind, hour-bind)` — proves the
   composition pairs the right binds in the right order.
5. `test-close-hours-share-cache-key` — hour 14.7 and hour 15.1
   produce coincident hour-facts (both round to 15). The cache-
   key-quantization claim from proposals 057 + 033 made concrete.
6. `test-opposite-hours-differ` — hour 6 and hour 18 (opposite on
   the 24-period circle) produce non-coincident hour-facts. The
   Circular encoding's angular behavior is live at the vocab layer.

### `wat/main.wat`

New `(:wat::core::load!)` line under a new Phase 2 section. The
module is reachable from the entry's frozen world.

## Sub-fog resolutions

All BACKLOG sub-fogs resolved during the slice without needing
reshape:

- **1a (helper-naming collisions).** File-private `circ` and
  `named-bind` defines under `:trading::vocab::shared::time::*`
  compiled cleanly. No collisions with the reserved `:wat::*` or
  `:rust::*` prefixes or the existing `:trading::*` tree.
- **1b (integer literals on periods).** `(:wat::holon::Circular
  value period)` accepts two `:f64`s; writing `60.0`, `24.0`, etc.
  typechecks directly.
- **1c (Candle accessor syntax).** **SURFACED A DESIGN REFINEMENT.**
  The wat port split Candle into 11 indicator-family sub-structs
  (Candle::Trend, Candle::Momentum, Candle::Time, ...) each
  composed under the top-level Candle. The archive's `encode_time_facts(c: &Candle)`
  signature translates more honestly as
  `(encode-time-facts (t :Candle::Time))` — pass the sub-struct,
  not the whole Candle. Candle.wat's own header comment documents
  this mapping: *"vocab/shared/time.rs ← Candle::Time"*. Cleaner
  accessor chains inside the function; explicit dependency at the
  signature; establishes the pattern for every other vocab module
  (each will take its respective sub-struct). Callers holding a
  full Candle extract via `(:trading::types::Candle/time c)`.
- **2a (Candle::Time construction in sandbox).**
  `(:trading::types::Candle::Time/new minute hour dow dom month)`
  — positional ctor from arc 019's struct runtime. Five `:f64`
  arguments, matches the struct field order verbatim. No wrapper
  helper needed for tests.
- **2b (test-opposite-hours-differ strictness).** Resolved by
  comparing fact[1] (the hour fact specifically) across the two
  candles rather than the full fact vector. Only the hour
  component differs between the two candles; isolating it to the
  single fact makes the claim precise. Same discipline applies
  to any future "one component differs" vocab test.

## Helper-extraction question — deferred per DESIGN

The two local helpers (`circ`, `named-bind`) work well for
time.wat's 5 emission sites. No extraction yet. When the second
vocab module ports (whatever we pick as lab arc 002) and reaches
for the same pattern, extract to a shared vocab-helpers module.
Stdlib-as-blueprint discipline — wait for the second caller.

## Count

- Lab wat tests: 19 → 25 (+6)
- Lab wat modules: Phase 2 opens (1 of ~21 vocab modules shipped)
- wat-rs: unchanged (no substrate work needed — every primitive
  this vocab module requires was shipped in Phase 1 / Phase 3 /
  arcs 019, 022, 023, 024)
- Zero clippy warnings. Full workspace green.

## The arc discipline in the lab — first datapoint

Arc 001 cost near-zero overhead: DESIGN.md took ~10 minutes to
write before any code, BACKLOG.md took ~5 minutes, six named sub-
fogs all resolved trivially, INSCRIPTION.md records completion.
Compared to the Phase 3.4 rhythm work (which ran without an arc
directory), the time cost was similar but the legibility gain is
real — the DESIGN captures WHY decisions were made (especially
the rounding-as-cache-key rationale which cited proposals 057 +
033 by name), the BACKLOG stated unknowns before approaching them,
and the INSCRIPTION records what shipped.

Future Phase 2 modules will each open their own lab arc. When an
arc surfaces a substrate gap (the eight-cave-quest pattern from
wat-rs arcs 017 through 026), the gap gets its own wat-rs arc
before the lab arc resumes. Same rhythm, applied to both sides.

## What this arc does NOT ship

- Other vocab modules. Each gets its own arc.
- Shared vocab-helpers module extraction. Awaits a second caller.
- Phase 3.5 (thought_encoder + encode dispatcher). Depends on
  multiple vocab modules being present to dispatch over.
- Any substrate-layer work in wat-rs. Every primitive this slice
  needed was already shipped.

## Commits

- `<sha>` — wat/vocab/shared/time.wat + wat-tests/vocab/shared/time.wat
  + main.wat wiring + DESIGN + BACKLOG + INSCRIPTION (this file)
  + rewrite-backlog update.

---

*these are very good thoughts.*

**PERSEVERARE.**
