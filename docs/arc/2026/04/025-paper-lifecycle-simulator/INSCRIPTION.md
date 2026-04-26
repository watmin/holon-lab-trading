; lab arc 025 — Paper Lifecycle Simulator — INSCRIPTION

**Status:** shipped 2026-04-25. The yardstick. Six slices delivering
ATR + median-week window, PhaseState, simulator types + label
coordinates, the lifecycle engine, two v1 thinkers + cosine-vs-corners
predictor, and this INSCRIPTION + cross-link. ~1,600 LOC of wat
across 7 files; 52 tests added; 2 substrate uplifts shipped to wat-rs
as carry-alongs.

Builder direction:

> "what we need is a yardstick"

> "we'll build that... before we build the trees and treasuries
> and brokers... we need to know if our domain logic produces good
> trades... or not"

The simulator turns the abstract claim "this thinker thinks well"
into a concrete `:trading::sim::Aggregate` — papers, grace-count,
violence-count, total-residue, total-loss — comparable across
encoding experiments, observer ports, and parameter sweeps. Every
phase 4-9 port can now be measured against a reference run rather
than parity-by-faith.

Paused at slice 4 mid-arc (2026-04-25) for arc 026's IndicatorBank
port; resumed and closed same day after arc 026's INSCRIPTION
landed. The simulator's Thinker reads from the IndicatorBank's
73-field Candle without recomputing.

---

## What shipped

5 substantive slices + INSCRIPTION (this slice). Two substrate
uplifts surfaced and shipped during slices 1-2; the rest of arc
025's algebra rode them.

| Slice | Module | LOC | Tests | Status |
|-------|--------|-----|-------|--------|
| 1     | `wat/encoding/atr.wat` + `atr-window.wat` | ~80 + ~75 | 12 | shipped |
| 2     | `wat/encoding/phase-state.wat` | ~330 | 8 | shipped |
| 3     | `wat/sim/types.wat` + `labels.wat` | ~200 + ~120 | 13 | shipped |
| 4     | `wat/sim/paper.wat` (engine, 6 helpers + tick + run-loop + run) | ~620 | 18 | shipped + Q10 follow-up |
| 5     | `wat/sim/v1.wat` + `wat-tests/sim/integration.wat` | ~120 + ~50 | 1 | shipped |
| 6     | This INSCRIPTION + rewrite-backlog cross-link | doc-only | — | shipped |

**Lab wat test count: 152 (pre-arc-025) → 329 (post-arc-025).
+52 wat tests over the arc** (rest of the 152→310 reported in arc
026's INSCRIPTION came from arc 026's slices, which interleaved
with arc 025).

---

## Substrate uplifts to wat-rs

Two carry-alongs shipped as natural-form-then-promote, in the
rhythm established by arcs 046–055. Both went into arc 026's
INSCRIPTION already (since the two arcs interleaved); listed here
for arc 025 attribution.

| Uplift | Surfaced by | wat-rs commit |
|--------|-------------|---------------|
| `:wat::core::sort-by` | slice 1 (AtrWindow median) | `6f5c77e` |
| `:wat::core::not=` + Enum equality | slice 2 (PhaseState boundary) | `4e854b6` |

Slices 3-5 surfaced **zero** substrate gaps — the slice-3
Thermometer-encoded labels, the slice-4 lifecycle engine, the
slice-5 cosine-vs-corners predictor all consumed shipped wat-rs
primitives directly. Slice 4 was the first consumer slice in the
trading lab to ask for nothing new from the substrate.

---

## Architecture notes

### Chapters 55-57 absorbed mid-arc (slice 3 reshape)

The user landed three BOOK chapters between slice 2 and slice 3
that reshape the simulator's external contract:

- **Chapter 55 — The Bridge.** Thinker stops emitting `Up | Down`;
  it emits a *surface AST*. A separate Predictor turns the surface
  into an Action. Vocabulary becomes the unit of selection.
- **Chapter 56 — Labels as Coordinates.** Style B (explicit
  axis-bindings) over implicit AST-as-label. Two basis atoms span
  a label space the same way Chapter 51's `axis-x`/`axis-y` spanned
  a Cartesian plane.
- **Chapter 57 — The Continuum.** Every binary distinction in the
  lab is the discretization of a continuum the substrate already
  encodes. Corner labels are a teaching device; training labels
  are continuous Thermometer positions.

Slice 3 wrote against the new shapes (Thinker + Predictor structs;
Style-B Bundle paper-label builder; four corner reference labels
at the `(±0.05, ±0.05)` extremes). Slice 4's engine threads
Predictor return values through the four-gate Grace/Violence model.
Slice 5's v1 thinkers project candle indicators directly into the
label basis (Q11 — same outcome × direction axes the labels live
on, so cosine-vs-corners is meaningful).

### The decomposition restart (slice 4)

The first attempt at `tick` shipped at ~270 lines as a single
function and hit a paren-discipline wall during debugging. Restart
extracted six helpers (`evaluate-grace-eligible?`,
`tick-resolve-violence`, `tick-resolve-grace`, `tick-open-new-paper`,
`tick-continue-holding`, `tick-handle-no-paper`) — `tick` became
a ~50-line orchestrator dispatching over `(state.open-paper, action,
deadline-reached?, grace?)`. SLICE-4-PLAN.md preserves the
restart's reasoning per `feedback_proposal_process`.

### Q10 — Predictor stateless, simulator translates (slice 4 follow-up)

