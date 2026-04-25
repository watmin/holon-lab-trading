# Lab arc 020 — exit/phase rhythm function

**Status:** opened 2026-04-24. Seventeenth Phase-2 vocab arc.
Follow-on to arc 019 — ships the third archive function
(`phase_rhythm_thought`) that arc 019 deferred.

**Motivation.** The rhythm function builds the structural memory
of the phase history: per-record Bundles → Sequential trigrams
→ plain-Bind pairs → top-level Bundle, all wrapped in
`(Bind (Atom "phase-rhythm") <bundle>)`. The regime observer
reads this when composing its decision.

Five distinct moves in one function; each modest alone, the
composition substantial:

1. **Per-record Bundle** — 5–11 facts per record (label + 4
   thermometer base, +3 prior-deltas if i > 0, +3 same-label-
   deltas if a same-label record exists earlier in the history).
2. **Same-label lookup** — for each record, find the last
   earlier record with the same (label, direction) pair.
3. **Sequential trigrams** — Sequential over window-3 of the
   per-record Bundles produces `Bind(Bind(a, Permute(b,1)),
   Permute(c,2))`.
4. **Plain-Bind pairs** — window-2 of trigrams produces
   `Bind(t0, t1)` (no Permute — distinct from `Bigram`'s
   Sequential semantics).
5. **Budget truncation** — cap at last 100 pairs (sqrt of
   d=10000); + 3 records before that.

---

## Shape

```scheme
(:trading::vocab::exit::phase::phase-rhythm-holon
  (history :Vec<trading::types::PhaseRecord>)
  -> :wat::holon::HolonAST)
```

Returns ONE HolonAST (not a VocabEmission tuple — no
scaled-linear involvement; the rhythm is pure structural).
Caller (regime observer, future) wraps with the rest of phase
emissions if needed.

Empty-cases return an empty Bundle:
- history < 4 records
- after windowing, pairs is empty

---

## Same-label lookup via `find-last-index`

Archive uses a 5-way mutable state tracker. The wat translation:
for each record at index i, scan `(take history i)` with
`find-last-index` (arc 047) to find the last earlier record
with the same (label, direction) pair.

```scheme
((same-idx :Option<i64>)
  (:wat::core::find-last-index
    (:wat::core::take history i)
    (:wat::core::lambda ((r :PhaseRecord) -> :bool)
      (:trading::vocab::exit::phase::same-label-and-direction?
        r current))))
```

Cost: O(n²) where n ≤ 103 (post-truncation). Realistic histories
are small enough that the quadratic term is invisible. Trade-off:
quadratic for clarity; no 5-tuple accumulator state thread.

The `same-label-and-direction?` helper uses arc 048's user-enum
match on both `:PhaseLabel` and `:PhaseDirection`:

```scheme
(:wat::core::match a-label -> :bool
  (:trading::types::PhaseLabel::Valley
    (:wat::core::match b-label -> :bool
      (:trading::types::PhaseLabel::Valley true)
      (...) false))
  ...
  (:trading::types::PhaseLabel::Transition
    ;; further dispatch on direction
    ...))
```

Verbose but principled — exhaustiveness checking guarantees
every (label, direction) combination is covered.

---

## Per-record Bundle construction

Each record's Bundle has:

| Group | Atoms | Condition |
|---|---|---|
| Base | label binding + 4 thermometers (rec-duration, rec-move, rec-range, rec-volume) | always |
| Prior | 3 deltas (prior-duration-delta, prior-move-delta, prior-volume-delta) | i > 0 |
| Same | 3 deltas (same-move-delta, same-duration-delta, same-volume-delta) | same-idx is Some |

Total: 5 to 11 facts. Each is a `Bind(Atom(name), Thermometer(value, min, max))`.

Thermometer bounds (from archive):
- rec-duration: (0, 200) — phase length in candles
- rec-move: (-0.1, 0.1) — close_open → close_final fraction
- rec-range: (0, 0.1) — high-low fraction of close_avg
- rec-volume: (0, 10000) — raw volume average
- prior-duration-delta: (-2, 2) — relative duration change
- prior-move-delta: (-0.1, 0.1) — absolute move change
- prior-volume-delta: (-2, 2) — relative volume change
- same-move-delta: (-0.1, 0.1)
- same-duration-delta: (-2, 2)
- same-volume-delta: (-2, 2)

Implementation: extract `record-bundle-at-index history i` as a
top-level function so the `map` body stays clean. Body builds
the facts vec via let* + conditional conj steps, then wraps
in `Bundle facts`.

