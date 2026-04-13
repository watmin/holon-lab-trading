# Review: Hickey / Verdict: CONDITIONAL

## The diagnosis is correct

"Exit observer" is a bad name. It names one phase of a three-phase
lifecycle. The proposal's analysis of WHY it lies is precise. A
programmer who reads "exit observer" builds a wrong mental model.
This should be fixed.

## The proposed name is wrong

"Position observer" does not communicate what this component does.
It communicates what it thinks ABOUT. There is a difference.

The market observer observes the market. What does it DO? It predicts
direction. The name "market observer" works because "market" is the
input and the observer pattern implies prediction. The thing being
observed IS the thing being predicted about.

But "position observer" breaks this. A position is a concrete thing
you hold — a quantity of an asset at a price. "Observes the position"
suggests it watches an existing position. It suggests monitoring. It
suggests a dashboard. It does not suggest that the component DECIDES
whether to enter, or PREDICTS how far to set stops.

The proposal says: "A position is the lifecycle object. You open it,
hold it, close it." But the component doesn't observe a position. It
doesn't even receive a position as input. It receives a composed
thought vector and returns distances. Before any position exists, it
is already working — it recommends distances that the broker uses
to CREATE the position.

The component predicts distances for something that does not yet
exist. "Position observer" implies it watches something that does.

## The deeper problem

The proposal renames to match the FUTURE component (after 044-049
land), not the CURRENT one. Today, `exit-observer.wat` has two
reckoners, both for distances. It has no phase awareness, no entry
decision, no hold decision. It has `recommended-distances` and
`observe-distances`. That is its entire interface.

The name should fit what the thing IS, not what it will become.
Names for future things are lies told early.

## What the component actually does

It estimates distances. Trail distance. Stop distance. It learns
from resolved trades what distances would have been optimal. It has
a cascade: reckoner prediction, then scalar accumulator fallback,
then default. Its entire job is: given this thought, how wide should
the stops be?

After 044-049, it will also think about phases and pivots. Then it
will be a richer component. But even then, "distances" remains the
core output — the thing the broker consumes, the thing the treasury
uses to fund.

## What I would call it

**Distance observer.**

It observes distances. It predicts distances. It learns distances.
The market observer predicts direction. The distance observer predicts
distance. The symmetry is exact, and it names the OUTPUT — the thing
other components consume.

When 044-049 land and it gains phase awareness, the phase vocabulary
becomes an input to the distance prediction. The output is still
distances. The name still holds.

Rejected:

- **sizing observer** — distances are not sizes. Sizes are capital.
  The treasury sizes. The distance observer measures how far.
- **risk observer** — risk is a judgment. Distances are measurements.
  The broker judges risk through Grace/Violence. The distance observer
  provides the measurements that make risk judgment possible.

## The rename list

The proposal's mechanical rename list is thorough. But `ExitLens`
becoming `PositionLens` is wrong regardless of the name. The lens
selects which vocabulary the observer thinks with. If the observer
becomes a distance observer, the lens is `DistanceLens`. Same
pattern: `DistanceLearn`, `DistanceSlot`, `distance_thought`,
`distance_batch`.

## Condition

Rename, yes. The gaze finding is valid. But choose a name that says
what the component DOES (predicts distances), not what it thinks
ABOUT (the position). "Position observer" is better than "exit
observer" — it is less of a lie — but it is still imprecise. A
good name is the cheapest documentation. Do not spend it on a word
that merely gestures in the right direction.

Consider "distance observer." If the datamancer has reasons to reject
it, I want to hear them. But the bar is: does the name tell a new
reader what the component produces? "Position" does not. "Distance"
does.
