# Resolution: Proposal 003 — Observer Redesign

**Status: ACCEPTED with conditions**

Both designers approved conditionally. The datamancer resolves the conditions below.

## The Design

Every observer becomes a two-stage pipeline:
1. **Noise subspace** (Template 2) — learns what's boring from Noise-labeled candles
2. **Journal** (Template 1) — learns Buy/Sell from the L2-normalized residual

The Observer is defined by three configuration axes:
- **Vocabulary** — which fact modules it sees
- **Labels** — what question it answers (Buy/Sell, Healthy/Unhealthy, Hold/Exit)
- **Window** — how much history it looks at

## Resolved Conditions

### L2-normalize the residual — ACCEPTED (Beckman)
Both agree. The residual after noise subtraction has reduced norm. Without normalization, the journal's prototype accumulation is biased by noise-subspace maturity. Normalize before feeding to the journal.

The datamancer's note: L2 normalization has caused issues before. We try it Beckman's way. If prototype separation degrades, we revisit. The data decides.

### Noise-only training — ACCEPTED (both)
The noise subspace learns ONLY from Noise-labeled candles — outcomes where price didn't cross the threshold. Training on all candles would subtract signal along with noise. The noise manifold is "what thoughts look like when nothing happens."

### On Buy/Sell learning — CLARIFICATION
The noise subspace does NOT learn Buy or Sell. It learns NOISE. The learning split:
- **Noise outcome** → `(update noise-subspace thought)` — teach what's boring
- **Buy/Sell outcome** → `(observe journal residual label weight)` — teach direction from clean signal

The journal still learns Buy vs Sell the same way it always has — from the threshold crossing label. The noise subspace just cleans the input first. The journal's prototypes separate better because the shared structure (the 45 always-present facts) has been removed before the prototypes ever see it.

### No decay to start — ACCEPTED (both)
Let the noise subspace accumulate across all regimes. Measure eigenvalue stability over 652k candles. If eigenvalues stabilize, decay is unnecessary (markets are cyclical, noise recurs). If they drift, add decay or engrams later. Simplest hypothesis first.

### k=8, calibrate empirically — ACCEPTED (compromise)
Start at k=8 (matches risk branch convention). Hickey wants measurement at k=2,4,8 — run all three, compare prototype separation. Beckman says read the eigenvalue gap. Both approaches say the same thing: let the data pick k.

### Calendar as standard — ACCEPTED (both)
Move calendar/session facts from Narrative-exclusive to standard (all observers). Every observer gets the opportunity to discover temporal context. The noise subspace handles irrelevance — if time doesn't matter for momentum, the momentum observer's subspace strips it.

### One generalist, not N — ACCEPTED (Hickey)
Start with one generalist (vocab = all). Cross-domain observers are future work. The generalist IS the superposition of all specialists. Adding more generalist variants is a combinatorial problem — the curve can't judge 10 observers on thin data. One generalist, proven, then explore.

### Clarify noise subspace vs good-state subspace — ACCEPTED (Hickey)
Two separate OnlineSubspace instances on every observer:
1. **Noise subspace** — operates on THOUGHT vectors, learns boring fact patterns
2. **Good-state subspace** (engram) — operates on DISCRIMINANT vectors, learns what good journal states look like

Different inputs, different purposes, different update gates. Both are Template 2. Both live on the Observer. They don't interact — the noise subspace preprocesses the journal's input, the good-state subspace postprocesses the journal's output.

### Monotonic warmup passthrough — ACCEPTED (Beckman)
Until the noise subspace has sufficient samples (min_samples), pass the raw thought through unfiltered. No partial subtraction. The transition should be monotonic — either full subtraction or none. This prevents the noise subspace from actively harming predictions during warmup.

### Update wat before Rust — ACCEPTED (Beckman)
The wat specification is updated FIRST. The Rust implements it. This is standing policy.

## Candidate Thoughts — Priority Order

Both designers agree on the first three. The datamancer adds the fourth.

1. **Recency** — time since last event (encode-log candles-since). Varies across candles, cheap to compute, not duplicated by existing facts.
2. **Distance from structure** — how far from 24h high, 48h low, range midpoint. Continuous scalar, not binary above/below. The tension IS the distance.
3. **Relative participation** — volume as ratio to its moving average. Continuous scalar, not binary spike/drought. Available to everyone.
4. **Session depth** — how deep into the current session (encode-linear fraction). First 30 minutes of US open vs last hour.

### Deferred

- **Self-referential facts** — both designers reject due to feedback loop risk. The datamancer agrees the PROPOSED self-referential facts are bad (observer encoding its own accuracy into its own input). But self-awareness as a concept isn't dead — the right self-referential thought may exist. Deferred, not killed.
- **Candle character** (doji, hammer, engulfing) — Hickey argues existing atoms already compose these morphologies. The datamancer is skeptical — prior attempts at compound emergent thoughts didn't work well. Deferred pending evidence that raw OHLCV ratios capture what named patterns do.
- **Velocity** (ROC of ROC) — already partially implemented as roc-accelerating/decelerating. Evaluate whether the existing fact is sufficient before adding more.
- **Sequence count as scalar** — consecutive-up/down already fires at 3+. Adding the count as a scalar is cheap. Low priority but free.

## Follow-ups

1. Update `wat/market/observer.wat` with the two-stage pipeline specification
2. Move calendar facts from Narrative-exclusive to standard in the encoder
3. Implement noise subspace on Observer struct
4. Add recency, distance-from-structure, relative-participation facts
5. Run k calibration (k=2,4,8) on 100k candles, measure prototype separation
6. Run 652k with the two-stage pipeline, compare observer accuracy before/after
7. Monitor eigenvalue stability to determine if decay is needed
