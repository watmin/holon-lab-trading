# Lab arc 020 — exit/phase rhythm function — BACKLOG

**Shape:** three slices. Extends `wat/vocab/exit/phase.wat`
with the rhythm function + helpers; tests; INSCRIPTION.

---

## Slice 1 — vocab module extension

**Status: ready.**

Extend `wat/vocab/exit/phase.wat` with:

**Numeric helpers** (8 lines each):
- `rec-duration r` — i64 → f64 conversion
- `rec-range r` — `(close-max - close-min) / close-avg`, guard close-avg > 0
- `rec-move r` — `(close-final - close-open) / close-open`, guard close-open > 0
- `rec-volume r` — direct volume-avg field access
- `rel a b` — relative-delta with epsilon guard

**User-enum predicates**:
- `same-label-and-direction? a b` — nested match on PhaseLabel ×
  PhaseDirection (both records' fields). For Valley/Peak ignore
  direction; for Transition compare direction.

**Top-level functions**:
- `record-bundle-at-index history i` — produces one per-record
  Bundle (5-11 facts). Builds base facts; conditionally extends
  with prior-deltas (i > 0) and same-deltas (find-last-index
  hits). Wraps in `(Bundle facts)`; unwraps Result.
- `phase-rhythm-holon history` — guards < 4 records → empty
  Bundle. Otherwise: build all record-bundles, truncate to last
  103, window-3 → Sequential trigrams, window-2 → plain-Bind
  pairs, truncate to last 100, wrap in Bundle, then in
  `(Bind (Atom "phase-rhythm") <bundle>)`.

**Sub-fogs:**
- **1a — Bundle Result unwrap.** Bundle returns Result; phase
  bundles are small (≤11 facts), capacity is not a concern.
  Match-unwrap with Atom-sentinel for the Err arm.
- **1b — Sequential return shape.** Sequential is a bind-chain
  combinator (returns HolonAST directly), not Bundle (no Result
  wrap). Plain map over windows works.
- **1c — `(get vec i)` returns Option.** Many lookups (`history[i]`,
  `history[i-1]`, `history[same-idx]`, `(first window)`,
  `(second window)`) need match-unwrap. Sentinel: `default-record`
  for records (already exists in arc 019); `(Atom "unreachable")`
  for HolonASTs.

## Slice 2 — tests

**Status: obvious in shape** (once slice 1 lands).

Extend `wat-tests/vocab/exit/phase.wat` with:

1. **rhythm: insufficient history (< 4 records)** — empty Bundle.
2. **rhythm: exactly 4 records** — produces 2 trigrams, 1 pair,
   wrapped Bundle. Holon shape: `Bind(Atom("phase-rhythm"),
   Bundle([1 pair]))`.
3. **rhythm: more records** — produces (n-2) trigrams, (n-3)
   pairs at n=10. Verify pair count via measurement.
4. **rhythm: budget truncation triggers** — synthesize > 103
   records; verify pair count caps at 100.
5. **same-label-and-direction?: Valley × Valley** — returns true.
6. **same-label-and-direction?: Valley × Peak** — returns false.
7. **same-label-and-direction?: Transition+Up × Transition+Down** —
   returns false (direction differs).
8. **same-label-and-direction?: Transition+Up × Transition+Up** —
   returns true.

Counting trigrams/pairs requires extracting Bundle arity from
the result. Use `:wat::holon::Bundle/items` accessor (auto-
generated per Bundle struct) — wait, Bundle is a HolonAST
variant, not a struct. Use `match` on the Bundle variant of
HolonAST? wat-rs may not expose this — fall back to higher-level
test (e.g., `coincident?` against a hand-built expected).

**Sub-fogs:**
- **2a — Bundle inspection.** wat-rs may not expose Bundle
  variant decomposition at user-tier. Fall back to `coincident?`
  comparison against hand-built expected if needed.

## Slice 3 — INSCRIPTION + doc sweep

**Status: obvious in shape** (once slices 1 – 2 land).

- `docs/arc/2026/04/020-exit-phase-rhythm/INSCRIPTION.md`.
  Records: phase rhythm shipped, completes exit/phase port (3 of
  3 archive functions); same-label lookup via find-last-index
  (the O(n²) trade-off); Sequential-trigram + plain-Bind pair
  composition; budget truncation pattern.
- `docs/rewrite-backlog.md` — Phase 2 gains "2.17 shipped" row.
- `docs/proposals/2026/04/058-ast-algebra-surface/FOUNDATION-CHANGELOG.md`
  — row documenting arc 020.
- Task #76 marked completed.
- Lab repo commit + push.
