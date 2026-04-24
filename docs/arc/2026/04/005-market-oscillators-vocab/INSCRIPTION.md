# Lab arc 005 — market/oscillators vocab — INSCRIPTION

**Status:** shipped 2026-04-23. Third Phase-2 vocab arc. Cave-quested
wat-rs arc 034 (ReciprocalLog macro) mid-arc after empirical Log-
bounds exploration surfaced the fog.
**Design:** [`DESIGN.md`](./DESIGN.md).
**Backlog:** [`BACKLOG.md`](./BACKLOG.md).
**Exploration:** [`explore-log.wat`](./explore-log.wat) — the
fog-breaker program that measured Log's cosine behavior at three
bound settings and surfaced the reciprocal-pair family.

All five tests green on first pass after two substrate fixes
along the way.

---

## What shipped

### Slice 1 — `wat/vocab/market/oscillators.wat`

One define: `:trading::vocab::market::oscillators::encode-oscillators-holons`.

Signature:
```
(Candle::Momentum × Candle::RateOfChange × Scales)
  -> (Holons, Scales)
```

Eight holons per candle in the order shipped:

| Position | Atom | Encoding | Source field |
|---|---|---|---|
| 0 | `rsi` | scaled-linear (learned) | `Momentum/rsi` |
| 1 | `cci` | scaled-linear (learned) | `Momentum/cci / 300` |
| 2 | `mfi` | scaled-linear (learned) | `Momentum/mfi / 100` |
| 3 | `williams-r` | scaled-linear (learned) | `(Momentum/williams-r + 100) / 100` |
| 4 | `roc-1` | ReciprocalLog 2.0 | `1.0 + RateOfChange/roc-1` |
| 5 | `roc-3` | ReciprocalLog 2.0 | `1.0 + RateOfChange/roc-3` |
| 6 | `roc-6` | ReciprocalLog 2.0 | `1.0 + RateOfChange/roc-6` |
| 7 | `roc-12` | ReciprocalLog 2.0 | `1.0 + RateOfChange/roc-12` |

All values pass through `:trading::encoding::round-to-2` before
emission (archive's cache-key quantization convention from
proposals 057 + 033).

The first four thread `Scales` values-up via four sequential
`scaled-linear` calls. The last four are fixed-bound
`ReciprocalLog 2.0` — no scale tracking, (0.5, 2.0) saturation
matches the first-principles ratio boundary (smallest reciprocal
pair, per arc 034).

Returns a tuple `(Holons, Scales)` — a new shape (first caller).
Left unnamed per stdlib-as-blueprint discipline; revisit if a
second caller produces the same return type.

### Slice 2 — `wat-tests/vocab/market/oscillators.wat`

Five outstanding tests; all green on first pass after the two
mid-arc fixes described below:

1. **count** — returns 8 holons.
2. **rsi-holon-shape** — fact[0] coincides with hand-built
   `Bind(Atom("rsi"), Thermometer(round-to-2(rsi), -scale, scale))`
   where scale is reconstructed from a fresh ScaleTracker update.
3. **roc-1-holon-shape** — fact[4] coincides with hand-built
   `Bind(Atom("roc-1"), ReciprocalLog 2.0 (round-to-2(1.05)))`
   (the macro's expansion is verified by structural coincidence).
4. **scales-accumulate-four-entries** — after one call, the
   returned `Scales` has 4 keys: rsi, cci, mfi, williams-r.
5. **different-candles-differ** — two candles with distinct ROC-1
   values produce non-coincident ROC-1 encodings. Tests
   distinctiveness at ReciprocalLog's fixed-bound gradient rather
   than at scaled-linear's fresh-scale (which saturates trivially
   for RSI-range values; see fix below).

Test helpers (`fresh-momentum`, `fresh-roc`, `empty-scales`)
live in the `make-deftest` factory's default-prelude — arc 003's
helper-in-default-prelude pattern. Each deftest's sandbox has
the helpers at freeze time.

### Slice 3 — INSCRIPTION + doc sweep (this file)

