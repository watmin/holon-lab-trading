# Review: Seykota

Verdict: APPROVED

## General Assessment

This proposal replaces a broken mechanism (distance-based exits that drift
and stack) with an economic mechanism (interest as carrying cost) that
produces the behavior every trend follower wants: ride winners, cut losers.
The interest doesn't cut losers by decree. It lets them bleed out from the
cost of being wrong. That is the correct mechanism. A stop loss is a human
imposing a price level. Interest is the market imposing a time cost. Time
cost is more honest than price levels.

The phase-based entry (three consecutive higher lows / lower highs) is trend
identification. Not prediction. Identification. You see the structure forming
and you get on. That is what trend following is. The 44% active / 56% idle
split is healthy. The market doesn't always trend. A system that sits idle
more than half the time is a system that respects that fact.

The three-condition exit is the most important part. It requires: the
structure is breaking (phase), the direction is turning (market observer),
AND the math works (residue covers fees). All three. This prevents premature
exits on noise. A dip during a trend doesn't trigger exit because the market
observer still says Up. A turn during a trend doesn't trigger exit if you
can't cover fees. You only leave when the trend is over AND you can leave
profitably. That lets winners run.

The runner selection is natural. At candle 200 with 30x residue-to-interest,
the carrying cost is invisible. That is a trend being ridden. The interest
killed the trades that weren't trends. The survivors are trends. Natural
selection through economics. This is what position sizing and risk management
are supposed to produce.

## Answers to the 10 Questions

**1. The lending rate.**

ATR-proportional. Fixed rates ignore volatility regimes. A fixed rate that
works in a 2% daily range will be too loose in a 0.5% range and too tight
in a 5% range. The rate should breathe with the market. One parameter: the
rate as a fraction of ATR per candle. Let the data discover the fraction.
Start at something small and observe what survival rates emerge.

**2. Entry frequency.**

Let the brokers self-gate from anxiety. One entry per candle is permitted
by the architecture. The interest penalizes excessive entry. A broker that
enters every candle during a 53-candle window will have 53 positions accruing
interest. Most will die. The broker that enters selectively -- at structure
confirmation points -- will have fewer positions, more of which survive. The
interest IS the gate. Do not add a treasury limit. Let the economics teach
restraint.

**3. The reckoner's new question.**

Discrete. "Exit or hold at this trigger?" is the correct framing. "How much
longer should I hold?" is a continuous prediction about the future -- exactly
the kind of prediction that broke the distance reckoner. The market will tell
you when to leave. The reckoner's job is to recognize the moment, not predict
the duration. Discrete is what the system is good at. Stay with strength.

**4. Treasury reclaim.**

Automatic. When the interest exceeds position value, the trade is dead. Giving
the broker "one more transition" is giving a losing trade one more chance. That
is the emotional trap every trend follower must avoid. The math says it's over.
It's over. Violence is automatic. No appeals.

**5. The residue threshold.**

Let the reckoner learn what "worth it" looks like. A minimum threshold is a
parameter. Parameters are opinions. The reckoner sees the anxiety atoms --
residue-vs-interest, unrealized-residue, candles-since-entry. It will learn
that exiting with 0.1% residue after 200 candles of interest is not worth it.
It will learn that exiting with 3% residue after 10 candles is worth it. The
shapes are different. The reckoner can distinguish them. Do not add a threshold.
Let the learning discover the economics.

**6. Both sides simultaneously.**

Yes. Both sides. The market does not trend in one direction forever. A broker
can hold longs from a prior buy window while entering shorts in a new sell
window. The old longs will evaluate at the next valley. The new shorts will
evaluate at the next peak. The treasury lends to both sides. The phase labeler's
symmetry (2,891 buy vs 2,843 sell) shows the market gives both directions roughly
equally. Restricting to one direction at a time would miss the transition trades
where the old trend is dying and the new trend is being born.

**7. The interest as thought.**

The four anxiety atoms are correct. interest-accrued (how much has this cost me),
residue-vs-interest (am I winning or losing the race), candles-since-entry (how
long have I been committed), unrealized-residue (what would I take home now).
One addition: the rate of change of residue-vs-interest over the last N candles.
Is the race getting better or worse? A position with 2.3x residue-vs-interest
that was 3.1x five candles ago is deteriorating. A position with 2.3x that was
1.5x five candles ago is strengthening. The trajectory matters as much as the
current state. That is momentum applied to the position itself.

**8. The denomination.**

Per-candle twist is the right granularity because candles are the heartbeat.
The rate should breathe with volatility. ATR-proportional as stated in Q1.
A fixed rate in a volatile regime is too cheap -- trades survive that shouldn't.
A fixed rate in a quiet regime is too expensive -- trades die that should live.
The rate must reflect what the market is actually doing.

**9. Rebalancing risk.**

The phase labeler's symmetry handles this in aggregate. Over 652K candles,
buy windows and sell windows are nearly equal. But locally, the treasury
can become imbalanced. Set a maximum directional exposure as a percentage
of total portfolio. Not a hard wall -- a graduated rate increase. The more
imbalanced the treasury becomes, the higher the rate for the overweight
direction. This is natural. When everyone wants to borrow USDC to go long,
USDC becomes expensive. The rate for longs rises. The rate for shorts falls.
Self-correcting through economics, not rules.

**10. Paper erosion as the only gate.**

Sufficient. The survival rate IS the edge. A broker whose papers survive
the interest at 70% has demonstrated that it can identify trends that outrun
carrying cost. An EV gate is a derived statistic from the same data. The
survival rate is simpler, harder to game, and directly measures what matters:
can this broker's trades outrun the cost of holding them? One gate. One
metric. One question. That is clean.

## Summary

The proposal replaces parameters with economics. Distance triggers with
carrying cost. Continuous predictions with discrete decisions. Stacking
papers with natural death. Every replacement moves toward the same principle:
let the market decide, not the model. The interest mechanism is a filter
that selects for exactly what a trend follower wants -- trades that move
far and fast. Everything else dies from the cost of standing still.

The system this produces will ride winners (the interest becomes invisible
on runners), cut losers (the interest kills drifters), and sit idle when
there is no trend (56% of the time). Those are the three behaviors that
make trend following work.

Build it.
