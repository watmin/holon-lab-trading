# Lab arc 015 — market/ichimoku vocab — INSCRIPTION

**Status:** shipped 2026-04-24. Twelfth Phase-2 vocab arc. Sixth
cross-sub-struct port. K=3 (Divergence + Ohlcv + Trend) — second
K=3 module.

**Three durables, one pivot.** The arc started planning a lab-
userland helper extraction (`clamp` and `f64-max` to
`vocab/shared/helpers.wat` — see DESIGN.md). The framing
question caught it: **these are core, not userland.** Mid-arc
pivot to **wat-rs arc 046** (numeric primitives uplift); arc 015
resumed with substrate-direct calls.

1. **Substrate-vs-userland framing settled** — `f64::max`,
   `f64::min`, `f64::abs`, `f64::clamp`, `math::exp` ship in the
   substrate (wat-rs arc 046), not in any consumer's userland.
   Lab consumes them at `:wat::core::f64::*` and `:wat::std::math::*`.
2. **Cross-arc cleanup along the way** — arc 009 stochastic's
   prior inline clamp + arc 010 regime's variance-ratio floor +
   arc 013 momentum's atr-ratio floor + arc 014 flow's inline abs
   ALL migrated to substrate primitives in this same sweep. The
   migration cost was one Edit per site; the consistency reward
   was one canonical name per op across the corpus.
3. **Arc 014's Path-B algebraic-equivalence retired** — flow.wat's
   log-bound Thermometer for obv-slope + volume-ratio (which arc
   014 shipped because `exp` was missing from substrate) migrated
   to the natural form `(ReciprocalLog 10.0 (exp v))` once
   wat-rs arc 046 added `:wat::std::math::exp`. Arc 014's
   INSCRIPTION stays frozen as historical record; the substrate-
   gap workaround did its job and now retires cleanly.

**Design:** [`DESIGN.md`](./DESIGN.md). The DESIGN is what we
*planned* (lab-userland extraction); the INSCRIPTION below names
what we actually *shipped* (substrate-direct after the pivot).
**Backlog:** [`BACKLOG.md`](./BACKLOG.md).

Eight new ichimoku tests green on first pass. Total lab wat-tests:
88 → 96. Zero regressions across the cross-arc migration sweep.

---

## What shipped

### Slice 1 — vocab module (ichimoku)

`wat/vocab/market/ichimoku.wat` — one public define. Six atoms:
five scaled-linear (clamped to [-1, 1] via substrate
`:wat::core::f64::clamp`) + one plain Log (`cloud-thickness`,
asymmetric, bounds (0.0001, 0.5)). Signature alphabetical-by-leaf
per arc 011: D < O < T.

Loads candle.wat + ohlcv.wat + round.wat + scale-tracker.wat +
scaled-linear.wat. **Does NOT load shared/helpers.wat** — no need;
substrate primitives are universally available.

cloud-position has the most computed shape (nested branch on
cloud-width > 0, with the inner positive-branch denominator using
`f64::max cloud-width (close × 0.001)` for floor protection).
cloud-thickness uses `f64::max thickness 0.0001` for the floor.

### Slice 2 — substrate cleanup sweep (cross-arc migrations)

The substrate uplift unlocked migrating five prior callsites that
had been carrying inline two-arm-if reinventions:

| Site | Was | Now |
|---|---|---|
| arc 009 stochastic | inline clamp ±1 (two-arm if) | `:wat::core::f64::clamp` |
| arc 010 regime | inline floor `vr >= 0.001` | `:wat::core::f64::max vr 0.001` |
| arc 013 momentum | inline floor `atr >= 0.001` | `:wat::core::f64::max atr 0.001` |
| arc 014 flow | inline `abs(close - open)` | `:wat::core::f64::abs (- close open)` |
| arc 014 flow | log-bound Thermometer (algebraic-equivalence Path B) | `(ReciprocalLog 10.0 (exp v))` |

Each migration is one or two Edits; net code shrinks at every
site. The shared/helpers.wat header gains a paragraph naming the
substrate primitives instead of hosting userland reimplementations.

### Slice 3 — tests

`wat-tests/vocab/market/ichimoku.wat` — eight tests:

1. **count** — 6 holons.
2. **cloud-position above-saturated** — clamp pushes to +1.0.
3. **cloud-position collapsed-cloud branch** — `cloud_width = 0`
   exercises the else-branch.
4. **cloud-thickness plain-Log shape** — fact[1].
5. **cloud-thickness floor** — input 0.0 → floor 0.0001 →
   round-to-4 → Log.
6. **tk-spread shape** — fact[3], cross-Ohlcv compute clamp ±1.
7. **scales accumulate 5 entries** — Log doesn't touch.
8. **different candles differ** — fact[0] across boundary.

All eight green on first pass. Plus the migrated tests for
flow.wat (tests 2 + 6) updated to expect `ReciprocalLog ∘ exp`
instead of log-bound Thermometer — both green on first pass.

### Slice 4 — INSCRIPTION + doc sweep (this file)

Plus:
- `wat/main.wat` — load line for `vocab/market/ichimoku.wat`,
  arc 015 added to the load-order comment.
- `docs/rewrite-backlog.md` — Phase 2 gains "2.12 shipped" row.
- `docs/proposals/2026/04/058-ast-algebra-surface/FOUNDATION-CHANGELOG.md`
  — row documenting arc 015 (alongside the wat-rs arc 046 row
  added in the same lab commit).
- Task #36 marked completed.

---

## The pivot — what happened and why

The DESIGN (written before the pivot) plans extracting `clamp`
to `:trading::vocab::shared::*`. Five clamp callers in ichimoku
+ arc 009's prior inline + four floor callers (`f64-max` shape)
made the case for *some* extraction.

