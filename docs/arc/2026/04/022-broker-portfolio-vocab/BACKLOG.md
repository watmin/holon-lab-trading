# Lab arc 022 — broker/portfolio vocab — BACKLOG

**Shape:** four slices. Type, vocab module, tests, INSCRIPTION
+ doc sweep.

---

## Slice 1 — type module

**Status: ready.**

Create `wat/types/portfolio.wat`:

- `(:wat::core::struct :trading::types::PortfolioSnapshot ...)` —
  5 f64 fields (avg-age, avg-tp, avg-unrealized, grace-rate,
  active-count).
- `(:wat::core::typealias :trading::types::PortfolioSnapshots
   :Vec<trading::types::PortfolioSnapshot>)` — plural alias.

Wire into `wat/main.wat` after pivot.wat (Phase 1 types group),
before the Phase 3 encoding helpers.

## Slice 2 — vocab module

**Status: ready** (slice 1 unblocks; both shippable in one
commit).

Create `wat/vocab/broker/portfolio.wat`:

- One define: `:trading::vocab::broker::portfolio::portfolio-rhythm-asts`.
- Body: extract per-field Vec<f64> via `:wat::core::map` over
  snapshots; call `:trading::encoding::rhythm::indicator-rhythm`
  5 times in let* with `:wat::core::try` unwrapping each
  BundleResult to HolonAST; collect into `(:wat::core::vec
  :wat::holon::HolonAST h0 h1 h2 h3 h4)`; wrap in `Ok`.
- Return type: `:Result<Vec<wat::holon::HolonAST>,wat::holon::CapacityExceeded>`.

Wire into `wat/main.wat` in the Phase 2 vocab block, after
`vocab/exit/regime.wat` from arc 021. Add `;; arc 022 — broker/portfolio`
chronology comment.

## Slice 3 — tests

**Status: obvious in shape** (once slices 1 – 2 land).

Create `wat-tests/vocab/broker/portfolio.wat`. Four tests:

1. **count** — Result Ok arm holds a `Vec<HolonAST>` of length
   5.
2. **deterministic** — same snapshot window through two calls
   produces holon[0] coincident? at d=10000.
3. **different windows differ** — two distinct snapshot
   windows produce holon[0] non-coincident.
4. **few snapshots fallback** — window of 2 snapshots produces
   5 rhythms, each with the empty-bundle Bind shape per
   indicator-rhythm's < 4 fallback. Verify the Result is Ok
   and length 5 (not Err — indicator-rhythm returns Ok with
   the empty-bundle sentinel for short windows).

`make-deftest` preamble defines `:test::fresh-snapshot` (5
f64 args → `PortfolioSnapshot`).

**Sub-fogs:**
- (none.)

## Slice 4 — INSCRIPTION + doc sweep

**Status: obvious in shape** (once slices 1 – 3 land).

- `docs/arc/2026/04/022-broker-portfolio-vocab/INSCRIPTION.md`.
  Records: first broker sub-tree vocab; PortfolioSnapshot
  type ships alongside (Phase 1.8 retroactive); plural-typealias
  per arc 020; Result-typed return signature per arc 032.
- `docs/rewrite-backlog.md` — Phase 1 gains "1.8 shipped" row
  for PortfolioSnapshot; Phase 2 gains "2.19 shipped" row for
  the vocab. Original "broker/portfolio BLOCKED" note retired
  with reason.
- `docs/proposals/2026/04/058-ast-algebra-surface/FOUNDATION-CHANGELOG.md`
  — row documenting arc 022.
- Task #47 marked completed.
- Lab repo commit + push.
