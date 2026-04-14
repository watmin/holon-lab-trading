# Review: Van Tharp

The measurement is honest. 34% single-candle phases. A phase
change every 3 candles. This is not a labeler producing structure
-- this is a labeler producing noise and calling it structure.

The builder is right to distrust this.

## The core problem

A phase is a statistical claim: "the market is doing THIS right
now." A claim needs enough data to be distinguishable from
randomness. One candle is not a claim. It is a single draw from
a distribution. You cannot characterize a distribution from one
sample.

The minimum sample for a learnable pattern depends on what the
downstream consumer needs to estimate. The reckoner needs to
see enough candles within a phase to build a vector that is
geometrically distinct from the vectors of other phases. In
hyperdimensional space, a bundle of 1 candle is just that candle.
A bundle of 5 candles starts to have a stable centroid. A bundle
of 10 has a reliable shape.

For position sizing specifically: I cannot size a trade based on
a phase that might not exist next candle. Position sizing requires
an expectation -- expected win rate times expected payoff. A
1-candle phase has no expectation. It has one observation.

## Question 1: Is 1.0 ATR the right smoothing?

No. The measurement proves it. 1.0 ATR at 5-minute resolution
means $10 on a $20 ATR day. A $10 move on BTC at 5 minutes is
routine noise. The half-smooth threshold of $5 for Peak/Valley
zones is absurd -- that is less than a single candle's range on
most days.

1.5 ATR is closer. But the real answer is that the multiplier
should be derived from the data, not from authority. Run the
labeler at 1.0, 1.5, 2.0, 2.5, and 3.0 ATR across the full
dataset. Measure the resulting phase duration distributions.
The right smoothing is the one where the median phase duration
is long enough for the reckoner to learn from -- at least 5
candles, ideally 8-12.

My expectation: 2.0 ATR will land in the right zone. At $20 ATR
that is a $40 threshold. A $40 move on 5-minute BTC is a real
structural event, not a wiggle. The half-smooth zone becomes
$20 -- roughly one full ATR -- which is a meaningful band.

## Question 2: Should the labeler have a minimum phase duration?

Yes. Absolutely yes. This is the most important change.

The minimum should be 5 candles. Here is the reasoning:

A phase with fewer than 5 candles does not have enough samples
for the downstream bundle to stabilize. At 4096 dimensions, a
bundle of N vectors has a signal-to-noise ratio proportional to
sqrt(N). At N=1 you have SNR=1 (no signal above noise). At N=5
you have SNR~2.2. At N=10 you have SNR~3.2. Five candles is the
minimum where the bundle is more signal than noise.

From a trading perspective: 5 candles at 5-minute bars is 25
minutes. That is the minimum duration for a "phase" to represent
a tradable condition. A momentum phase shorter than 25 minutes
is not actionable -- by the time you recognize it, size the
position, and enter, it is over.

Implementation: when the labeler detects a state change, it
should NOT immediately declare a new phase. It should mark the
change as "tentative" and only confirm it after 5 candles in the
new state. If the price reverts within 5 candles, the tentative
change is cancelled and the previous phase continues. This is
a confirmation window.

The confirmation window will dramatically reduce the 34%
single-candle problem. Most of those 1-candle phases are
exactly the noise that a confirmation window absorbs.

## Question 3: Is the architecture right?

The two-state machine (Rising/Falling) with derived labels is
fundamentally sound. Zigzag algorithms have a long history in
technical analysis and this is a streaming zigzag. The problem
is not the architecture. The problem is the parameters.

However, I would add one structural change: decouple the tracking
state transition from the label transition. Right now, when
`extreme - close > smoothing` fires, the tracking state flips
AND the close_phase/begin_phase fires on the same candle. The
tracking flip should be immediate (it is a mathematical fact
about the price). The label change should be delayed by the
confirmation window. This means the state machine has a third
implicit state: "tracking flipped but label not yet confirmed."

