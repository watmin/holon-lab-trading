# Lab arc 002 — exit-time vocab

**Status:** opened 2026-04-23. Second lab-repo arc. Direct sibling
of arc 001 (shared/time.wat) — same template, different sub-tree.

**Motivation.** Arc 001 shipped `:trading::vocab::shared::time::*`
as the foundational temporal context vocabulary. The archive also
has `:trading::vocab::exit::time::*` — a strict subset used by
exit-observer brokers that only care about hour + day-of-week for
regime-shift detection.

Two possible framings:

1. **Independent module** — port `vocab/exit/time.rs` verbatim as
   its own wat file, two emission sites, no shared helpers.
2. **Composition over arc 001** — recognize that exit-time's facts
   are a strict subset of shared/time's facts, and define
   `encode-exit-time-facts` as a filter over `encode-time-facts`.

Archive's framing is #1 — a separate file with its own `encode_`
function, its own tests. That's the honest shape; exit observers
have a narrow contextual need and the code makes that explicit at
the call site. Option #2 would save a few emission lines at the
cost of coupling exit semantics to the full time vocabulary's
order. **Pick #1.**

This matches the archive's intent and stays faithful to the
"each vocab family reads its specific sub-struct" pattern arc
001's design refinement established — even when the overlap is
large, each vocab module owns its emission shape.

---

## The input

Like arc 001, this module takes `:trading::types::Candle::Time`
(not the full Candle). The sub-struct has:

- `minute` — exit-time doesn't use
- `hour` — used
- `day-of-week` — used
- `day-of-month` — exit-time doesn't use
- `month-of-year` — exit-time doesn't use

Two fields out of five. The 60% unused-field ratio is fine —
wat accessors are zero-cost (struct auto-generated `/field` getters
from arc 019 slice 4). Callers already have the sub-struct in hand
from `(:trading::types::Candle/time c)`.

## Shape

Match arc 001's emission pattern. File-private `circ` and
`named-bind` helpers copy-pasted from arc 001's time.wat —
pending the "extract to shared vocab-helpers module" move arc 001
deferred until the second caller surfaces.

**This IS the second caller.** Arc 001's INSCRIPTION said:

> The two local helpers (`circ`, `named-bind`) work well for
> time.wat's 5 emission sites. No extraction yet. When the second
> vocab module ports (whatever we pick as lab arc 002) and reaches
> for the same pattern, extract to a shared vocab-helpers module.

But the extraction has a cost and a benefit worth weighing
honestly:

- **Cost:** one new file (`wat/vocab/shared/helpers.wat` or
  similar), one new load edge per caller, one more name to
  remember.
- **Benefit:** one definition per helper; changes land in one
  place; new vocab modules each pay zero ceremony to get the
  pattern.

With 17 more vocab modules queued after this one, 17× the
savings. The extraction is worth it. **Slice 1b opens for the
extraction** — done inside this arc rather than postponing to
a third caller.

## Exports

Two defines:

- `:trading::vocab::exit::time::encode-exit-time-facts`
  — `(Candle::Time) → Vec<HolonAST>`. Two leaf binds:
  - `Bind(Atom("hour"), Circular(hour-rounded, 24.0))`
  - `Bind(Atom("day-of-week"), Circular(dow-rounded, 7.0))`

No composition pairs — exit-time is narrow by design. Exit
observers don't need hour×dow compositions; they read each leaf
independently to spot regime shifts.

## Non-goals

- **No filter-over-shared/time**. Even though
  `encode-exit-time-facts(t) == [encode-time-facts(t)[1], encode-time-facts(t)[2]]`
  would work, it couples exit semantics to shared/time's emission
  order. Pick #1 (independent module).
- **No hour × day-of-week composition**. Archive doesn't ship it;
  exit observers don't use it.
- **No subsumption of this module into an `exit/all.wat`**.
  Exit sub-tree has four modules per the archive
  (phase.rs / regime.rs / time.rs / trade_atoms.rs); they ship
  independently.

---

## Why this is an arc

Every Phase-2 vocab module gets its own lab arc. Arc 001's
INSCRIPTION made the rule explicit:

> Future Phase 2 modules will each open their own lab arc. When an
> arc surfaces a substrate gap (the eight-cave-quest pattern from
> wat-rs arcs 017 through 026), the gap gets its own wat-rs arc
> before the lab arc resumes. Same rhythm, applied to both sides.

Arc 001 had zero substrate gaps. Arc 002 expected to have zero
substrate gaps too (identical primitive requirements); if one
surfaces it will be a wat-rs side quest in the standard cave-quest
shape.

---

## Non-goals for this arc

- **Extracting beyond shared helpers.** `circ` + `named-bind` lift
  out to shared/helpers.wat (slice 1b); anything else stays in its
  vocab module until its own second caller surfaces.
- **Exit tree beyond time.** `exit/phase.rs`, `exit/regime.rs`,
  `exit/trade_atoms.rs` each get their own arcs.
- **Re-testing arc 001.** shared/time.wat tests stay untouched;
  they still pass under the extracted helpers via the rename
  path (slice 1b migrates shared/time.wat's helper call sites
  to the shared names).
