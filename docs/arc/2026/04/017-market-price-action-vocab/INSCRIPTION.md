# Lab arc 017 — market/price-action vocab — INSCRIPTION

**Status:** shipped 2026-04-24. Fourteenth Phase-2 vocab arc.
Eighth cross-sub-struct port. K=2 (Ohlcv + PriceAction).
**Biggest plain-Log surface yet — 3 Log atoms across 2 different
domain shapes.**

Three durables:

1. **New plain-Log domain shape — count-starting-at-1.**
   `consecutive-up` and `consecutive-down` are asymmetric
   counts: lower-bounded at 1.0 (no streak), upper saturating at
   ~20 consecutive periods. Bounds `(1.0, 20.0)`. Distinct from
   the established fraction-of-price family `(0.001, 0.5)`.
   Future plain-Log atoms with new domain characteristics name
   their bounds in their arc's DESIGN.
2. **First lab `:wat::core::f64::min` consumer.** Substrate
   primitive shipped in arc 046; the first call site arrived
   here for `min(open, close)` in lower-wick. Arc 046's
   "f64::min ships unused" gap closes.
3. **Range-conditional pattern's sixth caller.** flow.wat had
   3, price-action.wat adds 3 — total 6 across two modules.
   Defaults differ (flow uses 0.5/0.5/0.0; price-action uses
   uniform 0.0). Helper extraction question opens to a third-
   module-with-uniform-defaults trigger.

**Design:** [`DESIGN.md`](./DESIGN.md).
**Backlog:** [`BACKLOG.md`](./BACKLOG.md).

Eight tests green on first pass.

---

## What shipped

### Slice 1 — vocab module

`wat/vocab/market/price-action.wat` — one public define. Seven
atoms:
- 4 scaled-linear: `gap` (clamped via `f64::clamp`),
  `body-ratio-pa`, `upper-wick`, `lower-wick` (all three
  range-conditional).
- 3 plain Log:
  - `range-ratio` (fraction-of-price family, bounds `(0.001, 0.5)`,
    round-to-4) — fourth caller after arc 013/015/016.
  - `consecutive-up` (count-starting-at-1 family, bounds
    `(1.0, 20.0)`, round-to-2) — first caller of new domain.
  - `consecutive-down` (same shape as consecutive-up).

Signature alphabetical-by-leaf per arc 011: O < P.