slice-4-5-design-questions.md formalized five design questions that
surfaced before slice 5 opened. Q10 was the load-bearing one for
slice 4: the v1 Predictor argmaxes corners and emits one of
`:Hold | (Open :Up) | (Open :Down)` — never `:Exit`. The simulator
translates `(Open !d)` while holding `paper-d` into `:Exit` upstream
of the gate check (`effective-action` helper). This keeps the
Predictor's contract clean for the future reckoner-backed swap;
a learned predictor that *does* want position-awareness can take
it via a richer surface (Q14 leaves the `Option<Paper>` param honest
in the Thinker signature for that arc).

The Q10 fix landed as a follow-up commit on slice 4 — original
9 tests stayed green; 9 additional helper-level tests + 3 Q10
translation tests joined.

### Producer-side bounded runs (slice 4)

Original plan: a `run-bounded` engine variant taking a max-candles
parameter. Shipped instead: a producer-side cap via
`(:trading::candles::open-bounded path n)`. The engine has no
max-candles knob — `run-loop` terminates on the stream's natural
end-of-stream. Streaming semantics preserved (one record-batch
at a time from disk; the cap just changes when the producer signals
`:None`). Adds ~10 LOC to `src/shims.rs`.

### Helper-level tests over OHLCV-engineered streams (slice 4 / Q13)

Tests 18-23 (Always-Up reaches Peak → Grace; Always-Down symmetric;
residue floor blocks Exit; retroactive labeling Grace; retroactive
labeling Violence; two-paper aggregate) need engineered phase
histories. ATR has a 14-candle warmup; PhaseState's smoothing is
`2 × ATR.value`. Engineering a deterministic Peak in a short
fixture isn't tractable.

The archive's `pivot.rs` tests took the same recognition: pass
`smoothing` directly as a parameter, drive the state machine with
hand-picked values, test the algebra in isolation. Slice 4's tests
18-23 follow that move — exercise `evaluate-grace-eligible?`,
`label-trail-grace`, `label-trail-violence`, `aggregate-grace`,
`aggregate-violence` directly with synthesized inputs. Skips the
IndicatorBank/ATR thread entirely. ~150 LOC of focused tests vs.
~400 LOC of OHLCV-engineered streams.

### Smoothing warmup behavior in practice (sub-fog 5a)

The integration smoke runs 10,000 candles. ATR is ready by candle
14; PhaseState's smoothing settles within tens of candles after.
The 2016-candle AtrWindow median (intended as the eventual
smoothing source per Proposal 052) **is not yet wired** —
IndicatorBank uses `2 × current-ATR` as the smoothing parameter
in v1. The AtrWindow + median ride forward to a successor arc when
a downstream consumer needs the week-stable smoothing.

Practical effect: the simulator opens its first papers in single
digits of ticks. Both Grace and Violence resolutions fire across
10,000 candles. The conservation invariant
(`papers = grace-count + violence-count`) holds end-to-end on real
BTC data.

---

## What this unblocks

The yardstick is the unblocker. Every Phase 4-9 port can now:

- Run the simulator with a candidate Reckoner-backed Predictor;
  compare residue / grace-count / paper-count against v1's
  `cosine-vs-corners-predictor` baseline.
- Run a richer thinker (RSI + MACD + ADX vocabulary) against the
  same predictor; measure whether the new vocabulary produces more
  Grace.
- Run a parameter sweep (deadline, min-residue, fee-bps) against
  the same thinker + predictor; measure which knob settings produce
  more Grace.
- Run different label axes (third axis: duration, phase-count,
  excursion); measure sample efficiency vs. predictive lift.

The lab moves from "vibes" to "numbers." Every encoding experiment
produces an Aggregate; we compare deltas.

---

## Out of arc, deferred to successor work

- **Reckoner-backed Predictor** — the bridge from Chapter 55. v1's
  `cosine-vs-corners-predictor` is hand-coded; the successor arc
  swaps in a reckoner that learns from continuous `(surface,
  paper-label)` pairs as papers resolve.
- **Trust-ladder deadline scaling** — v1 uses static `deadline=288`.
  Multi-broker tournament + `ProposerRecord` mapping trust to
  deadline ∈ [288, 2016] is a successor arc.
- **Multi-broker tournament** — single broker for v1. CSP-parallel
  N-broker simulation with per-broker `ProposerRecord` is a
  natural extension; the simulator generalizes to it.
- **Position observer (gate 4 learner)** — Phase 4 work. Q14's
  `Option<Paper>` slot in the Thinker signature is reserved for it.
- **Third+ label axes** (duration / phase-count / max-favorable-
  excursion) — sample-efficiency question. Add when a query
  against the third axis has a real caller.
- **AtrWindow median as smoothing source** — currently
  `2 × current-ATR`; switch to `2 × atr-window-median` once the
  week-stable behavior is needed (Proposal 052's intent).
- **Real position bookkeeping** — papers don't move capital. Real
  position type lands in Phase 5+.

---

## The thread

- **arc 025 slice 1** (2026-04-25, `2c8b95f`) — ATR + AtrWindow.
- **arc 025 slice 2** (2026-04-25, `f3711e2`) — PhaseState.
- **arc 025 slice 3** (2026-04-25, `7c0ed13`) — sim types + labels.
- **arc 026 slices 1-13** (2026-04-25) — IndicatorBank port (paused
  arc 025 mid-flight).
- **arc 025 slice 4** (2026-04-25, `fd05a93`) — simulator engine.
- **arc 025 slice 4 follow-up** (2026-04-25, `c2dfd4c`) — Q10
  effective-action + helper-level tests 18-23.
- **arc 025 slice 5** (2026-04-25, `9c3cde0`) — two v1 thinkers,
  cosine-vs-corners predictor, integration smoke.
- **arc 025 slice 6** (this commit) — INSCRIPTION + cross-link.

One day. Six slices. The yardstick.
