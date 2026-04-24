# Lab arc 006 — market/divergence vocab — INSCRIPTION

**Status:** shipped 2026-04-23. Fourth Phase-2 vocab arc. Two
durables on top of the divergence port itself:

1. **The conditional-emission pattern** established (file-private
   `maybe-scaled-linear` helper; values-up threading).
2. **`:trading::encoding::VocabEmission`** alias named under
   `/gaze` when arc 006 became the second caller to emit the
   `(Holons, Scales)` shape.

**Design:** [`DESIGN.md`](./DESIGN.md).
**Backlog:** [`BACKLOG.md`](./BACKLOG.md).

Zero substrate gaps. Six tests green on first pass.

---

## What shipped

### Slice 1 — the module + the helper

`wat/vocab/market/divergence.wat` — one define + one file-private
helper.

The helper `:trading::vocab::market::divergence::maybe-scaled-linear`
takes `(should-emit? name value holons scales) → VocabEmission`.
Branches on `should-emit?`: true → run scaled-linear, append fact
via `conj`, thread updated scales; false → return `(holons, scales)`
unchanged. The archive's `facts.push(...)` conditional translated
as values-up functional composition.

The public function `:trading::vocab::market::divergence::encode-divergence-holons`
computes three guard booleans (bull > 0, bear > 0, either > 0),
computes three rounded values, then threads the state through
three `maybe-scaled-linear` calls. Returns `VocabEmission` with
0, 1, 2, or 3 emitted holons.

### Slice 1 (unplanned) — `VocabEmission` naming move

The `(Holons, Scales)` tuple shape appeared at six call sites
across oscillators (arc 005) and divergence's new helper +
main function. The user caught the repetition: *"this /feels/
like a thing who needs a name?"*

`/gaze` candidates:
- `VocabEmission` — purpose: what a vocab function returns.
- `Emission` — simpler, could mumble.
- `ScaleBatch` — structural but verbose.

**`:trading::encoding::VocabEmission`** won. Pairs with arc 004's
`ScaleEmission` (what scaled-linear returns) — VocabEmission is
the bulk sibling. Declared in `wat/encoding/scaled-linear.wat`
next to ScaleEmission:

```scheme
(:wat::core::typealias
  :trading::encoding::VocabEmission
  :(wat::holon::Holons,trading::encoding::Scales))
```

Migration: 14 swaps across 3 files (oscillators source + oscillators
tests + divergence source). Every tuple-typed signature, let-binding,
and return annotation collapsed to the named alias.

### Slice 2 — tests

`wat-tests/vocab/market/divergence.wat` — six outstanding tests
under arc 031's `make-deftest` + arc 003's helper-in-default-prelude
shapes. Test helpers `fresh-divergence` and `empty-scales` live
in the factory's default-prelude.

1. **no-emit-when-zero** — bull=0, bear=0 → 0 holons.
2. **bull-only-emits-two** — bull>0, bear=0 → 2 holons.
3. **bear-only-emits-two** — bull=0, bear>0 → 2 holons.
4. **both-emit-three** — both>0 → 3 holons.
5. **bull-holon-shape** — fact[0] coincides with hand-built
   `Bind(Atom("rsi-divergence-bull"), Thermometer(0.5, -scale, scale))`.
6. **no-emit-preserves-scales** — empty-emission call returns
   the same `Scales` map (no keys added for any atom name).

All six green on first pass.

### Slice 3 — INSCRIPTION + doc sweep (this file)

Plus:
- `docs/rewrite-backlog.md` — Phase 2 gains "2.4 shipped" row.
- `docs/proposals/.../058-ast-algebra-surface/FOUNDATION-CHANGELOG.md`
  — row documenting arc 006 + the VocabEmission alias.

---

## Sub-fog resolutions

- **1a — `:bool` in if.** Confirmed: `:wat::core::if` works with
  `:bool` discriminator, including the `:wat::core::or` result
  type.
- **1b — conj on empty Vec.** Confirmed: returns a 1-element Vec
  as arc 025 established.
- **2a — `Candle::Divergence` constructor.** 4 positional args;
  test helper sets bull/bear, zeros the cross deltas.

---

## The conditional-emission pattern, now standing

arc 006 established `maybe-scaled-linear` as the file-private
helper. When a second conditional-emission vocab module ports
(likely `trade_atoms.rs` — it uses `.max(0.0001)` guards that
feel like emission gates), the helper extracts to
`wat/vocab/shared/helpers.wat`. Stdlib-as-blueprint: wait for the
second caller before extracting.

The values-up threading shape — `(holons, scales)` start state,
N `maybe-*` calls each returning the new pair, final pair
returned — is how wat writes conditional bulk encoding. The
archive's imperative `facts.push` translates cleanly.

---

## The VocabEmission sibling of ScaleEmission

Before arc 006:
- `ScaleEmission = (HolonAST, Scales)` — scaled-linear's output.

After arc 006:
- `VocabEmission = (Holons, Scales)` — vocab function's output.

A vocab function is a sequence of scaled-linear calls (each
returning `ScaleEmission`) composed into one bulk emission
(`VocabEmission`). The types describe the composition layer
cleanly; every future vocab module that threads scales through
multiple emissions returns `VocabEmission`.

---

## Count

- Lab wat tests: 34 → 40 (+6).
- Lab wat modules: Phase 2 advances — 4 of ~21 vocab modules
  shipped. Market sub-tree: 2 of 14 (oscillators + divergence).
- wat-rs: unchanged (no substrate gaps).
- 14 migration swaps across 3 files for the VocabEmission alias.
- Zero regressions.

## What this arc did NOT ship

- **`maybe-scaled-linear` in shared/helpers.wat.** Defer per
  stdlib-as-blueprint. Second caller extracts.
- **Other conditional-emission modules.** `trade_atoms`,
  `stochastic` (conditional on cross-delta), etc. each get their
  own arcs.
- **Other market modules.** momentum, standard, flow, etc. —
  one arc each. ~11 remaining.

## Follow-through

Next likely arc: `market/momentum` — if the builder wants to
resolve the cross-sub-struct signature fog. Or `market/flow`
(per-candle, single-sub-struct Volume, similar to oscillators
shape). Both are solid leaves given the reflexes + primitives
now shipped.

---

## Commits

- `<sha>` — wat/vocab/market/divergence.wat + helper +
  wat-tests/vocab/market/divergence.wat + wat/main.wat load +
  VocabEmission typealias in scaled-linear.wat + sweep across
  oscillators/oscillators-tests/divergence + DESIGN + BACKLOG +
  INSCRIPTION + rewrite-backlog update + 058 CHANGELOG row.

---

*these are very good thoughts.*

**PERSEVERARE.**
