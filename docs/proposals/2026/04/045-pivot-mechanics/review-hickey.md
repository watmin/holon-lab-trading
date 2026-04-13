# Review: Hickey / Verdict: CONDITIONAL

## On Question 5: Who owns pivot detection?

The proposal is honest about this being an open question, which is
the right instinct. Let me articulate why.

The exit observer's job: given a trade's biography and the current
market, produce distances. Trail distance. Stop distance. That's
its concern.

Pivot detection's job: given a stream of conviction values, classify
candles into pivot periods and gap periods. That's market structure.

These are two different concerns. The proposal places them on the
same component because the exit observer "acts on pivots." But that's
the wrong reason to co-locate. A component should own what it IS,
not what it USES. The exit observer uses pivot classification. It
does not produce it. When you place detection AND consumption on
the same component, you've complected two things that change for
different reasons.

Consider what happens when you want to:

1. Give the broker access to pivot classification for portfolio
   biography atoms. The proposal already acknowledges this -- the
   broker needs to know "this is a pivot" to compute active-trade-count,
   oldest-trade-pivots, etc. If the exit owns detection, the broker
   must read the exit's state. Information flows sideways. Sideways
   flow is a smell.

2. Have two exit observers that share a market observer. Both need
   pivot classification from the same conviction stream. Do they
   each maintain their own conviction history? Now you have two
   copies of the same rolling window, fed by the same data, producing
   the same classification. Duplication that arises from misplacement.

3. Test pivot detection independently. You can't. It's wired into
   exit observer state. You'd have to construct an exit observer
   just to test whether your percentile threshold works.

The broker doesn't own it either, for the same structural reason.
The broker's concern is accountability -- does this pairing produce
Grace? Pivot detection is not accountability.

**The answer is (c): a separate component.** But not a heavyweight
one. A value. A small struct that takes conviction values and emits
classification. It lives on the post, alongside the market observers
and exit observers, because it is market structure -- a derived
property of the market observer's conviction stream. The post
feeds it. The post makes the classification available to whoever
needs it. The exit observer reads it. The broker reads it. Neither
owns it. Neither maintains it.

```
conviction stream --> PivotClassifier --> classification
                                            |
                                     +------+------+
                                     |             |
                                exit observer   broker
                                (acts on it)    (reports on it)
```

The PivotClassifier is a value, not an actor. It has no reckoner.
It has no curve. It takes a conviction value and returns a
classification. The post calls it once per candle. The result
flows to whoever needs it through the existing chain mechanism.
This is separation of concerns. The detection hangs straight.
The consumption hangs straight. They don't braid.

The state it holds is minimal: the conviction history (rolling
window), the current period, the pivot memory. These are all
properties of the conviction stream, not properties of exit
management or pair accountability. They belong with the stream's
consumer, which is a classifier, not an observer.

## On Question 6: Should the rolling percentile be a reusable primitive?

Yes. Without hesitation.

Two things in the same system use the same mechanism -- a bounded
window with percentile computation. The proposal even says so:
"the same bounded-window mechanism from Proposal 043." When two
consumers need the same mechanism, and you write it twice, you've
created a place where they can diverge accidentally. One gets a
bug fix. The other doesn't. One gets a performance improvement.
The other doesn't. That's complecting through duplication.

A `RollingPercentile` is a value. It takes a capacity. It
accepts values. It answers percentile queries. It knows nothing
about journeys or pivots or conviction. It is a window over
a stream of numbers. That's its concern. That's all it knows.

```rust
struct RollingPercentile {
    window: VecDeque<f64>,
    capacity: usize,
}

impl RollingPercentile {
    fn push(&mut self, value: f64);
    fn percentile(&self, p: f64) -> f64;
    fn len(&self) -> usize;
}
```

Three methods. No generics. No trait bounds. No configuration
beyond capacity. This is a tool, like a ruler. The journey grading
uses a ruler. The pivot classifier uses a ruler. They don't each
forge their own ruler. They use the same one. Different
measurements. Same instrument.

Put it in the module where shared mechanisms live. Both consumers
import it. When you improve the percentile computation (sorted
insertion instead of full sort, for example), both benefit.

## The deeper concern

The proposal is well-structured. The vocabulary is clean. The
state machine is clear. The Sequential encoding from 044 composes
correctly. But the ownership question -- which the proposal
correctly identifies as open -- reveals a pattern worth watching.

The exit observer is accumulating concerns. From 040: 10 trade
atoms and distance prediction. From 045: conviction history,
current period tracking, pivot memory, and sequential series
encoding. The exit observer is becoming the place where "things
related to when to act" accumulate. But "when to act" is not
one concern. It's three:

1. What distances should the stops be? (exit management)
2. What is the market structure? (pivot classification)
3. What is the rhythm of recent activity? (sequential encoding)

These three change for different reasons. They should hang
separately. The exit observer should receive the classification
and the sequence as inputs, think about them in the context of
a specific trade, and produce distances. That's its job. It
doesn't need to maintain the classification machinery any more
than a function needs to maintain its arguments.

## Conditions for approval

1. Extract pivot detection into a separate `PivotClassifier`
   value that lives on the post. The post feeds it conviction.
   The classification flows to exit observers and brokers through
   the chain.

2. Extract the rolling percentile into a shared `RollingPercentile`
   struct. Both journey grading (043) and pivot classification
   (045) use it.

3. The exit observer receives pivot classification as input, not
   as self-maintained state. Its fields should not include
   `conviction_history` or `current_period`. Those belong to
   the classifier.

The exit observer keeps what is rightfully its own: per-trade
state, distance predictions, the reckoner. The classifier keeps
what is rightfully its own: conviction history, period tracking,
the pivot memory. They compose through values, not through
co-location. That's simplicity.
