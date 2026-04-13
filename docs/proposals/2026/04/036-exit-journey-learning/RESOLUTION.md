# Resolution: Proposal 036 — Exit Journey Learning

**Decision: APPROVED with Beckman's recommendations.**

## What we accept

1. **Continuous grading.** The error ratio (actual vs optimal distance)
   is the grade. No binary threshold. No is_grace for batch entries.
   The reckoner already handles continuous signals. Both designers
   agreed — don't quantize what we just recovered.

2. **Geometry, not consequence.** Grade the exit observer on what it
   controls — the distance from optimal. Not on system-wide residue
   consequence. Both designers agreed.

3. **Residue-based weights.** Weight each candle observation by the
   excursion at that candle — what's at stake. The residue IS the
   importance. It's measured, not asserted. Beckman's recommendation.
   Hickey preferred uniform but the residue carries information the
   timestamp doesn't.

4. **Path concern deferred.** Per-candle grading is strictly more
   honest than "all Grace." Ship it. Measure for correlated bias.
   Address sequence-awareness when evidence demands it. Both agreed.

5. **Hindsight is honest.** The optimal is the teacher. The reckoner
   learns E[optimal | thought]. The permanent gap between what the
   exit can predict and what hindsight reveals IS the noise floor.
   The noise subspace absorbs it.

## What we reject

- The 50% threshold (both designers rejected it)
- Temporal weighting (Hickey rejected, Beckman didn't advocate)
- Binary is_grace for batch entries (both rejected)

## Implementation

The deferred batch changes from:
```rust
ExitLearn { exit_thought, optimal, weight, is_grace: true, residue: weight }
```
to:
```rust
ExitLearn { exit_thought, optimal, weight: excursion_at_candle, is_grace: <continuous_grade>, residue: excursion_at_candle }
```

Where `continuous_grade` is the geometric error ratio:
```
error = (|actual_trail - optimal_trail| / optimal_trail
       + |actual_stop - optimal_stop| / optimal_stop) / 2
is_grace = error < median(observed_errors)  // Beckman's median for the rolling window
```

Wait — the designers said continuous, not binary. The `is_grace` field
is binary (bool). The continuous grade enters through the WEIGHT, not
the label. The label stays binary for the rolling window. The weight
carries the precision.

Revised: `is_grace` for batch uses Beckman's running median. The weight
is residue-based (excursion at candle). The reckoner's `observe_scalar`
receives the thought and the optimal distance with the residue weight.
The continuous signal enters through the weight dimension.

## Next steps

Implement. Measure. Compare grace_rate before and after. The target:
40-60% grace_rate on exit observers (balanced, not 90%).
