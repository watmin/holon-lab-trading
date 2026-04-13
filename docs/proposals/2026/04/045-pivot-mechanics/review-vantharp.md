# Review: Van Tharp / Verdict: CONDITIONAL

Conditional on two changes. The mechanics are sound. The
ownership is clear. Two of the four parameters need adjustment
before this becomes a specification.

## Question 1: The 80th percentile threshold

Wrong question. The right question is: should the threshold
be fixed or discovered? The answer is discovered.

The 80th percentile is a reasonable starting point for a
single observer. But the proposal places pivot detection on
each exit observer independently. Different exit observers
have different concerns. A momentum-paired exit needs FEWER,
STRONGER pivots — maybe the 90th percentile. A structure-paired
exit needs MORE, WEAKER pivots — maybe the 70th. The pivot
threshold IS an expression of trading style. Fixing it at 80
across all exits is the same mistake as fixing a stop-loss at
2% across all instruments.

The mechanism is correct — percentile-based thresholds adapt
to the conviction distribution, which adapts to the market.
A trending market raises all convictions, the threshold rises
with them, pivots stay rare. Choppy markets lower all
convictions, the threshold drops, pivots stay attainable. This
is exactly right. The distribution breathes. The threshold
breathes with it.

But the LEVEL of the percentile should be a parameter per
exit observer, not a global constant. Start them all at 80.
Let the reckoner learn which observers perform better at
different levels. This is not optimization — this is
acknowledging that different strategies need different
sensitivity.

For initial implementation: 80 is fine. It produces roughly
1 pivot per 5 candles (25 minutes at 5-minute bars). That is
frequent enough for accumulation, rare enough to mean
something. Ship it at 80. Plan for per-observer discovery
later.

**Verdict on percentile vs fixed threshold:** The percentile
approach is categorically superior to a fixed numerical
threshold. A fixed threshold (conviction > 0.07, say) is
meaningless across regime changes. The conviction scale itself
changes. A percentile is regime-invariant — it always means
"unusual relative to recent experience." This is correct.
Do not change it.

## Question 2: The conviction window N=500

Too long. Use 200.

The statistical argument: a percentile estimate from a sample
of size N has standard error proportional to 1/sqrt(N). At
N=200, the 80th percentile has standard error roughly 2.8%.
At N=500, roughly 1.8%. The extra precision is not worth the
cost.

The cost: 500 candles is 41.7 hours. In a market that pivots
every few hours, this means the conviction history straddles
multiple regimes. A 41-hour window includes Asian session,
European session, US session, weekend (if applicable), news
events, and quiet periods. The threshold becomes an average
of all these regimes. It stops being "unusual relative to
NOW" and becomes "unusual relative to the last two days."

200 candles is 16.7 hours. Roughly one full trading day. The
threshold reflects the current regime, not the average of
three. When the market shifts from trending to choppy, the
window adapts in hours, not days.

The matching argument: should this match the market observer's
recalibration interval? No. The market observer recalibrates
its noise subspace — a structural operation. The conviction
window is a distributional measurement. They serve different
purposes. Coupling them creates a dependency that constrains
both. Keep them independent.

The minimum viable window: below 100, the 80th percentile
becomes unstable. Above 300, it becomes sluggish. 200 is the
sweet spot — statistically stable, regime-responsive.

**Condition 1: Change N from 500 to 200.**

## Question 3: Direction changes within a pivot

Two pivots. Always.

A conviction spike where direction is Up, followed immediately
by a conviction spike where direction is Down, is not one
event. It is two events. The market said "up" and then said
"down." The exit observer needs to see BOTH — because the
trade biography is different for each.

Consider: the exit observer has an active long trade. A pivot
fires with direction Up — the trade is confirmed, the trail
widens. Two candles later, conviction is still high but
direction has flipped to Down. If this is the same pivot,
the exit observer sees "pivot, direction changed" — ambiguous.
If these are two pivots, the exit observer sees "Up pivot
(confirm) followed by Down pivot (threat)" — actionable.