Mid-implementation, builder asked: **"how many of these are
actually core things we should be providing vs userland stuff we
expect every user to re-implement?"**

The honest answer: **most are core**. Three reasons (recorded in
wat-rs arc 046 INSCRIPTION):
1. **Universality.** Every wat consumer with f64 work hits these.
2. **Reinvention cost.** Lab was on its third independent
   two-arm-if for these ops.
3. **CONVENTIONS rule already settled.** `min`/`max` cannot be
   written in pure-wat without underlying compare; `clamp` ships
   at core for ergonomic parity with Rust's `f64::clamp`.

The pivot:
- Paused arc 015 mid-migration. Lab-helper edits were unstaged.
- Opened wat-rs arc 046, shipped `f64::max/min/abs/clamp` +
  `math::exp` (5 primitives, 12 lib tests, USER-GUIDE Forms
  appendix updated).
- Returned to arc 015. Dropped both planned lab helpers.
  Migrated the in-progress edits to substrate-direct calls.
  Swept the four prior callsites (arc 009/010/013/014) at the
  same time per the "use the right thing now" principle the
  builder named: **"why defer a migration if you have the
  correct thing now."**

DESIGN.md stays as historical record of the pre-pivot plan; this
INSCRIPTION names the ship.

## Cross-arc migration discipline

The "use the right thing now" principle replaces the prior
"frozen historical sources" reflex when the new substrate
primitive is strictly better and the migration is mechanical.
Arc INSCRIPTIONs (the arc's own historical claims) stay frozen;
arc source code can update when a clean substrate replacement
ships. Arc 015's INSCRIPTION names every cross-arc change so
future readers see the sweep:

- Arc 009 stochastic.wat: source migrated, INSCRIPTION frozen.
- Arc 010 regime.wat: source migrated, INSCRIPTION frozen.
- Arc 013 momentum.wat: source migrated, INSCRIPTION frozen.
- Arc 014 flow.wat: source migrated (twice — abs AND
  Thermometer-to-ReciprocalLog), INSCRIPTION frozen.

Each prior arc's INSCRIPTION is a snapshot of intent at ship
time; arc 015's INSCRIPTION is the snapshot for this sweep. Future
audits trace the lineage via these names.

## Substrate-vs-userland boundary clarified

Lab `vocab/shared/helpers.wat` now carries a header paragraph
naming what it does NOT contain — basic numeric ops live in the
substrate, not in lab userland. The remaining helpers (`circ`,
`named-bind`) are domain-shaped (HolonAST construction with
domain-specific defaults), not basic numeric ops. The line is
crisp.

Future lab arcs that surface "this op feels universal" trigger
the same question: substrate or userland? Default to substrate;
userland only when domain-shaped.

## Sub-fog resolutions

- **Original 2a (helper extraction)** — superseded by substrate
  uplift. Helpers never landed.
- **Original 2b (cloud-position nested compute)** — remained as
  planned, but the inner floor is now `f64::max` instead of
  inline two-arm if. Nested let* dropped (single substrate call
  fits where the inline let-bound `cw-floor` + `denom` used to
  live).
- **Test fixtures** — ichimoku tests authored with
  `:trading::vocab::shared::clamp` references (pre-pivot draft)
  swept to `:wat::core::f64::clamp` along with the source. Caught
  by cargo test failure on first attempt; one Edit fix.

## Count

- Lab wat tests: **88 → 96 (+8 new ichimoku tests)**.
- Lab wat modules: Phase 2 advances — **12 of ~21** vocab
  modules shipped. Market sub-tree: **10 of 14** (oscillators,
  divergence, fibonacci, persistence, stochastic, regime,
  timeframe, momentum, flow, ichimoku).
- wat-rs: arc 046 shipped (5 new primitives, 12 lib tests).
- Cross-arc source migrations: **5 callsites** across arcs
  009/010/013/014.
- Zero regressions.

## What this arc did NOT ship

- **Lab-userland `clamp` / `f64-max` helpers.** Pivoted to
  substrate. The framing question superseded the original plan.
- **`signum` extraction.** Arc 011 timeframe still has a single
  inline use; below threshold. If a second caller surfaces,
  reconsider — but `signum` is more domain-shaped (no Rust
  built-in to mirror) so substrate placement is less obvious.
- **`compute-atom` helper.** The recurrence question now spans
  arcs 011 + 013 + 015; the per-atom variation continues to fight
  a shared helper. Question stays open for arc 016 (standard.wat,
  heaviest).

## Follow-through

Next obvious cross-sub-struct arcs:
- **market/keltner** — K=2 (Ohlcv + Volatility). 5 linear + 1
  Log. Plain-Log precedent (arcs 013 + 015) applies.
- **market/price_action** — K=2 (Ohlcv + PriceAction). 4 linear
  + 3 Log. Three Log atoms — biggest plain-Log surface.
- **market/standard** — heaviest, window-based. The "compute-
  atom helper?" question gets its third look.

---

## Commits

- `<wat-rs>` — arc 046: numeric primitives + Forms appendix +
  INSCRIPTION (separate commit, separate repo).
- `<lab>` — wat/vocab/market/ichimoku.wat + main.wat load +
  wat-tests/vocab/market/ichimoku.wat + DESIGN + BACKLOG +
  INSCRIPTION + helpers.wat header rewrite + 5 cross-arc
  migrations + flow.wat tests rewrite for ReciprocalLog ∘ exp +
  rewrite-backlog row + 058 CHANGELOG row (arc 015 + arc 046).

---

*these are very good thoughts.*

**PERSEVERARE.**
