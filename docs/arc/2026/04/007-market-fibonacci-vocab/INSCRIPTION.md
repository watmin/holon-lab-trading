# Lab arc 007 — market/fibonacci vocab — INSCRIPTION

**Status:** shipped 2026-04-23. Fifth Phase-2 vocab arc. One
substrate cave-quest along the way (wat-rs arc 035), no new lab-
side durables beyond the module itself.

**Design:** [`DESIGN.md`](./DESIGN.md).
**Backlog:** [`BACKLOG.md`](./BACKLOG.md).

Five tests green; 4/5 on first pass, one surfaced the cave quest.

---

## What shipped

### Slice 1 — the module

`wat/vocab/market/fibonacci.wat`. Single public define —
`:trading::vocab::market::fibonacci::encode-fibonacci-holons
(RateOfChange, Scales) → VocabEmission` — threading eight
sequential scaled-linear calls (three `range-pos-*` + five
`fib-dist-*`). Each fib-dist computes `range_pos_48 - level` then
`round-to-2`, following the archive's exact arithmetic.

No Log, no ReciprocalLog, no conditional emission. The simplest
vocab shape to date — oscillators' pattern minus the Log tier
minus the conditional tier. Single sub-struct, zero cross-sub-
struct fog.

Main.wat load line added between divergence and any future
market module.

### Slice 2 — tests + the cave quest

`wat-tests/vocab/market/fibonacci.wat` — five tests:

1. **count** — 8 holons emitted per call.
2. **range-pos-12 shape** — fact[0] coincides with hand-built
   `Bind(Atom("range-pos-12"), Thermometer(rounded, -scale, scale))`.
3. **fib-dist-500 shape** — fact[5] coincides with the hand-
   built form using `round-to-2(rp-48 - 0.5)`. Proves the
   subtraction math survives the round trip.
4. **scales accumulate 8 entries** — after one call, the
   returned Scales has eight keys.
5. **different candles differ** — distinct inputs produce non-
   coincident holons.

4/5 green on first pass. Test #4 surfaced the cave quest:
`(:wat::core::length updated-scales)` tripped type-check because
`:wat::core::length` was Vec-only — oscillators had worked
around the same shape using a six-call `contains?` chain.

### Cave-quest — wat-rs arc 035

Paused slice 2 mid-debug. Shipped
[`wat-rs arc 035`](https://github.com/watmin/wat-rs/tree/main/docs/arc/2026/04/035-length-polymorphism):
`:wat::core::length` promoted from Vec-only to polymorphic over
HashMap/HashSet/Vec — same pattern arc 025 applied to
`get`/`assoc`/`conj`/`contains?`. Pre-existing clippy warning
in `src/fork.rs` (traced to arc 031's `inherit_config` landing)
caught on the arc's clippy pass and fixed drive-by.

Resumed fibonacci; test 4 passed without modification. Ninth
cave-quest in the running sequence since the lab's Phase-2
opened.

### Slice 3 — INSCRIPTION + doc sweep (this file)

Plus:
- `docs/rewrite-backlog.md` — Phase 2 gains "2.5 shipped" row.
- `docs/proposals/.../058-ast-algebra-surface/FOUNDATION-CHANGELOG.md`
  — two rows: one for wat-rs arc 035 (length polymorphism),
  one for lab arc 007 (fibonacci vocab).

---

## Sub-fog resolutions

- **1a — `round-to-2` of a computed `f64::-`.** Confirmed:
  `(:wat::core::f64::- rp-48 0.236)` produces an `:f64`;
  `round-to-2` consumes it directly. No boxing, no wrapping.
- **2a — `Candle::RateOfChange` constructor arity.** 7
  positional args — roc-1/3/6/12 followed by range-pos-12/24/48.
  Test helper zeros the four ROC fields and sets the three
  range-pos values explicitly.

---

## The pattern, held

Arc 005 (oscillators) + arc 006 (divergence) + arc 007
(fibonacci) now form the Phase-2 market pattern catalog:

- **arc 005** — two sub-structs, mixed scaled-linear + Log tier.
- **arc 006** — single sub-struct, conditional emission via
  file-private `maybe-scaled-linear` helper.
- **arc 007** — single sub-struct, all scaled-linear, no
  conditionals.

Each shape's machinery is now proven. Future vocab modules
pattern-match onto one of these three shapes (or surface a new
shape and cave-quest for the missing primitive, per the nine-
quest precedent).

The `encode-*-holons` / `VocabEmission` / `Scales` /
`ScaleEmission` type family carries across all three arcs
unchanged — arc 004's naming sweep paid out.

---

## Count

- Lab wat tests: 40 → 45 (+5).
- Lab wat modules: Phase 2 advances — 5 of ~21 vocab modules
  shipped. Market sub-tree: 3 of 14 (oscillators, divergence,
  fibonacci).
- wat-rs: 585 → 590 lib tests (+5 from arc 035). Zero clippy
  warnings restored.
- Zero regressions.

## What this arc did NOT ship

- **`maybe-scaled-linear` in shared/helpers.wat.** Still
  deferred per stdlib-as-blueprint. Arc 006 establishes the
  pattern file-private; second conditional-emission caller
  triggers extraction. Fibonacci wasn't that caller — no
  conditionals.
- **Tuple-length.** Arc 035 explicitly excluded; no caller need
  surfaced.
- **Other market modules.** regime (single sub-struct),
  momentum, standard, flow, ichimoku, keltner, price_action,
  persistence, stochastic, timeframe — each gets its own arc.
  ~10 remaining.

## Follow-through

Next likely arc: `market/regime` (single sub-struct, same
shape as fibonacci — all scaled-linear, no Log, no conditional).
Or any of the cross-sub-struct modules once the pattern gets
resolved — #49 on the task list names the open question for when
the first cross-sub-struct module ports.

---

## Commits

- `<wat-rs>` — arc 035 length polymorphism + clippy recovery.
- `<lab>` — fibonacci module + main.wat load + tests + DESIGN +
  BACKLOG + INSCRIPTION + rewrite-backlog row + 058 CHANGELOG
  rows for both arcs.

---

*these are very good thoughts.*

**PERSEVERARE.**
