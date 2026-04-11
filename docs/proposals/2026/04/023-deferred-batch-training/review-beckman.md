# Review — Proposal 023: Deferred Batch Training

**Reviewer:** Brian Beckman (invited)
**Date:** 2026-04-10

## 1. Is O(runner_length^2) acceptable?

Yes, but not because it is cheap — because it is correct. The optimal
distance at candle k depends on the suffix of prices from k onward.
That suffix has length (N - k). Summing over k gives N(N-1)/2.
For N = 500, that is 125k comparisons — trivial on modern hardware,
well under a millisecond. The quadratic is in the NUMBER OF CANDLES,
not in the dimensionality of the vectors. You would need runners
exceeding 50,000 candles before this costs even one second. Do not
subsample. The full suffix computation gives you the exact sufficient
statistic for each candle's hindsight-optimal distance. Subsampling
discards information you already paid to collect.

## 2. Does the information factoring preserve signal?

It does more than preserve it — it decomposes it along the correct
causal axis. The market observer receives a binary channel (Grace:
reversal detected) followed by a scalar channel (excursion magnitude).
The exit observer receives a graded vector channel (thought, optimal
distance) per candle. These are informationally independent: the market
signal is about WHEN to enter, the exit signal is about HOW LONG to
stay. The composed thought at candle k is the sufficient statistic for
the exit decision at k — it already encodes everything the exit needs
to know about context. The factoring is clean.

## 3. Is the second market teaching redundant?

No. The first teaching is a 1-bit signal: "a runner formed." The second
teaching carries the magnitude. In information-theoretic terms, the first
is the indicator function, the second is the random variable itself. You
cannot reconstruct the magnitude from the indicator. Use the excess
(excursion minus trail threshold), not the raw excursion — the trail
threshold is already known to the observer. The excess is the surprise.
Surprise is information.

## 4. Verdict

Accept. The architecture respects the causal structure of the problem:
fast binary feedback for detection, deferred batch feedback for
calibration, magnitude reinforcement for discrimination. The memory
cost (40MB per 500-candle runner) is bounded by the number of concurrent
runners and is reclaimable at closure. The quadratic computation is
negligible. The factoring is information-theoretically sound. Build it.

One note: Question 4 from the proposal (learning from Violence papers)
deserves a yes. The exit observer set distances that failed to protect.
That is a label — Violence with high weight teaches "this context
produces bad distances." The market observer being wrong does not
make the exit observation uninformative. Condition on the context,
not the outcome's cause.
