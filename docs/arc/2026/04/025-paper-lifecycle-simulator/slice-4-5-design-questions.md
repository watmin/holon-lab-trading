# lab arc 025 — slice 4 / 5 design questions

**Status:** resolved 2026-04-25. User approved all five recommendations.

Surfaced by the building Claude before slice 5 opened. Five real
design choices that pin v1's Predictor + Thinker contract; getting
them wrong means re-writing the thinker after slice 5. Captured
here as a sibling doc to DESIGN.md so future readers (the building
Claude after compaction; successor arcs) can find the resolutions
without re-deriving them.

These supersede any earlier implicit assumptions in DESIGN.md or
BACKLOG.md slices 4-5.

Builder direction:

> "five things, in order of how much they could derail slice 5..."

> "i've read it and i agree with it"

| Question | Affects | Resolution |
|----------|---------|------------|
| Q10 — corner→Action map | slice 4 | Predictor stateless; simulator does position-aware translation |
| Q11 — surface-basis vs label-basis | slice 4 | v1 thinkers emit surfaces in `outcome-axis × direction-axis` basis (same as labels) |
| Q12 — v1 thinker vocabulary | slice 5 | Two v1 thinkers: `always-up-thinker` (smoke), `sma-cross-thinker` (real-ish) |
| Q13 — slice 5 test scope | slice 5 | Smoke only; tests 18–23 stay in slice 4 with synthetic fixtures |
| Q14 — Thinker's `Option<Paper>` | slice 4 | v1 ignores it; param in signature is honest but unread |

---

## Q10 — Corner → Action mapping

**Recommendation: Predictor is stateless w.r.t. open-paper state;
the simulator does position-aware translation.**

v1 mapping at the Predictor:

```
argmax corner          Predictor returns
─────────────────────  ──────────────────
corner-grace-up    →   (Open :Up)
corner-grace-dn    →   (Open :Down)
corner-violence-up →   :Hold
corner-violence-dn →   :Hold
```

`:Exit` never comes from the Predictor in v1. The simulator
interprets the Predictor's Action against the current paper state:

```
no paper open + (Open dir)   → open new paper in dir
paper-d open  + (Open d)     → :Hold (already going that way)
paper-d open  + (Open !d)    → :Exit current paper (trend turned)
any           + :Hold         → keep current state
```

This keeps the Predictor's contract clean — surface goes in, Action
comes out, no awareness of position state. The simulator is the
only thing that knows "we're currently long Up." It interprets a
Predictor saying `(Open :Down)` while we hold Up as "exit." Composes
naturally with the four-gate lifecycle: gates 1-3 still apply before
the simulator allows an Exit.

The "violence-* → :Hold" choice rather than "(Open opposite-dir)" is
the conservative read: violence-up means "Up will violence" — it
doesn't *necessarily* mean "Down will grace." Don't trade unless
the predictor has positive Grace conviction.

### Alternative considered

The Predictor could emit `:Exit` directly when argmax = violence-our-direction. This requires the Predictor to know about position state (either via the surface encoding it, or via a separate parameter). Both options couple the Predictor to lifecycle state in ways the v1 hand-coded version doesn't need; rejected for v1. Successor arc with reckoner-backed Predictor may want this — the coupling becomes worth it once the Predictor is learning.

---

## Q11 — Surface-basis vs label-basis cosine

**Recommendation: v1 thinkers emit surfaces in the same basis as
labels — `outcome-axis × direction-axis`.**

The thinker is the projector. Cosine-vs-corners is meaningful
because both sides live in the same coordinate system.

This means the v1 hand-coded thinker is doing TWO jobs:

