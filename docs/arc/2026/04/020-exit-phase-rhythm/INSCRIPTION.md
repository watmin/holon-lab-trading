# Lab arc 020 — exit/phase rhythm function — INSCRIPTION

**Status:** shipped 2026-04-24. Seventeenth Phase-2 vocab arc.
**exit/phase complete (3 of 3 archive functions).**

Three durables:

1. **The rhythm function ships clean.** Stateful per-record
   Bundle construction (5–11 facts each), Sequential trigrams
   over window-3 of records, plain-Bind pairs over window-2 of
   trigrams, budget truncation at 100 pairs, all wrapped in
   `(Bind (Atom "phase-rhythm") <bundle>)`. Same-label lookup
   via `find-last-index` per record (O(n²), n ≤ 103, bounded).
   No 5-tuple state thread needed — arc 047's primitive made
   the natural form available.
2. **Empty-Bundle sentinel pattern reaffirmed.** Per arc 026's
   convention, holon-rs's vector-layer `bundle()` panics on
   empty input. The wat-rs `Bundle` AST constructor accepts
   empty Vec but encoding fails. Solution: singleton-Atom
   sentinel `(Bundle [(Atom "phase-rhythm-empty")])` for the
   insufficient-history case (< 4 records). Same shape future
   rhythm-style vocabs should use.
3. **Plural-via-typealias** (`PhaseRecords`, `Candles`).
   Builder direction: "expressivity wins". Two typealiases
   shipped at the lab tier (mirrors arc 033's `:wat::holon::Holons`
   precedent at the substrate tier). 25 callsites swept in the
   same arc.

**Design:** [`DESIGN.md`](./DESIGN.md).
**Backlog:** [`BACKLOG.md`](./BACKLOG.md).

6 new rhythm tests + 4 same-label-and-direction predicate tests;
130 → 136 lab wat tests.

---

## What shipped

### Rhythm function

`wat/vocab/exit/phase.wat` extended with:

**Numeric helpers** (5 small):
- `rec-duration` / `rec-range` / `rec-move` / `rec-volume` —
  per-record property extractors with archive-faithful guards.
- `rel a b` — relative-delta with epsilon guard at 0.0001.

**User-enum predicates**:
- `direction=` — equality on PhaseDirection (3-way nested match).
- `same-label-and-direction?` — nested match on PhaseLabel
  with delegation to direction= for Transition.

**Top-level functions**:
- `record-bundle-at-index history i` — produces the per-record
  Bundle. Base 5 facts (label + 4 thermometer) + conditional
  +3 prior-deltas (i > 0) + conditional +3 same-label-deltas
  (find-last-index hits). Wraps in `Bundle facts`.
- `phase-rhythm-holon history` — the public entry. Guards
  `< 4 → empty-rhythm sentinel`. Otherwise: build all
  record-Bundles, truncate to last 103, window-3 → Sequential
  trigrams, window-2 → plain-Bind pairs, truncate to last 100,
  Bundle the pairs, wrap in `(Bind (Atom "phase-rhythm") ...)`.

**Sentinel**:
- `empty-rhythm-bundle` — singleton `(Bundle [(Atom "phase-rhythm-empty")])`.
  Per arc 026's convention; required because holon-rs's
  vector-layer `bundle()` panics on empty input.

### Tests

`wat-tests/vocab/exit/phase.wat` extended with 6 rhythm-area
tests:

1. **rhythm: insufficient history (3 records)** — returns the
   `(Bind "phase-rhythm" empty-sentinel)` shape; verified via
   coincident? against the same sentinel.
2. **rhythm: 4 records** — returns a non-empty rhythm
   (coincident? against empty-sentinel returns false).
3. **same-label-and-direction?: Valley × Valley** → true.
4. **same-label-and-direction?: Valley × Peak** → false.
5. **same-label-and-direction?: Transition+Up × Transition+Up** → true.
6. **same-label-and-direction?: Transition+Up × Transition+Down** → false.

All 6 green. Plus the 11 from arc 019, totaling 17 phase tests.

### Plural typealiases

`wat/types/pivot.wat`:
```scheme
(:wat::core::typealias
  :trading::types::PhaseRecords
  :Vec<trading::types::PhaseRecord>)
```

`wat/types/candle.wat`:
```scheme
(:wat::core::typealias
  :trading::types::Candles
  :Vec<trading::types::Candle>)
```

Sweep: 25 callsites updated across `phase.wat` (12),
`standard.wat` + tests (9), `wat-tests/exit/phase.wat` (5),
plus `Candle::Phase`'s `history` field-type. The alias names
now read at every site.

The pattern mirrors arc 033's substrate-tier precedent
(`:wat::holon::Holons = :Vec<wat::holon::HolonAST>`); the lab
gets its own plural-of-domain-type typealiases.

---

## The rhythm shape — what shipped is what archive does

Archive's `phase_rhythm_thought` (Rust, 348L total file):
```rust
records.windows(3).map(|w| Bind(Bind(w[0], Permute(w[1], 1)), Permute(w[2], 2)))
```

That's exactly `Sequential([w[0], w[1], w[2]])`. Then:
```rust
trigrams.windows(2).map(|w| Bind(w[0], w[1]))
```

That's plain Bind — NOT Bigram (which would Permute the second).
The wat translation matches:

