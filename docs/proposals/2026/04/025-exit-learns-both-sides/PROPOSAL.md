# Proposal 025 — Exit Learns Both Sides

**Date:** 2026-04-11
**Author:** watmin + machine
**Status:** PROPOSED

## The imbalance

The exit observer has N continuous reckoners — one per learned
distance. Today N=2 (trail, stop). Each reckoner accumulates
observations: a thought vector, a scalar value (what the distance
SHOULD have been), and a weight.

The exit observer currently learns from:

1. **Runner resolutions** — Grace papers that became runners. The
   deferred batch training provides N observations per runner at
   closure. Each observation carries hindsight-optimal distances
   from the suffix-max simulation.

2. **Funded settlements** — trades the treasury backed. Both Grace
   and Violence. But the broker edge is 0.0 — no trades are funded.
   This path is dead.

The exit observer does NOT learn from:

3. **Market signals** — Violence papers (stop fired before trail).
   These carry `optimal_distances` from `compute_optimal_distances`.
   The simulation ran. The hindsight answer exists. The exit never
   sees it.

The result: 100% Grace training data. The exit's reckoners build
prototypes from one distribution. The discriminant has no contrast.
The distances converge on what maximizes Grace residue — tight
trails, wide stops — which produces more Grace, which trains more
tight trails. The feedback loop is one-sided.

The 10k run confirms: 186,603 papers. 99% Grace. The trail/stop
ratio is 2:1 across every paper. The exit learned the ratio that
produces Grace and reinforced it.

## The principle

Every resolution — Grace or Violence — teaches every learned value.

This is not specific to N=2 or to trail/stop. If the exit observer
had 5 reckoners (trail, stop, take-profit, runner-trail, patience),
the principle is the same: each resolution carries hindsight-optimal
values for ALL N distances. Each reckoner receives its own optimal
value from the same event.

The reckoner doesn't know Grace from Violence. It knows: this
thought, this optimal value, this weight. Grace carries large
weight (the market confirmed — excursion). Violence carries small
weight (the market rejected — stop distance). Both are honest
observations. Both shape the discriminant. The weight carries the
outcome.

The 2 in the matrix is the cardinality of the outcome space (Grace,
Violence). The N is the number of learned values. The principle is:
`outcomes × learned_values` — every cell filled. No empty rows.

## The fix in wat

```scheme
;; The exit observer's learning contract.
;; Every resolution teaches every learned value.

(define (teach-exit exit-observer thought optimal weight)
  (for-each (lambda (reckoner optimal-value)
    (observe reckoner thought optimal-value weight))
    (:reckoners exit-observer)
    (fields optimal)))

;; WHO calls teach-exit? Every resolution. Both sides.

;; Grace paper resolves (trail crossed):
(teach-exit exit-obs
  (:composed-thought grace-paper)
  (compute-optimal-distances (:price-history grace-paper)
                             (:direction grace-paper))
  (:excursion grace-paper))

;; Violence paper resolves (stop fired):
(teach-exit exit-obs
  (:composed-thought violence-paper)
  (compute-optimal-distances (:price-history violence-paper)
                             (:direction violence-paper))
  (:stop-distance violence-paper))

;; Runner closes (deferred batch — N observations per candle):
(for-each (lambda (candle-obs)
  (teach-exit exit-obs
    (:thought candle-obs)
    (:optimal candle-obs)
    (:weight candle-obs)))
  (:exit-batch runner))
```

## The defaults

The current defaults are poison: trail=0.015, stop=0.030. These
were identified as poison in the prior session. The exit observer
moved from 1.5% to 2.97% — it was learning them away. But the
2:1 ratio persists because the training data is 99% Grace.

Replace with near-zero symmetric defaults: trail=0.0001,
stop=0.0001. Near zero so the math works. Symmetric so the first
papers resolve on both sides quickly. The accumulators fill with
honest data from both outcomes. The learned values replace the
bootstrap within the first recalibration.

```scheme
;; Before:
(new-exit-observer lens dims recalib 0.015 0.030)

;; After:
(new-exit-observer lens dims recalib 0.0001 0.0001)
```

## What changes

1. **Market signals teach the exit observer.** Every market signal
   (Grace or Violence) calls `observe_distances` on the exit
   observer for that broker's exit index. The composed thought and
   optimal distances from simulation flow to all N reckoners.

2. **Defaults become near-zero symmetric.** The bootstrap produces
   fast, balanced paper resolutions. The learned values replace
   the bootstrap as experience accumulates.

## What doesn't change

- The deferred batch training (Proposal 023) — runners still
  provide N per-candle observations at closure.
- The reward cascade (Proposal 021) — three learners, three moments.
- The simulation functions — `compute_optimal_distances` is unchanged.
- The continuous reckoner internals — same K=10 bucketed accumulators.
- The cascade: reckoner → accumulator → default.

## Questions

1. Should the weight for Violence observations be different from
   Grace? Currently Grace uses excursion, Violence uses stop_distance.
   Both are amounts. But excursion is "how right" and stop_distance
   is "how wrong." Should they be on the same scale?

2. With near-zero defaults, papers resolve on the first candle (any
   price movement crosses 0.01%). This means hundreds of paper
   resolutions per candle in the bootstrap phase. Is the propagation
   cost bounded?

3. The scalar accumulators also learn from Grace only. Should they
   receive Violence observations too? Same principle — every learned
   value needs both sides.