Do not build a multi-scale labeler. That is a different proposal.
Fix the single-scale labeler first. Multi-scale adds complexity
that hides whether the single scale is working. One scale,
correct parameters, confirmation window. Measure again. Then
decide if multi-scale is needed.

## Question 4: What does a good phase distribution look like?

Target distribution for 10k candles:

```
  1-2 candles:    < 5%   (only at genuine spike reversals)
  3-5 candles:    15-20%
  6-15 candles:   40-50% (the bulk -- this is where learning happens)
  16-30 candles:  20-25%
  30+:            5-10%
```

Phase changes per 1000 candles: 60-120. That is a change every
8-16 candles. Compare to the current 340 per 1000 (every 3
candles). The current labeler is 3-5x too sensitive.

The median phase duration should be 8-12 candles (40-60 minutes
at 5-minute bars). That is long enough for:
- The bundle to stabilize (sqrt(10) ~ 3.2 SNR)
- The reckoner to see the pattern develop
- A trader to recognize the condition and act on it
- The phase attributes (range, volume, move) to be meaningful

The mean will be higher than the median because some trends run
for 50-100 candles. That is correct -- a right-skewed distribution
with a fat tail on the long side reflects real market structure.

## Question 5: Should the Sequential encode ALL phases or only significant ones?

The Sequential should encode only confirmed phases. If the
confirmation window absorbs the 1-candle noise, then by
definition everything that reaches the Sequential is significant.

Do not add a separate filter between the labeler and the
Sequential. The labeler should produce clean output. If the
labeler's output needs filtering, the labeler is broken. Fix
the source, not the consumer.

The exception: the Sequential's capacity is bounded (20 records
in the history). If the phases are too short, the Sequential's
window covers less calendar time. At the current rate of 340
changes per 1000 candles, the 20-record history covers only
~60 candles (5 hours). At the target rate of 80 changes per
1000 candles, it covers ~250 candles (21 hours). That is the
difference between seeing one trading session and seeing a full
day. The reckoner needs the longer window.

## Question 6: Does the phase labeler belong at 1.0 ATR at all?

The labeler belongs at whatever scale produces learnable phases.
The scale is not 1.0 ATR -- the measurement proves this. But
ATR-based smoothing is correct in principle. It breathes with
the market. A fixed percentage would need recalibration across
different volatility regimes.

The 5-minute candle IS the right input. Do not aggregate to
hourly. The 5-minute candle is the resolution of the data and
the resolution of the trading decisions. Aggregating to hourly
throws away information that the reckoner might need. The
smoothing parameter is what controls the effective scale, not
the input resolution.

What needs to change is the multiplier. 2.0 ATR with a 5-candle
confirmation window. Measure the result. If the distribution
looks like my target above, the labeler is producing structure.
If not, try 2.5.

## Sizing implications

I want to be explicit about why this matters for position sizing.

My core principle: size positions based on the quality of the
edge, not the magnitude of the signal. The edge quality depends
on the sample size. A reckoner trained on 1-candle phases has
seen each "pattern" exactly once. There is no sample to estimate
edge from. A reckoner trained on 10-candle phases has seen each
pattern develop over 10 observations. The conviction score from
that reckoner means something.

The current system sizes based on reckoner conviction. If the
reckoner's conviction is built on noise, the sizing is built on
noise. Fix the input first. Then the sizing becomes meaningful.

## Recommended changes

1. Change smoothing from `1.0 * ATR` to `2.0 * ATR`
2. Add a 5-candle confirmation window before declaring a new phase
3. Run the full 652k candle dataset with both changes
4. Measure the resulting phase distribution
5. Verify the median phase duration is 8-12 candles
6. If median is below 8, increase to 2.5 ATR. If above 15, decrease to 1.75.

Do not change the architecture. Do not add multi-scale. Do not
filter at the Sequential. Fix the labeler's sensitivity. The
machine that consumes the phases is not broken. The phases are.
