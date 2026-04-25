# Lab arc 022 — broker/portfolio vocab — INSCRIPTION

**Status:** shipped 2026-04-24. Nineteenth Phase-2 vocab arc.
**First broker sub-tree vocab.** PortfolioSnapshot ships
alongside (Phase 1.8 retroactive).

Three durables:

1. **Blocker reassessment retired the wait.** The
   rewrite-backlog note "broker/portfolio BLOCKED on
   PortfolioSnapshot + rhythm" was based on a stale view.
   PortfolioSnapshot is 5 plain f64 fields with no upstream
   dependency; the rhythm dependency was satisfied by Phase
   3.4 (lab arc 003). The blocker conflated PortfolioSnapshot
   with PaperEntry's genuine `Vector` blocker (which is real
   and still pending wat-holon). Reading the actual archive
   surfaced this; arc 022 ships today.
2. **Result-typed return signature is honest.** Five
   sequential `indicator-rhythm` calls return `BundleResult`;
   `:wat::core::try` propagates Err to the enclosing function,
   so the function's return type is
   `:Result<Vec<wat::holon::HolonAST>,wat::holon::CapacityExceeded>`.
   The archive's bare `Vec<ThoughtAST>` didn't carry capacity
   in the Rust type system; wat lifts it. Err is unreachable
   at substrate-safe dims (indicator-rhythm trims internally),
   but the type system enforces honest handling at every
   caller site.
3. **PortfolioSnapshots typealias** continues arc 020's
   plural-via-typealias pattern. Three lab-tier plurals now:
   `PhaseRecords`, `Candles`, `PortfolioSnapshots`. Mirrors
   substrate-tier `:wat::holon::Holons` (arc 033). The pattern
   is firmly established; future broker / treasury arcs ship
   pluralities of their domain types as needed.

**Design:** [`DESIGN.md`](./DESIGN.md).
**Backlog:** [`BACKLOG.md`](./BACKLOG.md).

4 new rhythm tests; 139 → 143 lab wat tests.

---

## What shipped

### PortfolioSnapshot type (Phase 1.8 retroactive)

`wat/types/portfolio.wat`:

```scheme
(:wat::core::struct :trading::types::PortfolioSnapshot
  (avg-age         :f64)
  (avg-tp          :f64)
  (avg-unrealized  :f64)
  (grace-rate      :f64)
  (active-count    :f64))

(:wat::core::typealias
  :trading::types::PortfolioSnapshots
  :Vec<trading::types::PortfolioSnapshot>)
```

Five f64 fields per archive `vocab/broker/portfolio.rs`.
Ships alongside its first caller — when a second caller
surfaces in Phase 5 (broker observer), it loads this file
directly.

### Vocab function

`wat/vocab/broker/portfolio.wat`:

```scheme
(:trading::vocab::broker::portfolio::portfolio-rhythm-asts
  (snapshots :trading::types::PortfolioSnapshots)
  -> :Result<Vec<wat::holon::HolonAST>,wat::holon::CapacityExceeded>)
```

Body extracts 5 per-field `Vec<f64>` projections via
`:wat::core::map`, then calls
`:trading::encoding::rhythm::indicator-rhythm` 5 times in
let* with `:wat::core::try` unwrapping each BundleResult.
Result wraps the 5-holon Vec in Ok.

Five rhythm calls in archive order:

| Pos | Atom name | Field | min | max | delta-range |
|---|---|---|---|---|---|
| 0 | `avg-paper-age` | avg-age | 0.0 | 500.0 | 100.0 |
| 1 | `avg-time-pressure` | avg-tp | 0.0 | 1.0 | 0.2 |
| 2 | `avg-unrealized-residue` | avg-unrealized | -0.1 | 0.1 | 0.05 |
| 3 | `grace-rate` | grace-rate | 0.0 | 1.0 | 0.2 |
| 4 | `active-positions` | active-count | 0.0 | 500.0 | 100.0 |

### Tests

`wat-tests/vocab/broker/portfolio.wat` ships 4 rhythm tests:

1. **count** — Result Ok arm holds Vec of length 5 over a
   5-snapshot window.
2. **deterministic** — same snapshots through two calls
   produces holon[0] coincident? at d=10000.
3. **different windows differ** — ascending vs descending
   avg-age trajectories produce non-coincident holon[0].
