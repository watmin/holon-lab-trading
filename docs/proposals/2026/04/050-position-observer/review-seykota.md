# Review: Seykota / Verdict: REJECTED

## The problem is real

"Exit observer" is wrong. It names one action out of three. A
new trader reading the code would think this component wakes up
at the end of a trade. It doesn't. It decides trail width before
a position exists. The proposal correctly identifies the lie.

## "Position observer" is the wrong fix

On a trading desk, nobody says "position observer." That is not
a role. It is two nouns pushed together. A position is something
you have. An observer is something you are. "Position observer"
describes a relationship to an object, not a job.

The market observer gets away with it because "market" is an
environment. You observe the market the way you observe the
weather. But you do not observe a position. You manage it.

On a real desk, the person who decides when to get in, how much
room to give it, and when to get out is the **portfolio manager**
or, at a smaller scale, the **position manager**. The word is
"manager," not "observer." Managers make decisions. Observers
watch. This component makes decisions: deploy, hold, take residue.
It recommends distances. It learns from outcomes. That is
management, not observation.

But "position manager" collides with the enterprise vocabulary.
Manager means something else here. So we need to think harder.

## What the component actually does

I read the wat. Two reckoners: trail distance and stop distance.
A cascade: experienced reckoner, then accumulator, then default
crutch. It composes market thoughts with its own facts. It learns
from resolution. It decides distances that control the life of
the trade.

This is not observation. This is **sizing**. Trail width is a
sizing decision. Stop width is a sizing decision. On a desk,
the person who decides how tight or wide to set the stops is
making a risk-sizing call.

But in this architecture, the component does not pick position
size in dollars. The treasury does that. This component picks
*distance* -- how far the stop sits from the entry. That is
the geometry of the trade, not the capital allocation.

## The trading-native term

The closest desk role is the **risk clerk** or **risk officer** --
the person who sets the boundaries of each position. But "risk"
already has a branch in this architecture.

What this component does is set the **terms** of the trade. Entry
timing. Trail distance. Stop distance. The exit observer decides
the contract between the trader and the market: "I will stay in
as long as X; I will leave if Y." On a desk, the person drafting
those terms is the **structurer**.

But that imports jargon from derivatives desks where "structurer"
means something specific about product design. It would confuse
more than it clarifies.

## My recommendation

Keep searching. The proposal is right that "exit" is a lie. But
"position" is not the answer either. It is a Level 2 name -- it
is true but it mumbles. It says what the component looks at, not
what it does. And what it does is predict distances.

The honest name is **distance observer**. It observes market
conditions and predicts distances: trail width and stop width.
That is literally what the reckoners inside it learn. The
`recommended-distances` function is the interface. The
`observe-distances` function is the learning. Distances in,
distances out. The name should say that.

```
market observer    -- predicts direction
distance observer  -- predicts distances
broker             -- pairs direction with distances, grades the pair
```

The symmetry is real. Market observer predicts the market's
direction. Distance observer predicts the trade's distances.
Each name says exactly what the reckoner inside it learns.

If "distance observer" does not sit right, then I would accept
**position observer** as an improvement over "exit observer."
Any honest name is better than a lie. But the best name is the
one that says what the reckoners predict, and they predict
distances.
