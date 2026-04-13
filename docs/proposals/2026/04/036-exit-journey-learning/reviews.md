# Proposal 036 — Designer Reviews

## Hickey

1. Per-candle grading is correct. A trade is a process, not an event.
2. **Drop the 50% threshold.** The error ratio IS the grade. Make it
   continuous. A binary cut on a continuous measurement destroys
   information — the same sin the proposal corrects at the trade level.
3. **Weight by residue, not time.** The residue carries the information.
   The timestamp doesn't.
4. Hindsight is honest. All supervised learning is hindsight.
5. **Drop is_grace entirely for the batch.** The exit target is continuous
   (distances). The binary label is a lossy projection. Send
   (thought, optimal, weight, residue). Let the reckoner learn the
   continuous mapping.

## Beckman

1. Per-candle is pointwise but a trade is a path. Consider cumulative
   error trajectory (integral of error ratio over trade life, normalized
   by duration). A functor from paths to grades, not product of points.
2. The error ratio is asymmetric — tight (kills trade) vs wide (bleeds
   value). Grade by residue consequences, not geometric distance.
3. The 50% threshold is arbitrary. Use the running MEDIAN of observed
   errors. Guarantees balanced Grace/Violence by construction.
4. Median-adaptive threshold fixes distribution balance AND the
   unreachable-target problem.
5. The hindsight gap is real but manageable if treated as conditional
   expectation E[optimal | thought].

## Agreement

- Per-candle grading: correct.
- 50% threshold: wrong.
- Residue-based grading: better than geometric.

## Divergence

- Hickey: drop is_grace entirely. Go continuous.
- Beckman: keep the binary but use median-adaptive threshold.

## Decision

Pending.
