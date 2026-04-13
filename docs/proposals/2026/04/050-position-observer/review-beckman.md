# Review: Beckman / Verdict: CONDITIONAL

The proposal asks whether the name "position observer" correctly
names the functor currently called "exit observer." The answer
is: almost. The name is better than what it replaces, but it
carries a connotation that must be acknowledged.

## 1. What is the current functor?

Read the wat. `exit-observer.wat` defines a struct with:

- a lens (vocabulary selector),
- two continuous reckoners (trail distance, stop distance),
- default distances (crutches),
- an incremental bundle cache.

Its interface has three morphisms:

1. `recommended-distances`: (ExitObserver, Vector, Vec<ScalarAccumulator>, ScalarEncoder) -> (Distances, f64)
2. `observe-distances`: (ExitObserver, Vector, Distances, f64) -> ()
3. `experienced?`: ExitObserver -> bool

The input `Vector` is called `composed` -- the market thought
composed with exit-specific facts. The output is a pair of
distances. The learning input is hindsight-optimal distances.

This is a **state machine** (the reckoners accumulate experience)
whose query morphism maps composed thoughts to distance
predictions. It is a functor from the category of composed
thoughts (objects: vectors in R^d, morphisms: the learning
updates that transform the reckoner state) to the category of
distance pairs (objects: (trail, stop) in R^2).

## 2. What does "exit observer" name?

"Exit observer" names the **target** of the functor's query
morphism: the distances are used at exit time. This is like
naming a function after one of its call sites. If the function
is called from three places, the name describes one-third of
the usage. The proposal is correct that this is a lie.

## 3. What does "position observer" name?

"Position observer" names the **domain of concern**: the position
lifecycle. But look at what the functor *actually does today*.
It does not observe the position. It does not read position
state. It does not know whether a position is open, closed, or
hypothetical. It receives a composed thought vector and returns
distances. The broker manages the position (papers, triggers,
resolution). The exit observer predicts numbers.

The proposal's argument is aspirational, not descriptive. Lines
17-23 describe what the component *will do* after proposals
044-049 land:

- Decides ENTRY timing
- Decides HOLD
- Decides EXIT
- Thinks about trade state
- Thinks about the phase series
- Thinks about the pivot biography

Today's exit observer does exactly one thing: predict two
distances from a composed thought. It does not decide anything.
The broker decides. It does not observe trade state. The broker
composes the trade atoms (040) into the thought vector before
handing it to the exit observer. The exit observer sees geometry,
not positions.

## 4. The categorical question

The market observer is a functor:

```
MarketObserver: Candle -> (Direction, Edge)
```

(via the ThoughtEncoder and Reckoner, with noise stripping as a
natural transformation). Its name describes its source: candles,
which represent the market.

The proposed "position observer" would be a functor:

```
PositionObserver: ComposedThought -> Distances
```

Its source is not the position. Its source is a composed thought
vector -- a point in R^d that happens to encode some position
facts among other things. The position is one factor of the
product that produces the input. Naming the functor after one
factor of its domain's product is better than naming it after
one application of its codomain, but it is still a partial
truth.

The symmetry (market observer / position observer) is appealing
but does not hold strictly. The market observer really does
observe the market: its input is a candle, encoded via a lens
into a thought. The proposed position observer observes a
*composed thought* that contains market information, trade atoms,
and exit-specific vocabulary. It observes a vector. What
distinguishes it from the market observer is not what it observes
but what it predicts: distances rather than direction.

## 5. Does the symmetry hold after 044-049?

The proposal argues that after the phase labeler and pivot
biography land, the exit observer will genuinely think about
the position lifecycle. If the component gains:

- trade state awareness (excursion, retracement, age as
  first-class inputs it selects via its lens),
- phase series awareness (valley/transition/peak as vocabulary),
- entry/hold/exit decision vocabulary,

then "position observer" names the functor correctly. Its domain
will be the position lifecycle, its codomain will be lifecycle
decisions. The name will describe the morphism's role in the
diagram.

But that is the *future* functor, not the current one.

## 6. The condition

The name is correct for the component the architecture is
converging toward. It is premature for the component that exists
today. However: the proposal explicitly states this rename should
happen BEFORE the phase labeler and biography work, precisely so
the honest name is in place when the new vocabulary arrives.

This is a legitimate argument. Naming a component for what it is
*becoming*, when the becoming is already specified and approved
(049 is approved, 044-048 are specified), is forward declaration.
Category theory does this constantly: you declare a functor by
specifying its action on objects and morphisms, and only later
verify the functor laws. The declaration comes first.

The condition: **the phase labeler (049) and at least one
position-awareness vocabulary module must land within the same
development cycle as this rename.** If the rename ships and the
position-awareness work is deferred indefinitely, "position
observer" becomes the same kind of lie as "exit observer" -- a
name that describes something other than what the component does.

## 7. On the rejected alternatives

The proposal's rejections are sound. "Engagement observer" is
software jargon. "Lifecycle observer" names the pattern, not
the thing. "Trade observer" is ambiguous with the broker.
"Action observer" names verbs. "Stance observer" is invented.

I would add one more candidate to the rejection pile for
completeness: **"distance observer"** -- names what the functor
actually computes today. Rejected because it names the codomain,
not the role. After 044-049, distances will be one of several
outputs. Same defect as "exit observer," just moved to the other
end of the morphism.

## Summary

"Exit observer" is a Level 1 lie. "Position observer" is a
Level 0 truth for the component specified in the guide, and a
Level 1 aspiration for the component that exists in the wat
today. The symmetry with "market observer" holds *after* the
position-awareness work lands, not before. The rename is
justified as forward declaration, provided the declaration is
honored.

Approved, conditional on the phase labeler and position-
awareness vocabulary shipping in the same cycle as this rename.
If the rename ships alone, it is a different lie with better
aesthetics.
