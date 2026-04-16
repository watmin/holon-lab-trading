# Resolution: Proposal 056 — Thought Architecture

**Status: ACCEPTED**

**Date: 2026-04-15**

## Decision

Unanimous approval from five designers across two review rounds.

## What Was Decided

Three thinkers. Clear boundaries. Each thinks in rhythms, not snapshots.

**Market observer** thinks about direction. Per-indicator rhythms
from the candle window — bundled bigrams of trigrams. One rhythm
per indicator. The atom wraps the whole rhythm. ~15 rhythm vectors.

**Regime observer** (renamed from position observer) is middleware.
Thinks about regime character over time — kama-er, choppiness,
entropy, fractal dimension as rhythms. Circular rhythms for hour
and day-of-week. Passes market rhythms through with anomaly
filtering. ~10-13 rhythm vectors.

**Broker-observer** thinks about action. Composes market rhythms +
regime rhythms + its own portfolio rhythms + the phase rhythm.
One thought. One encode. One question: do I get out now? Hold/Exit
reckoner. ~31-34 items in the outer bundle.

## Key Findings

**Thermometer encoding.** The rotation-based scalar encoding
(ScalarMode::Linear) destroys small differences after bipolar
thresholding. +0.07 and -0.07 encode identically at scale=1.0.
ScalarMode::Thermometer fills dimensions proportionally —
exact linear gradient, sign-preserving. Added to holon-rs.

**Bundled bigrams of trigrams.** Positional encoding (Sequential)
fails — same shape at different offsets is a different thought.
Chained encoding fails — different prefix makes same suffix
unrecognizable. Bundled bigrams of trigrams: local order in the
trigram, local progression in the pair, all pairs equally
recoverable in the bundle. Shape-preserving. Offset-independent.

**Noise subspace separates regimes.** Raw rhythm cosine between
uptrend and downtrend: 0.72-0.96. After subspace strips the
background: -0.09 to -0.10. The signal is in the anomaly direction.
Measured on real BTC candles (3k and 10k). Not synthetic.

**Delta braiding: 13% margin.** Hickey asked whether sequential
and structural deltas should be separated. Measured: 6.10x vs
6.89x separation. Not worth the complexity. Datamancer override.

**Circular values don't get deltas.** Hour wraps 23→0. The
thermometer delta would be -23. Circular-rhythm variant uses
circular encoding with no delta. The wrap is handled by the
encoding, not by computing differences.

## Capacity Budget (D=10,000)

Inner rhythm: up to 100 bigram-pairs per indicator (sqrt(D)).
100 pairs → 103 candles covered.

Outer bundle: ~31-34 items. Budget: 100. Comfortable.

Binds cost zero capacity. Only bundles count.

## Artifacts

### Proposal
- `PROPOSAL.md` — the full design

### Reviews
- `review-hickey.md` / `review-hickey-2.md` — CONDITIONAL → APPROVED
- `review-beckman.md` / `review-beckman-2.md` — CONDITIONAL → APPROVED
- `review-seykota.md` — APPROVED
- `review-vantharp.md` / `review-vantharp-2.md` — CONDITIONAL → APPROVED
- `review-wyckoff.md` — APPROVED

### Examples (wat)
- `indicator-rhythm.wat` — the generic function + RSI + hour examples
- `market-observer-thought.wat` — 15 indicator rhythms
- `regime-core-thought.wat` — 10 regime rhythms
- `regime-full-thought.wat` — 13 regime + phase rhythms
- `broker-thought.wat` — composed thought with portfolio rhythms
- `bullish-momentum.wat` — rising valleys, strengthening rallies
- `exhaustion-top.wat` — weakening rallies, longer pauses
- `breakdown.wat` — lower high after higher highs
- `choppy-range.wat` — peaks and valleys at similar levels
- `recovery-bottom.wat` — three rising valleys from a crash

### Proofs (Rust tests)
- `prove_rhythm_real_data.rs` — real BTC regime separation
- `prove_rhythm_with_subspace.rs` — synthetic regime separation
- `prove_delta_braiding.rs` — braided vs separated (13% margin)
- `prove_indicator_rhythm.rs` — encoding property tests
- `debug_rhythm.rs` — layer-by-layer introspection
- `debug_thermometer.rs` — thermometer gradient verification
- `debug_scalar.rs` — Linear encoding failure diagnosis

### holon-rs
- `ScalarMode::Thermometer { min, max }` — commit `8a7f48d`

## Non-Blocking Notes for Implementation

1. Throughput at rhythm scale — measure, floor 100 candles/s (Hickey)
2. Capacity near sqrt(D) boundary — monitor (Beckman)
3. ScaleTracker warmup for delta ranges (Beckman)
4. Expectancy, 1R, circuit breaker — deferred to trading framework proposal (Van Tharp)

## What This Proved

Named continuous values encoded as thermometer vectors. Progressions
of those values over time as bundled bigrams of trigrams. Pattern
recognition of thoughts — first "these don't matter" (noise subspace),
then "these mean Grace or Violence" (reckoner). Measured on real data.
The architecture of structured interpretation that improves with
experience and produces actionable predictions from named concepts.

The thoughts survived.