1. Encoding the candle window (reading indicator values from arc 026's populated Candle)
2. Projecting that encoding into outcome × direction space (computing two scalars: `grace_lean` and `up_lean`)

```scheme
;; v1 thinker — projects candle indicators directly into label basis
(:trading::sim::Thinker
  :build-surface
  (lambda ((window :Candles) (pos :Option<Paper>)) -> :HolonAST
    ;; Compute lean-Up scalar from indicators (e.g., MACD positive?
    ;;   SMA20 > SMA50?)
    ;; Compute lean-Grace scalar from indicators (e.g., trend strength?)
    ;; Emit Bundle(Bind(outcome-axis, Therm(grace_lean,    -0.05 0.05)),
    ;;             Bind(direction-axis, Therm(up_lean,     -0.05 0.05)))
    ...))
```

### Why option (b) — unbind direction-axis from a rich indicator-basis surface — doesn't work

If the thinker emitted surfaces in indicator basis (`Bind(rsi-axis,
Therm(...))`, `Bind(macd-axis, Therm(...))`, etc.), unbinding
`direction-axis` returns noise — the surface has no
`direction-axis` bind. Cosine vs the four corners would be
substrate-noise (cross-axis cosines are ~0). The Predictor's
argmax becomes meaningless.

Chapter 56 names axis-decomposition as a *future* capability when
the thinker emits surfaces in the right basis; it doesn't claim
unbinding works on arbitrarily-basis'd surfaces. The basis must be
shared between surfaces and labels for cosine to mean what we want
it to mean.

### What this restricts in v1

The v1 thinker is restricted to projecting into outcome × direction.
It cannot emit rich indicator-encoded surfaces *and* cosine against
labels — those are different bases. Two paths to richer thinkers:

- **Path A (v1 stays here):** Thinker hard-codes the projection into outcome × direction. Different thinkers project differently (`always-up-thinker`, `sma-cross-thinker`, etc.) — but all output in label basis.
- **Path B (successor arc):** Thinker emits rich indicator-basis surfaces; reckoner-backed Predictor learns the projection. Different thinkers expose different vocabularies; the Predictor learns to weight them.

v1 stays on Path A. Path B opens once labels accumulate from
resolved papers and the reckoner has training data.

---

## Q12 — v1 thinker vocabulary content

**Recommendation: ship TWO thinkers in v1.**

### `:trading::sim::always-up-thinker`

Constant surface biased toward `corner-grace-up`:

```scheme
build-surface(_window, _pos) →
  Bundle(Bind(outcome-axis,   Thermometer(+0.04, -0.05, 0.05)),
         Bind(direction-axis, Thermometer(+0.04, -0.05, 0.05)))
```

Used for slice 5's integration smoke. Deterministic. Simplest possible.
Predictor argmaxes to `(Open :Up)`. Every paper opens Up; some Grace,
some Violence depending on what BTC does over the test window.

### `:trading::sim::sma-cross-thinker`

Reads `candle.sma20` and `candle.sma50` from arc 026's IndicatorBank
output:

```
sma20 > sma50 * 1.001  →  (outcome = +0.03, direction = +0.04)   ; lean grace-up
sma20 < sma50 * 0.999  →  (outcome = +0.03, direction = -0.04)   ; lean grace-down
otherwise              →  (outcome = -0.02, direction = 0.0)     ; lean violence-neutral
```

Two indicators. Both populated by IndicatorBank from candle 0 (no
warmup-skip). Test fixtures can drive it with hand-built crossing
streams. Defensible enough to be the v1 baseline; richer thinkers
(RSI + MACD + ADX) land in successor arcs once the simulator's
lifecycle is proven.

### Why two and not one

`always-up-thinker` is the smoke-test minimum — proves the simulator
runs end-to-end. `sma-cross-thinker` is the first thinker that
actually *thinks* — proves the cosine-vs-corners predictor produces
different Actions on different surfaces. Both ship in slice 5 (~50
LOC each + a couple tests).

### Threshold values

The `1.001 / 0.999` band on `sma20 / sma50` is a defensible-but-
arbitrary 0.1% deadband. Smaller would over-fire on noise; larger
would miss real crosses. Tunable in a successor arc that measures
which threshold produces the most Grace residue on the 6-year
stream.

---

## Q13 — Slice 5 integration test scope

**Recommendation: slice 5 stays scoped to a single smoke test.**

Tests 18-23 belong in slice 4's unit-test suite, with synthetic
OHLCV streams that produce the specific shapes
(peak-forms-at-candle-50, two-papers-Grace-and-Violence, etc.).
Real BTC data won't reliably exercise those exact behaviors;
synthetic fixtures will.

If the BACKLOG update during slice 4 said tests 18-23 "ride into
slice 5," that was over-eager. Revert to slice-5-as-smoke:

```scheme
(:wat::test::deftest :trading::test::sim::integration::ten-thousand-candles
  ()
  (:wat::core::let*
    (((stream :trading::candles::Stream)
      (:trading::candles::open-bounded "data/btc_5m_raw.parquet" 10000))
     ((thinker :trading::sim::Thinker)        <always-up-thinker>)
     ((predictor :trading::sim::Predictor)    <cosine-vs-corners-predictor>)
     ((config :trading::sim::Config)          <default-config>)
     ((agg :trading::sim::Aggregate) (:trading::sim::run stream thinker predictor config)))
    ;; Smoke only: simulator ran end-to-end, produced finite numbers.
    (:wat::test::assert-eq (:wat::core::> agg.papers 0) true)
    (:wat::test::assert-eq (:wat::core::f64::is-finite? agg.total-residue) true)))
```

Tests 18-23 stay in slice 4 with synthetic streams. They prove the
LIFECYCLE; slice 5 proves the simulator survives real data.
Different concerns; different fixtures.

### Why split

Real-data smoke is about "does this code path crash on a parquet of
650k candles?" — a presence test. Lifecycle proofs are about "does
Grace fire when the four gates align? does Violence fire on
deadline? are trail labels back-filled correctly?" — those are
synthetic-fixture territory because the test asserts specific
behaviors that real BTC data would only hit by accident.

If tests 18-23 ride into slice 5, slice 5 needs to construct
hand-built streams for each test, which defeats the purpose of "use
real BTC data" for slice 5.

---

## Q14 — Thinker's use of `Option<Paper>`

**Recommendation: v1 thinker IGNORES `Option<Paper>`.**

Same vocabulary regardless of position state. The simulator's
position-aware Action interpretation (Q10) handles state-dependence
at the outer layer.

```scheme
;; v1 thinkers — Option<Paper> in the signature but unread.
(lambda ((window :Candles) (_pos :Option<Paper>)) -> :HolonAST ...)
```

The param stays in the signature so the contract is honest (and so
future thinkers can read it without re-typing). v1's two thinkers
both ignore it.

### What the future does with it

Chapter 56's "axis can be a vocabulary's identity atom or another
reckoner's predicted label" hints at the future: a thinker that
DOES read position state would add a `holding-axis` bind to its
surface — `Bind(holding-axis, Up-atom)` if a paper is open Up,
`Bind(holding-axis, None-atom)` if no paper. The Predictor cosines
those against position-aware label corners. But that's a richer
label space (`outcome × direction × holding-state` = 8 corners or a
continuous third axis) and a successor-arc concern.

For v1, we want the thinker stateless w.r.t. position so the
simulator's translation logic (Q10) is the single source of
position-awareness. Two state machines tracking position would be
two places to get wrong.

---

## What this doc supersedes

- DESIGN.md's earlier implicit "the Predictor returns Action; some unspecified mapping" — this doc pins it (Q10).
- DESIGN.md's earlier implicit "thinker emits some surface; Predictor cosines vs labels" — this doc pins the basis (Q11).
- DESIGN.md sub-fog 5d's "v1 thinkers can be hand-coded" — this doc names the two specific v1 thinkers (Q12).
- BACKLOG.md slice 4's mid-flight update that pulled tests 18-23 into slice 5 — this doc reverts that, returning slice 5 to smoke-only and keeping tests 18-23 in slice 4 (Q13).
- BACKLOG.md's slice-3 Thinker signature note that `Option<Paper>` is "for future use" — this doc names that v1 ignores it (Q14).

When slices 4 and 5 ship and the INSCRIPTION lands, this doc's
resolutions get cited as "Q10–Q14 per slice-4-5-design-questions.md."

---

## Successor work made cleaner by these resolutions

- **Reckoner-backed Predictor** (the bridge from Chapter 55) — Q11's
  basis decision means the labels are already in a coordinate system
  the future reckoner can train on. No re-projection needed.
- **Richer thinkers** (RSI + MACD + ADX vocabularies) — Q12's
  two-thinker approach establishes the pattern; new thinkers slot in
  as additional structs with the same signature.
- **Position-aware thinkers** — Q14 leaves the Option<Paper> param
  honest in the signature, so a successor thinker can read it
  without breaking existing v1 thinkers.
- **Multi-broker tournament** — Q10's stateless Predictor + simulator-
  side translation generalizes naturally; each broker has its own
  Thinker + Predictor pair, simulator-side translation works
  per-broker without changes.
