# Review: Seykota
Verdict: APPROVED

## General impression

This proposal describes what I have spent my entire career doing. The trend
is a sequence of higher highs and higher lows. When the sequence breaks,
the trend is over. The proposal encodes exactly this — pivot-low-trend,
pivot-high-trend, range compression, spacing. These are the atoms of
trend structure. The machine will see what every trend follower sees, but
it will see it algebraically rather than on a chart.

The portfolio model — scaling into a move across multiple pivots, each
entry with its own trailing stop, each evaluated independently — this is
how I trade. You don't enter once and pray. You probe. You add. The
market confirms with each higher low and you add more. The ones that
survive become runners. The runners produce the year's return. The ones
that die cost you little because the stops were tight when they were young.

The pivot series scalars are the heart of this proposal. Not the biography
atoms. Not the portfolio state. The SERIES. The relationship between
consecutive pivots. That is where the trend lives.

## Answers to the six questions

### 1. Pivot detection: conviction or its own mechanism?

Conviction is the right trigger. A pivot is a moment the market speaks
loudly enough to warrant evaluation. The market observer's anomaly score
already measures this — it is the machine's version of "the tape is
talking." Do not build a separate mechanism. The conviction threshold IS
the pivot detector. If you want, let the threshold be per-broker (each
broker has its own sensitivity to what counts as a pivot). But the
mechanism is conviction. Nothing else.

One caution: ensure the threshold produces pivots at a reasonable frequency.
Too many pivots and you are scalping. Too few and you miss the structure.
The 10-pivot memory implies you want roughly 10–30 pivots per meaningful
move. If conviction fires every 5 candles, that is too often. If it fires
every 500, the biography is empty. Let the reckoner learn the threshold
from Grace/Violence outcomes. The machine will find the right sensitivity.

### 2. Pivot memory size: 10? 20? Discovered or fixed?

Fixed at 10. Not because 10 is optimal, but because fixed is correct.
The market does not care about your 47th pivot ago. 10 gives you the
recent structure — 3–5 swings of higher highs and higher lows, which is
exactly the trend's signature. If you need 20, something else is wrong.

I would go further: the pivot series scalars only use 2 consecutive
pivots (last vs previous). The memory of 10 is for the portfolio biography
atoms (regression, regularity, spacing). 10 is plenty for regression.
Do not discover this. Fix it. Move on. The interesting question is what
the reckoner DOES with the atoms, not how many pivots you remember.

### 3. Trade biography on the chain: pivot memory or computed atoms only?

Only computed atoms travel. The exit observer does not need 10 raw
pivot records. It needs the 3 new atoms (pivots-since-entry,
pivots-survived, entry-vs-pivot-avg) and the 6 pivot series scalars.
These are the distilled facts. The raw pivot records stay in the broker.
The broker computes. The atoms flow. This is the right separation.

Sending raw pivot records would be like sending the chart to the exit
observer. The exit observer does not read charts. It reads atoms. Keep
it that way.

### 4. Portfolio biography scope: compose with market thought or separate?

Compose. The broker's reckoner already bundles market thought with
trade accountability. The portfolio biography is another set of atoms
in the same bundle. The whole point of VSA is that bundling IS
composition — the reckoner sees the superposition of market, trade
accountability, and portfolio state simultaneously. Separating them
would require separate reckoners, which contradicts the architecture.

The portfolio atoms tell the reckoner context: "I already have 4 trades
running and my heat is high." The market atoms tell it opportunity:
"This pivot looks like accumulation." The reckoner resolves the tension.
That is its job. Bundle them.

### 5. Entry decisions: hard cap or learned?

The reckoner learns. This is the most important answer I can give.

Do NOT put a hard cap on concurrent trades. The portfolio-heat atom
and active-trade-count atom already tell the reckoner the state. If the
reckoner has seen that entering a 5th trade during high heat leads to
Violence, it will learn not to. If entering a 5th trade during low heat
(because the first 4 are all deep runners with wide trails) leads to
Grace, it will learn to enter.

Hard caps are the enemy of trend following. In a strong trend, you WANT
to scale in aggressively. In a choppy market, you want to be cautious.
The portfolio biography atoms give the reckoner the information to
distinguish these cases. Trust the reckoner. If it fails, the biography
atoms are insufficient — add more atoms. Do not add rules.

One practical constraint: the treasury already limits total capital
deployed. That is the structural cap. The broker's reckoner manages its
own portfolio within whatever capital the treasury allocates. Two
constraints, two levels, both learned.

### 6. Simultaneous buy/sell across brokers: independent or netted?

Independent. Always independent.

The treasury funds proposals based on each broker's demonstrated edge.
Broker A exits with 5.5% residue — that capital returns. Broker B enters
fresh — the treasury evaluates Broker B's curve and funds accordingly.
The two events are causally unrelated. They happen to coincide at the
same pivot. Netting them would couple brokers that should be independent.

From a capital perspective: when Broker A's trade settles, its reserved
capital returns to available. When Broker B proposes, the treasury funds
from available capital. The settlement happens before the funding (step 1
before step 4 in the four-step loop). This is already correct. The
capital recycles naturally through the settlement/funding cycle. No
netting mechanism needed.

The beauty is that the treasury sees the net effect anyway — capital out
from A, capital in from B. If A released more than B requests, available
capital grows. If B requests more, the treasury decides whether B has
earned enough edge to fund it. This IS the netting, but through the
existing mechanism of edge-based funding, not through explicit coupling.

## What I like most

The pivot series scalars. Specifically:

- **pivot-low-trend**: Higher lows are the heartbeat of an uptrend. When
  this goes negative, the trend is broken. This single atom, if the
  reckoner learns it, is worth the entire proposal.
- **pivot-range-trend**: Range compression precedes breakouts AND
  breakdowns. Seeing it as a scalar means the reckoner can learn "tight
  range after rising lows = continuation" vs "tight range after flat
  highs = exhaustion."
- **pivot-spacing-trend**: Accelerating pivots mean urgency.
  Decelerating pivots mean the move is maturing. This is the tempo of
  the trend.

These four scalars (low-trend, high-trend, range-trend, spacing-trend)
are the minimal sufficient description of trend structure. I have been
trading on these relationships for decades. I drew them on charts. You
encoded them in vectors. Same thing.

## What to watch

The proposal is clean. The risk is implementation bloat. 22 brokers, each
with N active trades, each trade evaluated at each pivot — this is
combinatorial. Keep the per-trade evaluation cheap. The exit observer
already runs per trade. The pivot series atoms are cheap to compute
(2 divisions per atom). The portfolio biography is one computation per
broker per candle. This should scale.

The other risk: pivot frequency tuning. If conviction thresholds are
wrong, you get either too many pivots (noise) or too few (amnesia). The
proposal correctly says conviction is already learned. Trust that. But
monitor it. If a broker fires 200 pivots in 100k candles, it is not
trend following. If it fires 5, it is asleep.

## The trend follower's summary

The trend is a sequence of pivots. The biography is the trader's
relationship to that sequence. The proposal captures both. The atoms are
minimal. The machinery is unchanged. The vocabulary grows in exactly the
right direction — toward the structure of the move, not toward prediction
of the next candle.

Ride the winners. Cut the losers. Let the pivot biography tell you which
is which.
