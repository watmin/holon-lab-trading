# Review: Proposal 025 — Rich Hickey

**Verdict:** ACCEPTED

## Assessment

This proposal fixes an information problem, not a design problem. The exit
observer is a function from thought-vector to distances. It learns by
observing (thought, optimal-distances, weight) triples. The only question
is: which events produce those triples? Currently: only Grace resolutions.
That is a selection bias baked into the training distribution. The reckoner
has no way to know it is being lied to by omission.

The fix is correct and minimal. `observe-distances` already exists and
already accepts any (composed, optimal, weight). The proposal does not
add a new interface. It adds callers. The function does not care about the
outcome — it cares about the thought and the hindsight value. Outcome is
already encoded in the weight. This is how it should work.

The principle — every resolution teaches every learned value — is sound
because `compute-optimal-distances` is a pure function over price history
and direction. It produces a valid answer whether the paper won or lost.
The answer is not "this paper was Grace therefore optimal trail is X." The
answer is "given this price history and direction, the optimal trail was X."
The outcome is irrelevant to the computation. The weight carries the
outcome's significance. The proposal correctly separates these concerns.

The near-zero default change is correct for a different reason. The current
defaults (0.015, 0.030) encode a prior. A prior is only useful when it
reflects genuine knowledge about the domain before any data arrives. These
values were not derived — they were guessed and then reinforced by
one-sided training. Near-zero symmetric defaults make no claim. The first
honest data replaces them. That is the right epistemic posture for a
bootstrap.

There is one subtlety worth naming. The `tick-papers` function in
broker.wat derives `approximate-optimal-distances` from MFE/MAE extremes,
not from full `compute-optimal-distances` replay. The Violence path in this
proposal uses `compute-optimal-distances` (the full simulation sweep over
20 candidates). These are not the same computation. Runner observations
also use the full sweep (via the deferred batch). So the exit observer
will be trained from two different approximations of "optimal." This is
not a reason to reject the proposal — the full sweep is strictly more
accurate, and the paper-derived approximation is already present for Grace
runners. But the inconsistency should be noted and the implications
understood. Both are honest given their available information.

## Concerns

**Weight semantics across outcomes (Question 1).** The current weight for
Grace uses excursion: how far the price moved in the right direction. For
Violence, the proposal uses stop_distance: how far the price moved against
the position before the stop fired. These are both amounts, but they
measure different things on different scales. Excursion is "how right was
this trade at its best." Stop-distance is "how wrong did this get before
we cut it." They are not symmetric quantities. A Grace paper with 3%
excursion carries weight=0.03. A Violence paper stopped at 1.5% distance
carries weight=0.015. The Violence observation is weighted half as much not
because it is less informative, but because the stop was closer. This could
systematically underweight Violence training relative to Grace. A more
principled weight for Violence might be the absolute return at resolution
(the loss), parallel to excursion being the gain. But this is not a
blocking concern — the direction of the fix is correct regardless of the
exact weight normalization.

**Bootstrap paper avalanche (Question 2).** With near-zero defaults
(0.0001), any price movement at all crosses the trail. In a 5-minute BTC
candle, a 0.01% move is routine. Every paper resolves on the first tick.
With N market observers × M exit observers brokers, and candles arriving
continuously, the first recalibration interval will process an enormous
number of paper resolutions. This is not a correctness problem — the
resolutions are honest. It is a throughput question. The current bench
shows 251/s stable at 10k candles. The bootstrap phase will have a higher
resolution rate, which means more propagation work per candle. The cost
is bounded per candle (bounded by the number of open papers, which is
bounded by the VecDeque cap), so the answer to Question 2 is yes, it is
bounded. But the constant factor in the bootstrap phase may be larger than
in steady state. Worth measuring, not worth blocking on.

**Scalar accumulator bias (Question 3).** The scalar accumulator in
broker.wat already separates Grace and Violence into distinct vector
accumulators (`grace-acc`, `violence-acc`). The `extract-scalar` function
then sweeps candidates and returns the one closest to the Grace prototype.
So the scalar accumulator already receives both outcomes through
`propagate()` — `observe-scalar` is called for every `propagate` call,
which already happens for both Grace and Violence resolutions. The scalar
accumulator is not Grace-only. Question 3 is already answered by the
existing code. This does not need to change.

## On the questions

**Question 1: Should Violence weight be different from Grace?**

Yes, they should be on the same conceptual scale. Excursion and
stop-distance are both prices, both fractions of entry, but they measure
different outcomes of a trade. The proposal uses them as-is because they
are both available and both non-zero. This is pragmatic and acceptable for
a first implementation. If the learned distances show systematic bias after
both sides train, revisit the weight normalization. For now: ship it, measure
it.

**Question 2: Is the propagation cost bounded with near-zero defaults?**

Yes. Papers are held in a VecDeque with a cap. The number of resolutions per
candle is at most cap × N × M. That is a constant determined at construction.
The bootstrap phase does not create unbounded work. The cost per candle rises
during bootstrap and returns to steady state as defaults are replaced by
learned values. The bound exists. Trust it.

**Question 3: Should scalar accumulators receive Violence observations?**

They already do. `propagate()` in broker.wat calls `observe-scalar` for
every resolution — Grace and Violence alike. The scalar accumulator's
`observe-scalar` dispatches to `grace-acc` or `violence-acc` based on
outcome. The extract function reads from `grace-acc` to find the closest
value. Both sides contribute to the structure from which the answer is
drawn. No change needed here.