The direction change forces a new period even if conviction
stays above threshold. Close the current pivot, record it.
Open a new pivot with the new direction. The conviction
history is unaffected — both candles are above threshold.
The state machine needs one additional transition:

```
Currently in pivot + conviction above threshold + direction changed
  → close current pivot, open new pivot with new direction
```

This is not flickering. Flickering is conviction bouncing
above and below threshold on consecutive candles. Direction
change at sustained high conviction is a REAL market event.
The machine should see it as two distinct periods.

**Condition 2: Direction change during a pivot forces a new
pivot period.**

## Question 4: Gap minimum duration

No minimum. The single-candle gap is information.

Here is why. The proposal defines a gap as: conviction drops
below threshold. If conviction drops for one candle and then
rises again, that IS a one-candle gap. The question is: does
this happen often enough to cause harm?

In a properly calibrated window (N=200, 80th percentile), the
threshold is stable candle-to-candle. Flickering — rapid
alternation between pivot and gap — happens when the conviction
is right at the threshold boundary. This is a real condition.
The market IS ambiguous. The machine should encode the
ambiguity, not suppress it.

A minimum duration (say, 3 candles below threshold before
declaring a gap) introduces a different problem: it creates
a hidden state. For those 3 candles, the exit observer is in
a pivot that has already ended. It is lying to itself. The
trade biography says "still in a pivot" when the conviction
has already fallen. This is worse than flickering.

The Sequential encoding handles flickering naturally. A
sequence of (pivot-1, gap-1-candle, pivot-2, gap-1-candle,
pivot-3) encodes the ambiguity in geometry. The reckoner can
learn that rapid alternation predicts differently than clean
transitions. Do not filter the signal. Let the reckoner
learn from it.

If flickering becomes a practical problem — if it overwhelms
the pivot memory with tiny entries — the answer is to raise
the percentile threshold for that observer, not to add a
minimum duration. The percentile is the right dial. A minimum
duration is a second dial that fights the first.

**Verdict: No minimum gap duration. Ship without it. Monitor
the pivot memory fill rate. Adjust the percentile if needed.**

## The Ownership Question

The exit observer. The proposal has it right.

The argument for the broker is that the broker sees the
portfolio. True. But the broker's concern is accountability
— Grace and Violence. The broker does not ACT on pivots. The
broker evaluates the pairing. The exit observer ACTS — it
sets distances, it manages trails, it evaluates the trade
biography. The pivot is an exit management concept, not an
accountability concept.

The argument for a separate component is that pivot detection
is "market structure." But in this architecture, market
structure is what the MARKET observer produces. The market
observer produces conviction and direction. That IS market
structure. The exit observer takes that structure and asks
"is this unusual?" That is a private question — the exit
observer's threshold, the exit observer's history, the exit
observer's sensitivity. Different exits can disagree about
whether the same candle is a pivot. That IS the diversity.

A separate component would produce a single pivot signal for
all exits. That destroys the per-exit sensitivity that makes
the architecture work. One exit sees a pivot. Another does
not. Same candle. Different thresholds. Different biographies.
Both correct. A shared pivot detector cannot do this.

The portfolio biography atoms (active-trade-count, oldest-
trade-pivots, etc.) live on the broker because they describe
the broker's portfolio. But they are DERIVED from the exit's
pivot classification, not from an independent detection. The
exit tells the broker "this is a pivot for me." The broker
records the aggregate. This is values up. This is correct.

**Verdict: Exit observer owns pivot detection. No separate
component. The broker reads the exit's output. The portfolio
biography is derived, not detected.**

## Summary of conditions

1. Change conviction window from N=500 to N=200.
2. Direction change during a pivot forces a new pivot period.

Everything else is approved as designed. The percentile-based
threshold is the right mechanism. The exit observer is the
right owner. The state machine is clean. No minimum gap
duration.

Ship with these two changes and it becomes a specification.
