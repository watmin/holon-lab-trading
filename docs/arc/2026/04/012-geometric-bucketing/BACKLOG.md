# Lab arc 012 — geometric bucketing — BACKLOG

**Shape:** five slices. Zero substrate (wat-rs) change.

---

## Slice 1 — observation program

**Status: ready.**

New file `docs/arc/2026/04/012-geometric-bucketing/explore-bucket.wat`.
Streams a simulated atom-value sequence through two encodings:

- **Current**: `round-to-2(value)` → Thermometer
- **Bucketed**: geometric `bucket(value, scale)` → Thermometer

For each candle in the stream:
- Update a local ScaleTracker.
- Compute both encodings.
- Track unique encoding counts (by content — `coincident?` check
  or hand-compute hash).

Output tabulates unique-count ratios for:
- Small atom (typical values ~0.02): scale matures ~0.04 after
  warm-up.
- Medium atom (typical values ~0.5): scale matures ~1.0.
- Large atom (typical values ~50): scale matures ~100.

Expected: bucketed version shows **fewer unique encodings** for
large-scale atoms (over-splitting retired) and **similar or more
unique encodings** for small-scale atoms (under-splitting
retired — small values now distinguishable).

**Sub-fogs:**
- **1a — unique-count tallying in wat.** No built-in "set of
  encoded holons" counter. Use a HashSet<String> keyed by a
  content-digest string (atom-name + serialized Thermometer
  triple). Simple to assemble.
- **1b — "mature scale" simulation.** Run each atom's tracker
  through 200 candles before starting the unique-count window.

## Slice 2 — core change

**Status: ready after slice 1 confirms the math.**

Modify `wat/encoding/scale-tracker.wat`:
- Add `bucket-value :: f64 × f64 × f64 -> f64` helper:
  `bucket(value, scale, noise-floor) = round(value / bucket-width) × bucket-width`,
  where `bucket-width = scale × noise-floor`.
- Floor bucket-width at some tiny constant (e.g., `1e-12`) to
  avoid division-by-zero when scale is floored to 0.001 and
  noise-floor is small.

Modify `wat/encoding/scaled-linear.wat`:
- Between scale computation and Thermometer construction, call
  `bucket-value` with the value and scale. Use the bucketed
  value in the Thermometer.

**Sub-fogs:**
- **2a — noise-floor access inside scale-tracker.** Is
  `(:wat::config::noise-floor)` callable from any scope? Yes —
  it's a config accessor (arc 024). Call it at the bucket site.
- **2b — does bucket-width = 0 ever happen?** Scale floors at
  0.001; noise-floor at d=1024 = 0.0313. Product = 3.1e-5 — never
  zero.

## Slice 3 — unit tests

**Status: obvious in shape** (once slice 2 lands).

New tests in `wat-tests/encoding/scale-tracker.wat` (or a new
`wat-tests/encoding/geometric-bucket.wat`):

1. **bucket-rounds-to-nearest-multiple** — raw value maps to
   the nearest multiple of scale × noise-floor.
2. **values-within-bucket-are-identical-encoded** — two values
   inside the same bucket produce identical Thermometer outputs.
3. **values-across-buckets-differ** — two values in adjacent
   buckets produce distinct Thermometer outputs.
4. **bucket-symmetric-around-zero** — positive and negative
   values bucket symmetrically.

## Slice 4 — regression verification

**Status: obvious in shape** (once slices 1 – 3 land).

Run the full lab suite. All 67 existing tests should pass
unchanged. Bucketing at mature scales doesn't shift hand-built
expecteds off coincidence — bucket widths at test scales
(typically 0.01-0.03) are finer than the value magnitudes
involved, and the hand-built expected uses the SAME bucketing
path (via `scaled-linear` or by replaying its steps).

If any test breaks, triage: (a) the test was depending on
blind round-to-2 quantization; (b) the bucketing genuinely
shifted output off the expected shell. Case (a): update test
to use the new geometric quantization in its expected
construction. Case (b): investigate — possibly a scale-floor
interaction.

## Slice 5 — INSCRIPTION + doc sweep

**Status: obvious in shape** (once slices 1 – 4 land).

- `docs/arc/2026/04/012-geometric-bucketing/INSCRIPTION.md`
  records the math, the observation outcome, the scoped change.
- `docs/rewrite-backlog.md` — Phase 3 section gains a
  "geometric bucketing shipped" note (since this is an
  `encoding/` change, not a Phase 2 vocab).
- `docs/proposals/.../058-ast-algebra-surface/FOUNDATION-CHANGELOG.md`
  — row documenting the encoding-layer rule (consumes wat-rs's
  noise-floor, no substrate change).
- Task #50 marked completed.
- Follow-up tasks flagged: vocab round-to-N sweep (optional) +
  startup saturation observation (separate concern).

---

## Working notes

- Opened 2026-04-23 straight after arc 011's scale-precision
  conversation. Builder's insight = the whole spec.
- Arc does NOT fix startup saturation (fresh-tracker Thermometer
  degeneracy). Separate concern; separate future arc if
  pressing.
- Possible follow-up arc names (defer until the need surfaces):
  - "startup scale seeding" — pre-mature trackers from
    historical data
  - "scale floor re-derivation" — replace 0.001 with
    noise-floor-derived minimum
  - "vocab round-to-N retirement" — sweep vocab to remove the
    now-superseded atom-level rounds
