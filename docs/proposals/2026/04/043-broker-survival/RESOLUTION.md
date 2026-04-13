# Resolution: Proposal 043 — Broker Survival

**Decision: APPROVED. Three changes. Wyckoff wins Tension 2.**

Three designers reviewed. Three CONDITIONAL verdicts. One debate
round. Convergence on all three tensions.

## The three changes

### 1. Papers always register

The gate no longer controls paper registration. Every broker
registers papers every candle, regardless of EV. The gate
controls FUNDED PROPOSALS only.

Funding predicate: `resolved >= 200 && ev > 0.0`

One parameter (200). Papers are free. The learning loop never dies.

Unanimous: Seykota, Van Tharp, Wyckoff.

### 2. Per-broker journey grading with rolling percentile

Each broker maintains its own rolling window of the last N=200
error ratios. The threshold is the 50th percentile (median).
Replaces the shared EMA (alpha=0.01, seed=0.5).

Per-broker fixes the volume imbalance (4 survivors drowning 18
learners). Rolling percentile fixes the EMA's structural weakness
(infinite memory, convergence under volume).

Wyckoff: both together. Seykota and Van Tharp said sequence.
**Wyckoff wins. Implement both.**

### 3. Market observer learns from direction

The broker splits its learn signal at resolution time:

- **Market observer** receives Correct/Incorrect — did the
  predicted direction match the resolved direction?
- **Exit observer** receives Grace/Violence — did the trade
  outcome produce residue?

Same channel. Different label. The market observer's learning
objective is directional accuracy. The exit observer's learning
objective is trade management quality. These are independent
measurements and must have independent labels.

Unanimous after debate: Seykota held, Van Tharp conceded
("I was wrong"), Wyckoff held.

## What changes

1. `broker_program.rs`: remove gate check from paper registration.
   Add funding predicate (`resolved >= 200 && ev > 0.0`) to
   proposal logic only.
2. `broker.rs`: replace `journey_ema: f64` + `journey_count: usize`
   with a rolling window of N=200 error ratios. Threshold at median.
3. `broker_program.rs`: split learn signal. Market observer receives
   direction label. Exit observer receives trade outcome label.

## What doesn't change

- The pipeline. The observers. The treasury. The telemetry.
- The trade atoms (040). The market lenses (042).
- The three primitives. The architecture just is.