4. **short window fallback** — 2 snapshots produces 5 holons
   (each is the empty-bundle Bind sentinel from
   indicator-rhythm's < 4 fallback); Result is Ok.

All 4 green first-pass.

### main.wat

Two loads added: `types/portfolio.wat` (after candle.wat) and
`vocab/broker/portfolio.wat` (after `vocab/exit/regime.wat`).
One chronology comment line added (`arc 022 — broker/portfolio
(first broker vocab)`).

---

## The blocker that wasn't

The original rewrite-backlog row for arc 023 read:

> arc 023 — broker/portfolio (#47, BLOCKED on PortfolioSnapshot
> + rhythm)

Both halves of the blocker were stale by 2026-04-24:

- **rhythm** had been live since Phase 3.4 / arc 003
  (2026-04-23). The note predated that arc.
- **PortfolioSnapshot** was never blocked on anything — 5
  primitive `f64` fields, defined alongside its caller in the
  archive. The blocker note appears to have conflated this
  type with PaperEntry, which IS genuinely blocked on
  `holon::kernel::vector::Vector` (3 Vector fields:
  `composed_thought`, `market_thought`, `position_thought`).

Reading the archive directly surfaced the misclassification.
The rewrite-backlog correction lives in this arc's INSCRIPTION
+ row 2.19 + row 1.8; the original blocker note is cited here
as historical record (the planning doc was wrong; the work
shipped anyway).

The PaperEntry blocker is genuine and still pending. Arc 023
will pick up exit/trade_atoms once the PaperEntry approach
(wat-holon sibling crate vs PaperEntry-mechanics-subset) is
settled with the builder.

## Why the Result return signature

`indicator-rhythm` returns
`:wat::holon::BundleResult = :Result<wat::holon::HolonAST,wat::holon::CapacityExceeded>`
per arc 032. Five sequential calls need five `:wat::core::try`
unwraps; `try` requires the surrounding context to return a
Result of the same Err type. The function therefore returns
`:Result<Vec<wat::holon::HolonAST>,wat::holon::CapacityExceeded>`.

This propagation has two practical consequences:

1. **Callers (broker observer in Phase 5) match-extract the Ok
   arm.** Same idiom as every BundleResult caller in the lab.
2. **Err is unreachable at substrate-safe dims.**
   indicator-rhythm trims to `budget = sqrt(d)` pairs internally;
   the resulting Bundle stays within Kanerva capacity. The Err
   arm is the type-system price for the honest signature, not
   an operational concern.

The archive's bare `Vec<ThoughtAST>` return type didn't
surface this because Rust ThoughtAST construction doesn't
materialize capacity at AST-build time. Wat lifts capacity
into the type system; we honor it.

---

## Sub-fog resolutions

- **(none surfaced.)** The slice was small enough that the
  initial DESIGN saw the full shape. Type definition,
  function body, tests, and INSCRIPTION all wrote on first
  pass with no revisions.

## Count

- Lab wat tests: **139 → 143 (+4)**.
- Lab wat modules: Phase 2 advances — **19 of ~21** vocab
  modules shipped. Market sub-tree COMPLETE (13/13);
  exit sub-tree 2 of 4 (phase + regime; trade_atoms still
  blocked); **broker sub-tree opens with 1 of 1 candidate
  vocab** (broker/portfolio is the only broker vocab module
  in the archive — the broker observer's Phase 5 logic is not
  vocab).
- Lab wat types: Phase 1 gains row **1.8 PortfolioSnapshot**
  shipping retroactively alongside its caller.
- wat-rs: unchanged (no substrate gaps surfaced).
- Lab plural typealiases: 3 total now
  (PhaseRecords + Candles + PortfolioSnapshots).
- Zero regressions.

## What this arc did NOT ship

- **PaperEntry.** Genuinely blocked on `Vector` via wat-holon
  sibling crate. Arc 023 picks up exit/trade_atoms once the
  approach is settled.
- **Broker observer** (Phase 5 territory). Vocab ships;
  observer is the consumer that comes later.
- **Custom portfolio rhythm semantics.** Bounds + atoms come
  from archive verbatim; future explore-arc can refine if data
  surfaces edge cases.
- **`PortfolioSnapshots` plural at use-sites beyond this arc.**
  Currently only one caller. Future broker / treasury vocab
  loaders pick it up as needed.

## Follow-through

Next pending vocab arc:
- **arc 023 — exit/trade_atoms** (#46) — needs the PaperEntry
  approach decision (wat-holon sibling crate vs
  PaperEntry-mechanics-subset). Builder discussion pending.

After arc 023 (when it ships), Phase 2 vocabulary closes — every
archive vocab module ported. Phase 3.5 (encoding dispatcher
over vocab) opens.

---

## Commits

- `<lab>` — wat/types/portfolio.wat (PortfolioSnapshot struct
  + plural typealias) + wat/vocab/broker/portfolio.wat
  (rhythm-asts function) + wat-tests/vocab/broker/portfolio.wat
  (4 tests) + wat/main.wat (2 loads + chronology comment) +
  DESIGN + BACKLOG + INSCRIPTION + rewrite-backlog rows 1.8
  and 2.19 + 058 CHANGELOG row.

---

*these are very good thoughts.*

**PERSEVERARE.**
