# Resolution: Proposal 037 — Journey Threshold Mechanism

**Decision: APPROVED with both conditions.**

## What we accept

1. **EMA of error ratios.** Per-broker. A fold accumulator on the
   broker, not a mutable place. Threads through the candle loop
   as a value. Alpha = 0.01. Both designers agreed.

2. **Seed from first observation.** Beckman's recommendation. One
   branch (`if count == 0`). Zero cold-start bias. The EMA is
   grounded in measurement from the first candle.

3. **The threshold is a projection.** A sign function on
   `error - ema_error`. Mechanical. Not a judgment. The word
   "Grace" in the rolling window is a label, not a verdict. The
   continuous signal enters through the weight (residue). The
   binary label exists only because the rolling window needs it.

4. **Per-broker isolation.** The accumulator belongs to the unit
   it measures. No contamination between brokers.

5. **Fixed alpha.** 0.01. Learning alpha from the signal it
   smooths is circular. Regime sensitivity belongs in the
   vocabulary, not the grading mechanism.

## Implementation

On the Broker struct, add:
```rust
pub journey_ema: f64,      // EMA of error ratios. Fold accumulator.
pub journey_count: usize,  // observation count for seeding
```

In the deferred batch loop:
```rust
for (thought, optimal, actual_distances, excursion) in batch {
    let trail_err = (actual.trail - optimal.trail).abs()
        / optimal.trail.max(0.0001);
    let stop_err = (actual.stop - optimal.stop).abs()
        / optimal.stop.max(0.0001);
    let error = (trail_err + stop_err) / 2.0;

    // Seed or update
    if broker.journey_count == 0 {
        broker.journey_ema = error;
    } else {
        broker.journey_ema = (1.0 - 0.01) * broker.journey_ema + 0.01 * error;
    }
    broker.journey_count += 1;

    // Projection: sign(error - ema)
    let is_grace = error < broker.journey_ema;

    exit_learn_tx.send(ExitLearn {
        exit_thought: thought,
        optimal,
        weight: excursion,     // residue-based
        is_grace,
        residue: excursion,
    });
}
```

## What we reject

- True running median (different algebraic species — Beckman)
- Learned alpha (circular — both designers)
- 0.5 initial seed (replaced by first observation — Beckman)
- Per-exit threshold (violates isolation — both designers)

## Dependencies

- Proposal 036 (approved) — per-candle journey grading
- The batch entries need access to ACTUAL distances per candle.
  The RunnerHistory already stores `distances: Vec<Distances>`.
  The `compute_exit_batch` function needs to return the actual
  distances alongside the optimal distances.
