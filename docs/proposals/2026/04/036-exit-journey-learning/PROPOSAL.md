# Proposal 036 — Exit Journey Learning

**Scope:** userland

## The current state

The exit observer manages running trades. It proposes trail and stop
distances every candle via continuous reckoners. The broker registers
papers and resolves them. When a paper resolves, the broker sends
learn signals to the exit observer:

1. **Immediate signal:** one observation per resolution.
   `is_grace = resolution.outcome == Outcome::Grace`. Honest.

2. **Deferred batch:** one observation per candle of the runner's life.
   All marked `is_grace: true`. The runner succeeded (trail crossed),
   so every candle along the way is labeled Grace.

The reckoners learn from both signals. The exit observer's rolling
`grace_rate` window reflects the label distribution.

## The problem

The deferred batch marks every candle of every runner as Grace. A
runner that lived 50 candles generates 50 Grace observations. A
Violence paper generates 1 Violence observation. The Grace count
dominates by volume.

Evidence from 10k candles:
```
volatility:  grace_rate=0.93  — 93% Grace
timing:      grace_rate=0.92  — 92% Grace
structure:   grace_rate=0.0   — 0% Grace (dead — no runners)
generalist:  grace_rate=0.87  — 87% Grace
```

The exit observer cannot distinguish skill from luck. A runner that
nearly hit the stop 30 times is labeled identically to one that
cruised to the trail. The journey isn't graded — only the destination.

## The proposed change

Grade each candle of the runner's life by management quality. The
simulation already computes hindsight-optimal distances at each candle
via `compute_optimal_distances`. The actual distances are what the
exit observer proposed. The gap between actual and optimal IS the
grade.

The deferred batch sends `(thought, optimal_distances, weight)` per
candle. The `is_grace` label reflects management quality, not trade
outcome.

## The algebraic question

The reckoners already consume `(thought, label, weight)` observations.
The proposed change modifies the LABELS, not the algebra. The
bundle/bind/cosine primitives are unchanged. The journal accumulation
is unchanged. The continuous reckoner query is unchanged.

The change is in the information fed to the reckoner. The reckoner
composes the same way. The input is more honest.

## The simplicity question

The current model is simple: runners are Grace, stops are Violence.
One bit per trade.

The proposed model is more complex: each candle is graded against
hindsight-optimal distances. The grade depends on the gap.

But the current model is a lie — it's simple because it destroys
information. The proposed model is complex because it preserves
information. Preserving information that the reckoner needs is
not complecting — it's feeding.

The open question: should the grade be binary (Grace/Violence per
candle) or continuous (the error ratio itself)?

## Questions for designers

1. Should the per-candle grade be binary (Grace/Violence with a
   threshold) or continuous (the error ratio as a weight)?

2. If binary: what determines the threshold? A fixed value (50%)?
   The running median of observed errors? Something else?

3. Should the grade consider the CONSEQUENCE (residue produced) or
   the GEOMETRY (distance from optimal)? A tight stop that kills
   has different consequences than a wide trail that bleeds.

4. Should the batch weight be uniform, temporal (later candles weigh
   more), or residue-based (candles with more at stake weigh more)?

5. Is there a risk that hindsight-optimal distances create an
   unreachable target? The exit observer can't know the future.
   Does grading against a future-informed optimal create a
   distribution the reckoner can never match?

6. A trade is a path, not a bag of points. Does per-candle grading
   miss correlated errors (e.g., consistently biased tight, surviving
   by luck of direction)?