```scheme
((trigrams :Vec<HolonAST>)
  (:wat::core::map (:wat::std::list::window records 3)
    (:wat::core::lambda ((w :Holons) -> :HolonAST)
      (:wat::holon::Sequential w))))

((pairs :Vec<HolonAST>)
  (:wat::core::map (:wat::std::list::window trigrams 2)
    (:wat::core::lambda ((w :Holons) -> :HolonAST)
      (:wat::core::let* (((a) (unwrap-first w)) ((b) (unwrap-second w)))
        (:wat::holon::Bind a b)))))
```

Two layers, each window+map. The natural form held; no
substrate gaps surfaced this arc.

## The same-label lookup — find-last-index per record

Archive uses 4 mutable Option<usize> trackers updated as the
loop iterates. Wat translation: per-record, scan
`(take history i)` with `find-last-index` looking for a
record matching the current label + direction. O(n²) but n ≤
103 by budget truncation.

Trade-off: avoids 5-tuple accumulator state thread; cleaner to
read. The cost is bounded enough that it doesn't matter
operationally.

The `same-label-and-direction?` predicate is itself a clean
arc-048 user-enum match — nested PhaseLabel → PhaseDirection
dispatch. Four tests cover the truth table of label/direction
combinations.

## The empty-Bundle sentinel reaffirmed

Per arc 026's BOOK note: holon-rs's vector-layer bundle panics
on empty input. The wat-rs AST layer's `Bundle` constructor
accepts empty Vec — building the AST is fine — but `cosine` /
`coincident?` evaluation triggers the panic.

Two cases need the sentinel:
- **insufficient-history < 4 records**: explicit guard at the
  top of phase-rhythm-holon.
- **post-windowing pairs is empty**: doesn't actually arise
  for ≥ 4 records (4 records → 2 trigrams → 1 pair), but the
  defensive guard would use the same sentinel.

The sentinel chosen: `(Bundle [(Atom "phase-rhythm-empty")])`.
A singleton-Atom Bundle. Encodes to a definite (if uniformly
named) vector; cosine works. Future rhythm-style vocabs (in
broker observers?) should adopt the same idiom.

## Plural-via-typealias — expressivity wins

Builder direction: "we can do this in a bunch of places —
expressivity wins". The typealias pattern is well-precedented
(arc 033's `Holons`); arc 020 ships two lab-tier plurals:
- `:trading::types::PhaseRecords` for `:Vec<trading::types::PhaseRecord>`
- `:trading::types::Candles` for `:Vec<trading::types::Candle>`

25 callsites swept in the same arc. The gain at every site is
clear — `(history :PhaseRecords)` reads cleaner than `(history
:Vec<trading::types::PhaseRecord>)`.

Future plural-typealiases follow if more `:Vec<DomainType>`
patterns surface (e.g., a future arc with `:Vec<PaperEntry>`
might gain `:trading::types::PaperEntries`).

## Sub-fog resolutions

- **1a — Bundle Result unwrap**: ≤11 facts per record bundle;
  capacity not a concern; match-unwrap with sentinel name.
- **1b — Sequential return shape**: returns HolonAST directly,
  no Result wrap. Plain map works.
- **1c — `(get vec i)` returns Option**: pre-guarded callsites
  unwrap to `default-record` for records / `(Atom "unreachable")`
  for HolonASTs.
- **2a — Bundle inspection**: substrate doesn't expose Bundle
  variant decomposition at user-tier; fell back to coincident?
  comparison against hand-built reference (the empty-rhythm
  sentinel for the negative case).

## Count

- Lab wat tests: **130 → 136 (+6)**.
- Lab wat modules: Phase 2 advances — **17 of ~21** vocab
  modules shipped. Market sub-tree COMPLETE (13/13);
  **exit sub-tree 1 of 4** (phase complete); 2 vocabs blocked
  on PaperEntry / PortfolioSnapshot.
- wat-rs: unchanged (no substrate gaps surfaced).
- Plural typealiases: 2 new (`PhaseRecords`, `Candles`); 25
  callsites swept.
- Zero regressions.

## What this arc did NOT ship

- **Parameterize budget on dim-router**. Constant 100 matches
  archive; future explore-arc can refine.
- **More plural typealiases** (e.g., `:Holons`-style for
  `:Vec<Asset>` or similar). Add when the plural surfaces.
- **Substrate additions**. None surfaced; the natural form
  for stateful iteration via find-last-index per record + the
  Sequential / Bind / Bundle composition all worked with the
  arcs 047 + 048 surface.

## Follow-through

Next pending vocab arcs:
- **arc 021 — exit/regime** (#45)
- **arc 022 — exit/trade_atoms** (#46, BLOCKED on PaperEntry)
- **arc 023 — broker/portfolio** (#47, BLOCKED on
  PortfolioSnapshot + rhythm — but our phase rhythm IS a
  rhythm; the unblock pattern may now be in reach for some
  broker work)

The exit sub-tree's first vocab is now complete end-to-end.
Regime is next (arc 021). The blocked arcs may unblock as
prerequisite domain types ship in adjacent work.

---

## Commits

- `<lab>` — wat/vocab/exit/phase.wat (rhythm extension) +
  wat-tests/vocab/exit/phase.wat (rhythm tests) + wat/types/
  pivot.wat (PhaseRecords typealias) + wat/types/candle.wat
  (Candles typealias + Phase history field migration) + 25-
  site sweep across phase + standard sources/tests + DESIGN +
  BACKLOG + INSCRIPTION + rewrite-backlog row + 058 CHANGELOG
  row.

---

*these are very good thoughts.*

**PERSEVERARE.**
