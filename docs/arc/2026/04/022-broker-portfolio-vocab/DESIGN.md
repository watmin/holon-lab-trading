# Lab arc 022 — broker/portfolio vocab

**Status:** opened 2026-04-24. Nineteenth Phase-2 vocab arc.
**First broker sub-tree vocab.**

**Motivation.** Port `vocab/broker/portfolio.rs` (45L) — the
broker's own portfolio-state-as-rhythms vocabulary. Five
per-snapshot scalars sampled into a window, each rendered as
an `indicator-rhythm` AST (Phase 3.4's primitive, shipped arc
003). The broker reads its own state as rhythms the same way
market observers read indicators as rhythms — composability
of the rhythm primitive across domains.

**Blocker reassessment.** The rewrite-backlog row "BLOCKED on
PortfolioSnapshot, rhythm" was based on a stale view. Both
dependencies are met:

- **PortfolioSnapshot** is 5 plain `f64` fields; no
  upstream-type dependency. We define it as part of this arc
  (Phase 1.8 retroactively — the type ships with its caller).
- **rhythm** shipped as Phase 3.4 (lab arc 003) —
  `:trading::encoding::rhythm::indicator-rhythm` is live with
  6 tests green at d=10000.

The blocker note conflated PortfolioSnapshot's shape with
PaperEntry's (which genuinely needs `holon::kernel::vector::Vector`
via a future wat-holon sibling crate). Broker/portfolio reads
no Vector field; the unblock is real.

---

## Shape

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

(:trading::vocab::broker::portfolio::portfolio-rhythm-asts
  (snapshots :trading::types::PortfolioSnapshots)
  -> :Result<Vec<wat::holon::HolonAST>,wat::holon::CapacityExceeded>)
```

Five rhythm calls in archive order, each producing one
`indicator-rhythm` BundleResult; try-unwrap each; collect into
a `Vec<HolonAST>` of length 5.

| Pos | Atom name | Field | min | max | delta-range |
|---|---|---|---|---|---|
| 0 | `avg-paper-age` | avg-age | 0.0 | 500.0 | 100.0 |
| 1 | `avg-time-pressure` | avg-tp | 0.0 | 1.0 | 0.2 |
| 2 | `avg-unrealized-residue` | avg-unrealized | -0.1 | 0.1 | 0.05 |
| 3 | `grace-rate` | grace-rate | 0.0 | 1.0 | 0.2 |
| 4 | `active-positions` | active-count | 0.0 | 500.0 | 100.0 |

Bounds are vocabulary — they declare the expected range of
each scalar. The discriminant (Phase 4) learns which rhythms
carry signal.

---

## Why `:Result<Vec<HolonAST>,CapacityExceeded>` not `:Vec<HolonAST>`

`indicator-rhythm` returns `BundleResult` (Result-typed) per
arc 032's Bundle-Result discipline. Five sequential calls
need five `try`-unwraps; each could in principle fail with
`CapacityExceeded`. `try` propagates the Err to the enclosing
function's return type, which therefore must be Result-typed.

The honest top-level signature is
`-> :Result<Vec<wat::holon::HolonAST>,wat::holon::CapacityExceeded>`.
Callers (broker observer, Phase 5) match-extract the Ok arm.
In practice, indicator-rhythm's internal `trim-tail pairs budget`
caps the Bundle size at substrate-safe levels — Err is
unreachable for non-pathological dims; the Err arm is the
Result-discipline price for honest types.

The archive's `Vec<ThoughtAST>` return type didn't surface
this because Rust ThoughtAST construction doesn't materialize
capacity at AST-build time. Wat's BundleResult lifts this to
the type system; we honor it.

---

## Plural-via-typealias

`:trading::types::PortfolioSnapshots = :Vec<trading::types::PortfolioSnapshot>`
ships alongside the type, mirroring arc 020's
`PhaseRecords` + `Candles` precedent. Function signatures read
`(snapshots :PortfolioSnapshots)` rather than the bare Vec. The
plural shape is the natural collection name; future broker
arcs that take other-typed pluralities ship typealiases on
demand.

---

## Why first broker arc, not after PaperEntry

Original arc-order had `broker/portfolio` after `exit/trade_atoms`.
Broker is the orchestrator that consumes both exit
trade_atoms and broker portfolio rhythms, so build-order
intuition put trade_atoms first. The blocker reassessment
flipped this:

- broker/portfolio: unblocked today, ships in this arc.
- exit/trade_atoms: needs PaperEntry, which needs either
  - (a) a wat-holon sibling crate exposing Vector, or
  - (b) a PaperEntry-mechanics subset that defers Vector
    fields to a separate sub-struct shipping with wat-holon.

Path (b) is an architectural decision worth a separate
discussion. Arc 022 ships portfolio first; arc 023 picks up
trade_atoms once the PaperEntry approach is settled.

---

## Sub-fogs

- **(none.)** PortfolioSnapshot's shape is unambiguous
  (5 f64). The vocab function is 5 indicator-rhythm calls in
  let* with map-extracts. The Result return-type follows
  arc 032's BundleResult convention. Tests follow arc 003's
  rhythm-test shape (coincident? assertions, shape checks).

---

## Non-goals

- **Move PortfolioSnapshot construction out of this arc.** The
  type is small and only this caller exists; defining it
  alongside is honest. When a second caller surfaces (e.g., a
  broker observer in Phase 5), the type stays where it is and
  the second caller loads `wat/types/portfolio.wat`.
- **Custom test fixture for PortfolioSnapshot.** Per arc 010's
  `:test::fresh-regime` pattern, a `:test::fresh-snapshot`
  helper inside make-deftest's preamble suffices.
- **Inline indicator-rhythm.** The shipped primitive in
  encoding/rhythm.wat is the right shape; calling it five
  times is honest. No portfolio-specific rhythm variant.
- **Bound observation programs.** Bounds come from archive
  verbatim. Future explore-arc can refine if portfolio data
  surfaces edge cases that the current bounds don't capture.