Bundle returns `BundleResult` (Result<HolonAST, CapacityExceeded>)
per arc 032. Phase rhythm bundles are small (5-11 facts each);
capacity isn't a concern. Match-unwrap with sentinel for the
unreachable Err arm.

---

## Sequential trigrams + plain-Bind pairs

After all per-record Bundles are built and history truncated to
last 103:

```scheme
;; window-3 produces Vec<Vec<HolonAST>>; map Sequential over each.
((trigrams :Vec<HolonAST>)
  (:wat::core::map
    (:wat::std::list::window record-bundles 3)
    (:wat::core::lambda ((w :wat::holon::Holons) -> :wat::holon::HolonAST)
      (:wat::core::match (:wat::holon::Sequential w) -> :wat::holon::HolonAST
        ((Ok h) h)
        ((Err _) (:wat::holon::Atom "unreachable"))))))
```

Sequential expands to `Bind(Bind(a, Permute(b,1)), Permute(c,2))`
for window-3 — exactly the archive's shape. Returns
BundleResult... wait, Sequential doesn't return BundleResult,
let me check. Actually Sequential is the bind-chain combinator,
not Bundle — it returns just the bind chain (`HolonAST`). No
Result wrap.

For pairs, the substrate `Bigram` macro applies `Sequential` to
window-2 (inserting Permute). Archive uses plain `Bind`. So I
inline a manual map-window-2-bind:

```scheme
((pairs :Vec<HolonAST>)
  (:wat::core::map
    (:wat::std::list::window trigrams 2)
    (:wat::core::lambda ((w :wat::holon::Holons) -> :wat::holon::HolonAST)
      (:wat::holon::Bind
        (:trading::vocab::exit::phase::unwrap-first w)
        (:trading::vocab::exit::phase::unwrap-second w)))))
```

Where `unwrap-first` / `unwrap-second` match-extract from
`Option<HolonAST>` (Vec accessors return Option per arc 047).
The unwrap is safe because window-2 produces only 2-element vecs.

---

## Budget truncation

Two truncation steps per archive:

1. **records → last (budget + 3) = 103**: drop records older
   than the last 103.
2. **pairs → last budget = 100**: drop pairs older than the
   last 100.

`drop` is a substrate primitive (arc-019 confirmed); takes
`Vec<T> × i64` and returns a Vec without the first n elements.
Combined with `length` for the conditional check.

`budget = 100` derives from `sqrt(d=10000)` per Kanerva; for a
substrate-default d=4096 the budget would differ, but archive
hard-codes 100. Lab inherits the constant; future explore-arc
could parameterize on dim-router.

---

## Substrate primitives consumed (all present)

- `:wat::core::range` — index iteration
- `:wat::core::map` — over indices and over windows
- `:wat::core::take` / `drop` — truncation
- `:wat::core::length` — size checks
- `:wat::core::find-last-index` (arc 047) — same-label lookup
- `:wat::core::get` — Vec index access (returns Option)
- `:wat::core::match` on user enums (arc 048) — same-label?
  predicate + label dispatch
- `:wat::std::list::window` — sliding windows
- `:wat::holon::Bundle` / `Sequential` / `Permute` / `Bind` /
  `Atom` / `Thermometer`
- `:wat::core::i64::to-f64`, `f64::abs`, `f64::-`, `f64::/`,
  `f64::*`, comparisons

No new substrate primitives surfaced during sketch. The "natural
form" worked end-to-end with arc 047 + arc 048's surface plus
the existing list/holon stdlib.

---

## Why this is not in the same file as arc 019

Arc 019 already shipped phase.wat with current + scalar. Arc
020 EXTENDS that file with the rhythm function. Same file,
additional content; no separation of concern needed at the file
level.

---

## Non-goals

- **Parameterize budget on dim-router**. Constant 100 matches
  archive; future explore-arc can refine.
- **Cross-record Sequential collisions**. Sequential's Permute
  is deterministic (positional), so identical records at
  different indices don't collide. No special handling.
- **Capacity-exceeded handling**. Phase bundles are small (≤11
  facts); BundleResult Ok is the live arm. Err sentinel is
  unreachable but match-required.
- **Non-empty-but-too-short history**. < 4 records returns an
  empty Bundle; ≥ 4 builds the rhythm. Window-3 over 4 records
  gives 2 trigrams, window-2 of 2 trigrams gives 1 pair. Edge
  case but valid.
