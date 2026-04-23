# Lab arc 001 — vocab-opening (Phase 2.1)

**Status:** opened 2026-04-23.
**Scope:** opening Phase 2 of the lab rewrite — port the first
vocab module (`vocab/shared/time.rs`) faithfully to wat,
establish the per-module pattern for the 15+ siblings, and
capture what surfaces as the first contact reveals.

**Parent plan:** `docs/rewrite-backlog.md` Phase 2 section.

**First lab-repo arc.** Arcs through 026 lived in wat-rs. Tonight
the lab repo adopts the same discipline — DESIGN up front,
BACKLOG with status markers, INSCRIPTION at close. Same structure
as `wat-rs/docs/arc/2026/04/<NNN-slug>/` — lab numbering starts
at 001 because this is the lab's first.

---

## What this arc is about

Port `archived/pre-wat-native/src/vocab/shared/time.rs` (113L) to
`wat/vocab/shared/time.wat` as `:trading::vocab::shared::time::*`.
Ship two pure functions:

- `encode-time-facts` — 5 leaf binds, one per circular time
  component (minute, hour, day-of-week, day-of-month,
  month-of-year)
- `time-facts` — 5 leaves + 3 pairwise compositions
  (minute × hour, hour × day-of-week, day-of-week × month)

Comment in the archive: *"Both are vocabulary. The thinker bundles
whatever set it wants. The discriminant picks the winners."* Ship
both — they're two ways of the same lens.

## Why time.rs first

- **Simplest vocab module** — 5 atoms, all `Circular`. No
  HashMap threading, no window iteration, no derived struct.
- **Likely imported by downstream** — time-of-day matters for
  every observer (market, exit, broker).
- **Proves the vocab pattern in wat** — template for the 14
  market modules + 4 exit + 1 broker. Establishes conventions
  (naming, rounding, test shape).
- **No new substrate dependencies** — every primitive needed
  (Candle fields from Phase 1.6, `Circular`, `Bind`, `Atom`,
  `f64::round`) is already shipped.

## Decisions locked before writing

- **Namespace:** `:trading::vocab::shared::time::*`. Matches
  directory hierarchy. Long but honest.
- **No structs.** The archive's `shared/time.rs` has no struct
  (just reads candle fields directly); the wat port matches.
  (Market modules in the archive DO have structs — we'll revisit
  when we port them and decide per-site.)
- **Round to 0 for every circular value.** Per proposal 057's
  RESOLUTION + 033's PROPOSAL: `round_to` at emission time is
  cache-key quantization, NOT signal precision. For time values,
  whole-integer quantization is honest — hour 14.3 and hour 14.7
  share the cache key "hour 14" because the user-level time unit
  IS integer-quantized. Every other vocab module's rounding is a
  context-specific decision carried faithfully from the archive.
- **Ship both `encode-time-facts` and `time-facts`.** Archive
  comment: both are vocabulary.
- **Local `circ` / `bind` / `atom` helpers (file-private).** The
  archive uses three one-liner helpers. Matching that gives five
  readable emission sites instead of five verbose ones. When a
  SECOND vocab module wants the same helpers, extract to a shared
  helpers module — standard "second caller surfaces the pattern"
  rule. YAGNI until then.
- **main.wat loads the new module.** `(load!
  "vocab/shared/time.wat")` added to `wat/main.wat` so the entry
  composes the vocab surface as it grows.

## Tests planned (outstanding bar)

Six tests in `wat-tests/vocab/shared/time.wat`:

1. `test-encode-time-facts-count` — returns 5 facts.
2. `test-time-facts-count` — returns 8 (5 + 3 compositions).
3. `test-hour-fact-coincides-with-expected-shape` —
   fact[1] coincides with hand-built `Bind(Atom("hour"),
   Circular(rounded-hour, 24.0))`.
4. `test-minute-x-hour-composition-coincides` — fact[5] coincides
   with hand-built `Bind(minute-bind, hour-bind)` — verifies the
   composition shape, not just presence.
5. `test-close-hours-share-cache-key` — a candle with hour 14.7
   and a candle with hour 15.1 produce coincident fact sets
   (both round to 15 at digits=0).
6. `test-opposite-hours-differ` — hour 6 and hour 18 (opposite
   points on the 24-period circle) produce NON-coincident fact
   sets. Sanity-checks that Circular's angular encoding is live
   at this layer — that opposite points on the clock sphere don't
   collapse by accident.

## Rounding rationale — carried from the archive

From proposal 057's RESOLUTION:

> The correctness of L1 depends on vocabulary modules embedding
> quantized scalar values in the AST node. `round_to` at emission
> time + `Hash` via `to_bits()` means changed values produce
> changed keys. Stale entries are unreachable, not incorrect.

From proposal 033's PROPOSAL:

> Round to 2 digits — the cache stays finite.
> `round_to(2)` quantizes the scale to ~100 possible values.
> Cache keys change slowly.

The per-site digit count is a deliberate cache-granularity choice.
For circular time values, the unit IS integer (hour 14, minute 30,
day-of-week 2), so `digits=0` is the honest quantization. For
other vocab modules (market/standard, market/oscillators, etc.),
different digit counts encode different cache-granularity choices
(2 for normalized scalars, 4 for small distance ratios, etc.).
Each emission site's digit count is load-bearing — we port
verbatim, we don't infer.

## Connection to Chapter 28's native granularity

At d=1024 substrate resolution is ~1.5% of range (locked in the
`coincident_q_window_around_4_on_range_0_10` test). Cache-key
quantization for time at `digits=0` maps to 1/24 ≈ 4% for the
hour unit — LOOSER than the substrate's resolution. Safe. The
cache-key and the substrate agree that values within one hour are
"the same thing" for routing purposes.

---

## What this arc does NOT ship

- Other vocab modules (market/standard, oscillators, momentum,
  etc.). Those are subsequent arcs once this one's pattern is
  locked and whatever helpers emerged are extracted.
- Shared vocab helpers module. YAGNI until a second caller.
- Phase 3.5 (thought_encoder + encode dispatcher). Depends on
  Phase 2 being populated enough to dispatch over.
- Struct types for vocab modules. The archive has structs for
  window-based modules (StandardThought, OscillatorsThought) —
  those decisions land when those ports land.
- Bulk helpers for `(round val 0)` — the archive has a local
  `circ` function that does round+Circular; port matches that.

---

## Why this is arc-class in the lab

Until now, lab slices have landed as individual commits referencing
`docs/rewrite-backlog.md`. The wat-rs arc discipline (DESIGN
up-front, BACKLOG with status markers, INSCRIPTION recording what
shipped) has proven its value through nine substrate arcs (017,
018, 019, 020, 023, 024, 025, 026). Tonight the lab adopts the
same shape because the same reasons apply: complex slices benefit
from being planned before coded, unknowns benefit from being
named before approached, sub-fogs benefit from resolving as code
lands, completion benefits from being recorded.

The first slice is simple; the discipline cost is near-zero; the
payoff is a pattern future Phase 2 arcs will use.

*Each arc is a lantern; several lanterns make a map.*
