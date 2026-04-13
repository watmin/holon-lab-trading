# Review: Van Tharp / Verdict: APPROVED (Option A)

## Question 1: Full history or recent records?

Recent records only. The exit needs enough pivot history to build
a Sequential thought — that means the last N completed periods,
not the full series back to candle zero.

Here is the reasoning. The exit's job is to set distances: trailing
stop, safety stop, take profit, runner trail. These are functions
of CURRENT market character, not market archaeology. A pivot from
6000 candles ago tells the exit nothing about where to place a stop
today. The regime has changed. The volatility has changed. The
conviction distribution has shifted.

What matters is: how long was the last pivot period? How strong?
How does it compare to the last few periods? That is a bounded
window — 20 records is generous, 10 is probably sufficient. The
chain can carry this as a bounded slice with zero guilt.

This answers in favor of Option A. If the exit only needs recent
records, the chain is a natural carrier. You do not need persistent
state on the exit thread to maintain deep history.

## Question 2: Stateless or stateful?

This is the interesting question, and I conceded too quickly in
the 045 debate. Let me be precise now.

The significance filter is **stateless at detection, stateful at
interpretation**.

Detection is stateless: a PivotRecord arrives with duration,
volume, conviction, direction. The filter applies a threshold —
"is this period long enough to matter? Is the conviction strong
enough?" That threshold is a pure function of the record's fields.
No memory required. A percentile cutoff over the arriving records.

But here is the thing people miss about position sizing: the
MEANING of a pivot changes with your equity curve. A significance
filter that treats all pivots equally regardless of recent
performance is leaving money on the table. In my R-multiple
framework, the size of a position depends on the recent distribution
of R-multiples. The significance of a pivot should similarly depend
on what pivots have meant FOR THIS EXIT recently.

However — and this is why I approve Option A — that learning does
not belong in the significance filter. It belongs in the exit's
reckoner. The reckoner already learns conviction-to-accuracy
curves. When a pivot-period thought enters the encoding, the
reckoner will learn whether that thought improves prediction or
not. The significance filter does not need to duplicate that
learning. It just needs to gate noise.

A rolling percentile over the arriving records is sufficient. That
is stateless in the meaningful sense: it does not accumulate hidden
state across the exit's lifetime. It reacts to the window of
records the chain carries. The reckoner handles the deeper learning.

## The statistical argument for Option A

The significance filter needs a sample to compute percentiles.
Where does that sample come from?

- **Option A:** The chain carries the last 20 records. The filter
  computes percentile over those 20 records. Sample size: 20.
  Adequate for a rank-based threshold. You do not need thousands
  of samples for an 80th percentile — you need rank ordering,
  and 20 records give you that with 4 records above threshold.

- **Option C:** The exit maintains its own tracker with N=500
  rolling window. More statistical power for the threshold
  computation. But: Beckman already flagged this as M redundant
  Mealy machines producing identical state. The extra precision
  of 500 vs 20 samples does not justify the factoring error.

- **Option B:** Adds pipes to solve a problem that does not exist.
  The join problem alone disqualifies it.

Twenty records is enough. The filter is a gate, not a model. It
separates signal from noise at the coarsest level. The reckoner
does the fine-grained learning. Spending 22 redundant state
machines to get a better percentile estimate for a coarse gate
is over-engineering.

## Position sizing implications

The pivot series directly affects position sizing through the
broker's Grace/Violence reckoner. Longer, higher-conviction pivot
periods should correlate with better R-multiples. The chain
carrying recent pivot records means the exit can encode this
information into its distance predictions, which flow into the
broker's proposals, which flow into treasury funding.

The key insight: the pivot data does not need its own sizing logic.
It feeds the existing machinery. The distances the exit produces
already determine the R-multiple structure of each trade. Better
distance prediction from pivot awareness means better R-multiples.
The existing funding mechanism (treasury funds proportionally to
edge) handles the rest.

Option A keeps the pivot data in the value stream where the
existing machinery can use it. No special treatment. No side
channels. The chain carries facts. The exit interprets them. The
reckoner learns from the results. That is the architecture.

## Summary

1. Recent records only. Bounded slice of 20. The chain carries it.
2. Stateless filter, stateful reckoner. The filter gates noise.
   The reckoner learns significance. Do not conflate the two.
3. Option A. Simplest. No new pipes. No redundant state machines.
   The statistical requirements of a coarse gate are met by 20
   records. The chain is the natural carrier.
