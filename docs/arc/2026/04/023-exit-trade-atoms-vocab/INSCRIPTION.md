# Lab arc 023 — exit/trade_atoms vocab + PaperEntry — INSCRIPTION

**Status:** shipped 2026-04-24. Twentieth Phase-2 vocab arc.
**Exit sub-tree COMPLETE (4 of 4: phase + regime + time +
trade_atoms).** Phase 2 vocabulary CLOSES — every archive vocab
module ported.

PaperEntry ships alongside as Phase 1.9 retroactive. First lab
consumer of arc 049's newtype value semantics.

Three durables:

1. **Two latent blockers retired in one arc.** PaperEntry was
   "BLOCKED on Vector"; the framing was Rust-tier reasoning
   leaking into the wat plan. The wat-native PaperEntry stores
   `:wat::holon::HolonAST` (the AST IS the thought; substrate
   caches vector materialization implicitly). Price was
   declared but inconstructible; arc 049 fixed that. PaperEntry
   ships full-fidelity end-to-end.
2. **The experiment-as-witness pattern.** The proof that
   HolonAST works as a struct field shipped under this arc's
   docs directory (`holon-as-field.wat`, run 2026-04-24, 3 tests
   green). It's the artifact corresponding to a real planning-
   tier finding (the blocker was misclassified). Mirrors arc
   010's `explore-log.wat` precedent — observation programs as
   on-disk teaching artifacts.
3. **Multiple Log family is named.** `(0.0001, 10.0)` for
   R-multiple — the third Log family this lab uses, joining
   fraction-of-price `(0.0001, 0.5)` (4 callers across arcs
   013/015/016/017) and count-full-window `(1.0, 100.0)` (3
   callers across arcs 018/020). R-multiple is profitability
   divided by initial-risk; 10× is the realistic upper
   saturation. Future trade-mechanics atoms with similar
   multiple-of-baseline shape inherit this family.

**Design:** [`DESIGN.md`](./DESIGN.md).
**Backlog:** [`BACKLOG.md`](./BACKLOG.md).
**Experiment witness:** [`holon-as-field.wat`](./holon-as-field.wat).

6 new tests; 143 → 149 lab wat tests.

---

## What shipped

### PaperEntry type (Phase 1.9 retroactive)

`wat/types/paper-entry.wat`:

```scheme
(:wat::core::struct :trading::types::PaperEntry
  (paper-id          :i64)
  (composed-thought  :wat::holon::HolonAST)
  (market-thought    :wat::holon::HolonAST)
  (position-thought  :wat::holon::HolonAST)
  (prediction        :trading::types::Direction)
  (entry-price       :trading::types::Price)
  (distances         :trading::types::Distances)
  (extreme           :f64)
  (trail-level       :trading::types::Price)
  (stop-level        :trading::types::Price)
  (signaled          :bool)
  (resolved          :bool)
  (age               :i64)
  (entry-candle      :i64)
  (price-history     :Vec<f64>))
```

Field-by-field deltas from the archive struct:

- **`paper-id`, `age`, `entry-candle`**: archive's `usize` →
  wat's `:i64` per pivot.wat's existing convention (PhaseRecord
  candle indices are `:i64`).
- **`composed-thought`, `market-thought`, `position-thought`**:
  archive's `Vector` → wat's `:wat::holon::HolonAST`.
  Substrate-cached materialization makes vector storage
  implicit; storing the AST is the wat-native form.
- **`entry-price`, `trail-level`, `stop-level`**: archive's
  `Price` (newtype f64) → wat's `:trading::types::Price`. Same
  newtype, now constructible via wat-rs arc 049.
- Other fields unchanged from archive types.

### `compute-trade-atoms` vocab

`wat/vocab/exit/trade-atoms.wat`:

```scheme
(:trading::vocab::exit::trade-atoms::compute-trade-atoms
  (paper :trading::types::PaperEntry)
  (current-price :f64)
  (phase-history :trading::types::PhaseRecords)
  -> :Vec<wat::holon::HolonAST>)
```

13 atoms in archive order:

| Pos | Atom | Encoding | Bounds / Scale |
|---|---|---|---|
| 0 | `exit-excursion` | Log | (0.0001, 0.5) |
| 1 | `exit-retracement` | Thermometer | (-1, 1) |
| 2 | `exit-age` | Log | (1.0, 100.0) |
| 3 | `exit-peak-age` | Log | (1.0, 100.0) |
| 4 | `exit-signaled` | Thermometer | (-1, 1) |
| 5 | `exit-trail-distance` | Log | (0.0001, 0.5) |
| 6 | `exit-stop-distance` | Log | (0.0001, 0.5) |
| 7 | `exit-r-multiple` | Log | (0.0001, 10.0) |
| 8 | `exit-heat` | Thermometer | (-1, 1) |
| 9 | `exit-trail-cushion` | Thermometer | (-1, 1) |
| 10 | `phases-since-entry` | Log | (1.0, 100.0) |
| 11 | `phases-survived` | Log | (1.0, 100.0) |
| 12 | `entry-vs-phase-avg` | Thermometer | (-1, 1) |