Substrate primitives consumed:
- `:wat::core::f64::max` ×3 (range-ratio floor; consecutive-up
  floor; consecutive-down floor; upper-wick's `max(open, close)`).
- `:wat::core::f64::min` ×1 (lower-wick's `min(open, close)`) —
  **first lab caller**.
- `:wat::core::f64::abs` ×1 (body-ratio-pa's `abs(close - open)`)
  — second lab caller.
- `:wat::core::f64::clamp` ×1 (gap atom).

### Slice 2 — tests

`wat-tests/vocab/market/price-action.wat` — eight tests:

1. **count** — 7 holons.
2. **range-ratio plain-Log shape** — fact[0], fraction-of-price
   family bounds.
3. **gap shape with clamp** — fact[1], `(gap/0.05)` clamped to
   ±1, round-to-4 → scaled-linear. Input `0.10` triggers clamp
   at `1.0`.
4. **consecutive-up plain-Log shape** — fact[2], count family
   bounds. Input 5 → `1+5=6` → Log 6.0 1.0 20.0.
5. **consecutive-up floor** — input -2 → `1+(-2)=-1` → max with
   1.0 → 1.0 → Log at floor edge.
6. **body-ratio-pa shape** — fact[4], cross-Ohlcv compute via
   `f64::abs` + range, round-to-2.
7. **upper-wick shape** — fact[5], tests `f64::max` of two
   free f64 values.
8. **lower-wick shape** — fact[6], **tests `f64::min`** (first
   lab use of the substrate primitive).

All eight green on first pass.

### Slice 3 — INSCRIPTION + doc sweep (this file)

Plus:
- `wat/main.wat` — load line for `vocab/market/price-action.wat`,
  arc 017 added to load-order comment.
- `docs/rewrite-backlog.md` — Phase 2 gains "2.14 shipped" row.
- `docs/proposals/2026/04/058-ast-algebra-surface/FOUNDATION-CHANGELOG.md`
  — row documenting arc 017.
- Task #38 marked completed.

---

## The plain-Log family — two shapes now

| Family | Bounds | Round | Domain | Callers |
|---|---|---|---|---|
| Fraction-of-price | `(0.001, 0.5)` | round-to-4 | always `(0, ~0.5)`, asymmetric | atr-ratio (013), cloud-thickness (015), bb-width (016), range-ratio (017) |
| Count-starting-at-1 | `(1.0, 20.0)` | round-to-2 | always `≥ 1`, asymmetric | consecutive-up (017), consecutive-down (017) |

Both asymmetric, both lower-bounded by their floor input
guarantee, both ship best-current-estimate bounds with empirical
refinement deferred per arc 010 reflex.

The two-family naming makes future Log atoms easier — DESIGN
just states which family the atom joins, or names a new family
if the domain differs. Adds one paragraph; eliminates the
re-derivation.

## First f64::min consumer

Arc 046 shipped `:wat::core::f64::min` alongside `f64::max`.
Lab usage waited for the right call site — `lower-wick =
min(open, close) - low`. Arc 017 closes the "min ships unused"
gap from arc 046's INSCRIPTION's "what this arc did NOT ship"
section.

## Range-conditional pattern — six callers, two modules

Recurrence:

| Module | Atom | Numerator | Default |
|---|---|---|---|
| flow | buying-pressure | `(close - low)` | 0.5 |
| flow | selling-pressure | `(high - close)` | 0.5 |
| flow | body-ratio | `abs(close - open)` | 0.0 |
| price-action | body-ratio-pa | `abs(close - open)` | 0.0 |
| price-action | upper-wick | `(high - max(open, close))` | 0.0 |
| price-action | lower-wick | `(min(open, close) - low)` | 0.0 |

Numerator varies six times; default varies module-uniformly
(flow non-uniform, price-action uniform 0.0). The helper-
extraction question raised in arc 014 still doesn't tip — a
shared helper would need closure-passing or pre-computed
numerator, both fighting wat's let-binding ergonomics.

**Threshold rephrased**: a third module with the same shape AND
uniform defaults would tip. Until then, stay inline.

## Sub-fog resolutions

- **1a — PriceAction constructor arity.** 4-arg per candle.wat;
  helper takes all 4 with order matching struct decl.
- **1b — File name.** `price-action.wat` (kebab-case wat
  convention) for archive's `price_action.rs`. Namespace path
  `:trading::vocab::market::price-action::*` matches.
- **1c — Range-conditional repeats from flow.wat.** Compute
  `range` and `range-positive` once via let-binding, three
  branches with default 0.0 (uniform — different from flow).

## Count

- Lab wat tests: **103 → 111 (+8)**.
- Lab wat modules: Phase 2 advances — **14 of ~21** vocab
  modules shipped. Market sub-tree: **12 of 14**
  (oscillators, divergence, fibonacci, persistence, stochastic,
  regime, timeframe, momentum, flow, ichimoku, keltner,
  price-action). Remaining: **standard** (#43, the heavy port)
  + this market sub-tree's last; plus the exit/* tree.
- wat-rs: unchanged.
- Zero regressions.

## What this arc did NOT ship

- **Empirical refinement of consecutive-up/down bounds.**
  Best-current-estimate `(1, 20)`; explore-log can refine
  later if data shows otherwise.
- **Range-conditional helper extraction.** Threshold not met
  yet (need third module with uniform defaults).
- **`compute-atom` helper.** Question stays open for arc 018
  (standard.wat).

## Follow-through

Next pending vocab arcs:
- **market/standard** (#43) — heaviest, window-based. Multi-
  helper-question reckoning. Last market vocab.
- **exit/phase** (#44) — exit observers tree opens.
- **exit/regime** (#45).
- BLOCKED: trade_atoms (#46 — PaperEntry), portfolio (#47 —
  PortfolioSnapshot, rhythm).

---

## Commits

- `<lab>` — wat/vocab/market/price-action.wat + main.wat load +
  wat-tests/vocab/market/price-action.wat + DESIGN + BACKLOG +
  INSCRIPTION + rewrite-backlog row + 058 CHANGELOG row.

---

*these are very good thoughts.*

**PERSEVERARE.**
