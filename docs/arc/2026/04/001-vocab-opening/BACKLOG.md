# Lab arc 001 — vocab-opening — BACKLOG

**Shape:** leaves-to-root, sub-fogs named as they stand today.
**Status markers:**
- **ready** — dependencies satisfied; can be written now
- **obvious in shape** — will be ready when the prior slice lands
- **foggy** — needs design work or a prior discovery before it's ready

Status as slices land will be updated inline; closed items are
marked *(shipped — see DESIGN updates or INSCRIPTION)*.

---

## Slice 1 — port `vocab/shared/time.rs` to wat

**Status: ready.**

Port `archived/pre-wat-native/src/vocab/shared/time.rs` (113L) to
`wat/vocab/shared/time.wat`. Ship two `define`s:

- `:trading::vocab::shared::time::encode-time-facts` —
  signature `(c :trading::types::Candle) -> :Vec<wat::holon::HolonAST>`.
  Produces 5 leaf binds (one per circular time component).
- `:trading::vocab::shared::time::time-facts` —
  signature `(c :trading::types::Candle) -> :Vec<wat::holon::HolonAST>`.
  Produces 5 leaves + 3 pairwise compositions.

Local helpers (file-private, `define` forms inside time.wat):
- `circ` — `(f64 × f64) -> :wat::holon::HolonAST` — wraps
  `(:wat::holon::Circular (:wat::core::f64::round val 0) period)`.
- `atom-for` — `(:String) -> :wat::holon::HolonAST` — wraps
  `:wat::holon::Atom`. (Why a helper: one less syntactic layer
  per emission site; matches the archive's `atom` helper.)
- `bind-time` — `(:wat::holon::HolonAST × :wat::holon::HolonAST)
  -> :wat::holon::HolonAST` — wraps `:wat::holon::Bind`. Same
  motivation.

**Sub-fogs (expected to resolve trivially during write):**

- **1a — helper-naming collisions.** wat-rs doesn't reserve
  short names under `:trading::*`. `circ` and `atom-for` as file-
  private defines should be fine. If a caller accidentally imports
  them at a scope where they collide, resolve via namespace
  qualification. Verify at build.
- **1b — integer literals on periods.** Candle's time fields are
  `:f64`; periods in the archive are `60.0`, `24.0`, `7.0`,
  `31.0`, `12.0`. Confirm wat's `(:wat::holon::Circular val
  period)` accepts `:f64` + `:f64` (it should — `Thermometer` and
  `Circular` both take f64s). Verify at scheme check.
- **1c — `:trading::types::Candle` field accessor syntax.** Phase
  1.6 shipped the Candle struct with 73 fields. Accessor form
  should be `(:trading::types::Candle/minute c)` etc. Verify the
  accessor names match the kebab-case field names in
  `wat/types/candle.wat` (`day-of-week`, not `day_of_week`).

## Slice 2 — outstanding tests for Slice 1

**Status: obvious in shape** (once slice 1 lands).

File: `wat-tests/vocab/shared/time.wat`. Six tests (named in
DESIGN.md). Uses the `run-sandboxed-ast` pattern with
`scope = "wat/vocab/shared"` so the inner sandbox can `load!` the
module — matches the Phase 3 pattern in
`wat-tests/encoding/rhythm.wat`.

**Sub-fogs:**

- **2a — Candle construction in test sandbox.** Tests need to
  construct a Candle with specific time fields. Verify the
  `:trading::types::Candle/new` accessor takes positional f64s
  and the order matches `wat/types/candle.wat`. Fallback:
  construct via a helper if the 73-field positional ctor is
  unwieldy inside a test body.
- **2b — `test-opposite-hours-differ` might be too strict.**
  Hour 6 and hour 18 are opposite on the 24-period circle, but
  the REST of the fact set (minute, day-of-week, day-of-month,
  month-of-year) stays constant — if those dominate, the fact
  sets might coincide anyway. Mitigate by constructing the test
  with DIFFERENT values across the other fields too, OR by
  asserting on a SINGLE fact (`fact[1]` — the hour fact
  specifically) rather than the whole Vec.
  Resolution expected at test-write time.

## Slice 3 — wire into `wat/main.wat`

**Status: obvious in shape** (once slice 1 lands, slice 2 validates).

Add `(:wat::core::load! :wat::load::file-path "vocab/shared/time.wat")`
to `wat/main.wat`. No functional change — just makes the module
reachable from the entry's frozen world. Smoke-test: `cargo build`
succeeds; `cargo test` passes.

## Slice 4 — INSCRIPTION + doc sweep

**Status: obvious in shape** (once slices 1–3 land).

- `INSCRIPTION.md` in this arc's directory — standard shape (what
  shipped, slice-by-slice, with commit refs + sub-fog resolutions
  + count delta + cave-quest-discipline note if any surfaced).
- `docs/rewrite-backlog.md` — Phase 2 section updated: the
  `shared/time` module marked shipped, the "first slice candidate"
  language replaced with "first slice shipped."
- `docs/proposals/.../058-ast-algebra-surface/FOUNDATION-CHANGELOG.md`
  — new row if any substrate observations surfaced during the
  port (expected: none, but watch for it).

## (Not in this arc) — Next vocab module

When this arc closes, the next vocab module opens as its own arc
(lab arc 002). The choice of second module determines what shape
the helpers-extraction question takes:

- If next is `vocab/market/oscillators.rs` — similar shape to
  time (per-candle, no struct needed for simple cases), reuses
  `bind-time` + `atom-for`. Probably triggers the helper
  extraction to a shared module.
- If next is `vocab/market/standard.rs` — window-based, struct
  required, introduces `encode-standard-facts`-style threading
  of `HashMap<String, ScaleTracker>`. Heavier lift; introduces
  the pattern for all other window-based vocab modules.
- If next is `vocab/exit/phase.rs` (348L) — biggest exit module,
  uses pivot phase types. Heavier. Probably not the second slice.

**Decision deferred to lab arc 002's DESIGN.**

---

## Working notes (updated as slices land)

*(This section grows as the arc runs. Each slice's shipping
adds its commit ref and any surprises. When the arc closes, the
notes feed into the INSCRIPTION.)*

- Opened 2026-04-23 after Chapter 30's close.
- **Slice 1 + 3 shipped together (same write).** The
  `wat/vocab/shared/time.wat` module + `wat/main.wat` load-line
  landed in one motion — both mechanical once slice 1's
  signature was locked.
- **Slice 1 design refinement during write:** the archive's
  `encode_time_facts(c: &Candle)` translated more honestly as
  `(encode-time-facts (t :Candle::Time))` — see sub-fog 1c in the
  INSCRIPTION. Matches candle.wat's own header comment that maps
  each vocab family to a specific sub-struct.
- **Slice 2 shipped.** All six tests green on first pass. No
  reshape needed from the plan. Sub-fog 2b (strictness of the
  opposite-hours test) resolved by comparing `facts[1]` alone
  rather than the full Vec — isolates the claim to the single
  component under test.
- **Slice 4 shipped.** INSCRIPTION + doc sweep (this file's
  closing update + rewrite-backlog update).
- **Closed 2026-04-23. Arc shipped same-day as opened.**