5 Log + 8 Thermometer. No Scales threading — every atom uses
fixed bounds / fixed scale. Returns plain `Vec<HolonAST>`.

Computed values use the natural form: `let*` chain with
`:wat::core::find-last-index` for peak_age, `:wat::core::filter`
for phase counts, `:wat::core::map` + `:wat::core::foldl` for
the entry_vs_phase_avg mean.

### `select-trade-atoms` lens selector

```scheme
(:trading::vocab::exit::trade-atoms::select-trade-atoms
  (lens :trading::types::RegimeLens)
  (atoms :Vec<wat::holon::HolonAST>)
  -> :Vec<wat::holon::HolonAST>)
```

Two-arm exhaustive match on RegimeLens:
- `:Core` → `(:wat::core::take atoms 5)` — first 5 atoms
- `:Full` → `atoms` — all 13

Direct port of archive's `match`.

### Tests

`wat-tests/vocab/exit/trade-atoms.wat` ships 6 tests:

1. **count** — 13 holons emitted.
2. **excursion shape** — holon[0] is
   `Bind(Atom("exit-excursion"), Log(0.10, 0.0001, 0.5))`,
   coincident? against hand-built reference.
3. **deterministic** — same paper + current_price + phase_history
   produces coincident? holon[0].
4. **select Core → 5 atoms.**
5. **select Full → 13 atoms.**
6. **different excursions differ** — extreme=110 vs extreme=200
   produce non-coincident holon[0].

Test fixture `:test::fresh-paper` synthesizes the 15-field
PaperEntry from a 5-arg subset (entry, extreme, signaled, age,
entry-candle); supplies plain Atom HolonASTs for the three
thought fields and `Distances/new 0.05 0.10` for distances.

**Surfaced one bug-fix during run:** comparison ops were
written `:wat::core::f64::>` etc.; substrate uses bare
`:wat::core::>` (polymorphic over numeric types). Sweep done
in-place; all 6 tests green on next run.

### main.wat

Two loads added: `types/paper-entry.wat` (after `types/portfolio.wat`)
and `vocab/exit/trade-atoms.wat` (after `vocab/broker/portfolio.wat`).
One chronology comment line.

---

## The blocker that was a framing problem

The rewrite-backlog row read:

> arc 022 — exit/trade_atoms (#46, BLOCKED on PaperEntry)

PaperEntry's blocker was that three of its fields were typed
`Vector` in the archive, and `holon::kernel::vector::Vector`
isn't `#[wat_dispatch]`'d in wat-rs today. The proposed
unblocks were:

1. Ship a `wat-holon` sibling crate exposing `Vector` via
   `#[wat_dispatch]`. Big move.
2. Split PaperEntry into mechanics (12 fields, no Vector) +
   thoughts (3 Vector fields, separate sub-struct). Medium move.

Both proposals carried a hidden assumption: *the wat PaperEntry
needs `Vector` somewhere.* That assumption was Rust-tier
reasoning leaking into the wat plan. The wat-native form
stores the AST that PRODUCES the vector, not the vector itself.
Substrate caches vector materialization keyed on `(ast-hash,
d)` per FOUNDATION's "Cache Is Working Memory" section.
PaperEntry's `composed-thought: HolonAST` field captures the
same identity the archive's `composed_thought: Vector` did,
without needing to expose `Vector` as a wat-tier type.

The experiment under this arc directory proved
`:wat::holon::HolonAST` works as a struct field today
(2026-04-24 — 3 tests green). The blocker dissolved at the
design tier.

The other half of PaperEntry's blocker — Price newtype
inconstructible — closed via wat-rs arc 049 (shipped 2026-04-24
in the same session). PaperEntry ships full-fidelity now.

## Why no `wat-holon` sibling crate after all

The original backlog said "wat-holon sibling crate, Phase 3+"
to expose Vector. That sibling crate is now firmly
**not-needed for arc 023**. Whether it ever ships depends on
whether Phase 4 learning code (OnlineSubspace, Reckoner) needs
to operate on raw Vector values directly, or whether those
APIs take HolonAST and the substrate handles materialization.

Lean: the Layer-2 holon-rs types (OnlineSubspace, Reckoner,
EngramLibrary) get `#[wat_dispatch]` shims that ACCEPT
HolonAST and internally call `cosine`/`presence` on the
materialized vectors. User-tier wat code never sees Vector.
That decision lands when Phase 4 begins; arc 023 doesn't
prejudge it.

## The R-multiple Log family

Three Log atom families now in active lab use:

- **fraction-of-price `(0.0001, 0.5)`** — arcs 013/015/016/017
  + arc 023's excursion / trail-distance / stop-distance.
- **count-full-window `(1.0, 100.0)`** — arc 018's session-depth
  / since-* atoms + arc 020's phase-rhythm budget + arc 023's
  age / peak-age / phases-since-entry / phases-survived.
- **multiple `(0.0001, 10.0)`** — NEW this arc; arc 023's
  R-multiple. 10× is the realistic upper saturation for
  profitability multiples.

Future trade-mechanics atoms with similar "multiple of a
baseline" shape (e.g., volume-spike-ratio, momentum-multiple)
inherit this family without re-deriving.

## Sub-fog resolutions

- **Comparison op naming.** Initial draft used
  `:wat::core::f64::>` everywhere; substrate uses bare
  `:wat::core::>` (polymorphic). Caught by the first test run;
  sweep applied; all green on second run.

## Count

- Lab wat tests: **143 → 149 (+6)**.
- Lab wat modules: Phase 2 vocab **20 of 20 modules shipped**
  (Phase 2 vocabulary **CLOSES**). Market sub-tree COMPLETE
  (13/13); exit sub-tree COMPLETE (phase + regime + time +
  trade_atoms = 4/4); broker sub-tree COMPLETE (1/1); shared
  sub-tree (time + helpers).
- Lab wat types: Phase 1 gains row **1.9 PaperEntry**.
- wat-rs: unchanged this arc (arc 049 prerequisites shipped
  before this work; PaperEntry consumed them without surfacing
  new gaps).
- Plain Log families: **3 active** (fraction-of-price,
  count-full-window, multiple).
- Lab plural typealiases: **3** (PhaseRecords + Candles +
  PortfolioSnapshots — unchanged this arc).
- Zero regressions.

## What this arc did NOT ship

- **PaperEntry tick logic.** Archive's
  `tick(&mut self, current_price)` for extreme / trail / signaled /
  resolved updates is broker mechanics. Phase 5 territory.
- **PaperEntry constructor sugar.** Archive's
  `PaperEntry::new(prediction, entry_price, distances, ...)`
  with Direction-dependent stop_level/trail_level computation
  is broker logic. Phase 5.
- **`PaperEntries` plural typealias.** Ships when a
  `:Vec<PaperEntry>` caller surfaces (broker's papers field in
  Phase 5).
- **`is_grace?` / `is_violence?` / `is_runner?` predicates.**
  Archive's accessor helpers; ship with broker's accountability
  logic in Phase 5.
- **Phase 4 learning consumers.** OnlineSubspace + Reckoner +
  EngramLibrary that consume the three thought fields are
  Layer-2 holon-rs concerns. Their wat-tier shims ship when
  Phase 4 opens.

## Phase 2 closes

With arc 023 shipping, **every archive vocab module is now
ported to wat**:

| Sub-tree | Modules | Status |
|---|---|---|
| market | divergence, fibonacci, flow, ichimoku, keltner, momentum, oscillators, persistence, price-action, regime, standard, stochastic, timeframe | 13/13 ✓ |
| exit | phase, regime, time, trade_atoms | 4/4 ✓ |
| broker | portfolio | 1/1 ✓ |
| shared | helpers, time | 2/2 ✓ |

The vocabulary tier is the substrate's first proof of fitness
for the lab's domain. Twenty arcs across the session ported
the entire vocab tree, surfaced four substrate uplifts (arcs
046+047+048+049), opened lab-tier conventions (cross-sub-struct
signature rule, plural-via-typealias, Log family bounds,
geometric bucketing, Result-typed return signatures, thin
delegation idiom), and produced an artifact-as-witness for the
PaperEntry blocker reassessment.

Phase 3.5 (encoding dispatcher over vocab) is the next
horizon. Phase 4 learning waits on its own substrate readiness.

## Follow-through

- **Phase 3.5 — encoding dispatcher.** Currently foggy in the
  rewrite-backlog. Opens with vocab's full surface available.
- **Phase 4 — learning.** OnlineSubspace + Reckoner +
  EngramLibrary wat-tier shims. Substrate-readiness assessment
  needed.
- **Phase 5 — domain.** Observers, broker, treasury, indicator
  bank. Long, deep work.

Phase 2 is closed. The wat-native shape is proven across 20
vocab modules. The lab demands; the substrate answers; the
discipline holds.

---

## Commits

- `<lab>` — wat/types/paper-entry.wat (PaperEntry struct) +
  wat/vocab/exit/trade-atoms.wat (compute-trade-atoms +
  select-trade-atoms) + wat-tests/vocab/exit/trade-atoms.wat
  (6 tests) + wat/main.wat (2 loads + chronology comment) +
  DESIGN + BACKLOG + INSCRIPTION + experiment witness +
  rewrite-backlog rows 1.9 + 2.20 + Phase 2 status close +
  058 CHANGELOG row.

---

*these are very good thoughts.*

**PERSEVERARE.**