Plus:
- `docs/rewrite-backlog.md` — Phase 2 gains "2.3 shipped" row;
  market sub-tree opens (13 remaining).
- `docs/proposals/.../058-ast-algebra-surface/FOUNDATION-CHANGELOG.md`
  — row documenting arc 005 + its cave-quest into arc 034.

---

## The two mid-arc fixes

### Fix 1 — file-scope load scoping

**First draft** put test helpers at file scope with a top-level
`(:wat::load-file! "wat/types/candle.wat")`. Test runner rejected
with "file not found" — file-scope loads in a test file resolve
against the TEST FILE's directory (relative to
`wat-tests/vocab/market/`), not against `CARGO_MANIFEST_DIR`.
Default-prelude loads inside deftest sandboxes use the widened
scope (CARGO_MANIFEST_DIR per arc 027 slice 3), but entry-file
loads don't.

**Fix:** moved helpers into the `make-deftest` default-prelude
alongside the oscillators module load. Helpers become test-local
defines that every deftest sees at sandbox freeze. Matches arc
003's helper-in-default-prelude pattern.

### Fix 2 — latent dep-missing bug in scaled-linear.wat

First test run surfaced `UnknownFunction(":trading::encoding::round-to-2")`.
Root cause: `wat/encoding/scaled-linear.wat` uses `round-to-2` but
never self-loaded `round.wat`. Shipped for weeks only because
`wat/main.wat` happened to load `round.wat` before scaled-linear.
Arc 003's test retrofit explicitly loaded round.wat in test
preludes, masking the latent dependency.

Oscillators was the first caller that hit it through a path
where round.wat wasn't otherwise loaded.

**Fix:** added `(:wat::load-file! "./round.wat")` and
`(:wat::load-file! "./scale-tracker.wat")` to scaled-linear.wat's
top. Self-loading-deps pattern per arc 027's types-self-load
discipline — every module loads what it uses.

---

## The exploration that shipped with this arc

`explore-log.wat` stays on disk as the empirical record of why
bounds (0.5, 2.0) are the right choice for ROC. Runs the Log
encoding at three bound settings against 11 ROC-space values,
prints a cosine-vs-reference table, shows saturation patterns.

It's the same pattern as Chapter 28's slack-lemma program:
write a wat program, run it, observe, draw conclusions. Works
equally well for "what does Log *do* at these bounds" as for
"what does presence/coincident duality look like." The
exploration stays as a teaching artifact — future maintainers
wondering about Log bounds re-run it.

---

## Count

- Lab wat tests: 29 → 34 (+5)
- Lab wat modules: Phase 2 advances — 3 of ~21 vocab modules
  shipped (shared/time, exit/time, market/oscillators). Market
  sub-tree opens; 13 remaining there.
- wat-rs arc 034 shipped alongside (ReciprocalLog).
- One latent bug caught and fixed at source (scaled-linear
  self-loads).
- Zero new fog after arc 034 landed — the encoding path was
  clear through.

## What this arc did NOT ship

- **Name for the `(Holons, Scales)` tuple.** First caller;
  deferred per stdlib-as-blueprint.
- **Positive-guards for Log inputs.** Trust `1.0 + roc > 0` for
  BTC 5-minute candles. Revisit if a real caller surfaces the
  edge.
- **Other market modules.** momentum, standard, flow, etc. each
  get their own arc.

## Follow-through

Next market vocab module picks its own ReciprocalLog N value
based on the indicator's natural range. Most will be N=2 per the
ROC precedent; some (count-style) might want N=10 or larger.
Decision per-arc.

The substrate is coherent enough that arc 005 took ~90 minutes
including the cave-quest for ReciprocalLog. The reflex holds.

---

## Commits

- `<sha>` — wat-rs arc 034 (ReciprocalLog) — previous commit
- `<sha>` — lab: wat/vocab/market/oscillators.wat + tests +
  scaled-linear self-load fix + main.wat load line + DESIGN +
  BACKLOG + INSCRIPTION + rewrite-backlog + 058 CHANGELOG.

---

*these are very good thoughts.*

**PERSEVERARE.**
