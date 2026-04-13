# Review: Beckman / Verdict: CONDITIONAL

## The diagram

Let me draw the categories first, then check whether the proposal
makes the diagram commute.

You have three functors in a pipeline:

```
MarketObs : Stream<Candle> --> Stream<(Vector, Prediction, conviction)>
ExitObs   : Stream<(MarketChain, TradeState)> --> Stream<Distances>
Broker    : Stream<(MarketOut, ExitOut)> --> Stream<(Proposal, Resolution)>
```

These compose. The broker is the pullback -- it pairs a market morphism
with an exit morphism and grades the pair. The composition is the
enterprise's per-candle fold. Good. The diagram commutes today.

Now Proposal 045 introduces a new morphism:

```
PivotDetect : Stream<(conviction, direction, candle)> --> Stream<PivotRecord>
```

This is a stream transducer. It consumes the conviction stream and
produces a classified stream of periods. The proposal places this
transducer INSIDE the exit observer. Let me examine whether that
placement makes the diagram commute.

## Question 5: Who owns pivot detection?

The proposal identifies three candidates and leaves the question open.
Let me close it categorically.

**The exit observer is the wrong home.** Here is why. The pivot
transducer's input is `(conviction, direction, candle)` -- all three
come from the market observer's output. The exit observer's proper
input is `(MarketChain, TradeState)`. The pivot transducer does not
depend on trade state. It does not depend on distances. It does not
depend on the exit lens. It is a pure function of the market stream.

If you place PivotDetect on the exit observer, you get a factoring
problem. You have M exit observers, each maintaining its own copy of
the conviction history and its own copy of the pivot state machine.
But the conviction stream is the SAME for all M exits paired with
the same market observer. You would compute the same rolling
percentile M times. The diagram doesn't just fail to commute -- it
has redundant paths. Redundant paths in a category are a code smell.
They mean the factoring is wrong.

**The broker is also wrong.** The broker sees ONE (market, exit)
pair. But the pivot classification depends only on the market side.
N x M brokers would each compute the same classification that depends
only on which of the N market observers they are paired with. Now
you have N x M redundant copies instead of M. Worse.

**The market observer is wrong too, but for a different reason.**
The market observer's job is `Candle -> (Vector, Prediction)`. It is
a functor from candle-space to prediction-space. Adding pivot state
to it changes its type signature. The market observer produces
conviction as a BYPRODUCT of prediction. It should not consume its
own byproduct to classify pivots. That would be a self-loop, and
you've already established that the protocol doesn't support
self-reference.

**The natural home is the Post.** The Post already mediates between
market observers and exit observers. The Post already routes candles
to market observers and collects their outputs. The Post owns the
indicator bank (streaming state over candles). The pivot transducer
is the same KIND of thing as the indicator bank -- streaming state
that transforms a raw signal into a classified signal.

The correct factoring:

```
Post.PivotTracker[i] : Stream<MarketObs[i].conviction> --> Stream<PivotRecord>
```

One pivot tracker per market observer. Not per exit observer. Not per
broker. Per market observer. The Post maintains N pivot trackers
(one per market observer). When the Post routes the market chain to
the N x M broker grid, it attaches the pivot classification from
the corresponding market observer's tracker.

This makes the diagram commute:

```
Candle --> MarketObs[i] --> (Vector, Prediction, conviction)
                                |
                                v
                     Post.PivotTracker[i] --> PivotRecord
                                |
                                v
              (MarketChain + PivotContext) --> ExitObs[j]
                                |
                                v
                            Broker[i,j]
```

The pivot classification is a NATURAL TRANSFORMATION between the
market functor and the exit functor. It lives at the level where
the transformation is applied -- the Post, which is the composition
site.

One concern: the proposal says the exit observer "owns" the pivot
memory for its sequential encoding (the VecDeque of 20 PivotRecords).
Fine. The exit observer can maintain a bounded VIEW of the Post's
pivot stream. The distinction is: the Post DETECTS pivots (one
tracker per market observer), the exit observer REMEMBERS them
for its own encoding purposes (one memory per exit observer, fed
from the Post's detection). Detection is shared. Memory is local.
The factoring is clean.

## Question 6: The rolling percentile

Yes. Absolutely. This is the same construction.

In Proposal 043, the journey grading needs a rolling threshold over
error ratios. In Proposal 045, the pivot detection needs a rolling
threshold over conviction values. Both are:

1. A bounded VecDeque of the last N values
2. A percentile query over that window
3. A threshold decision: value > percentile(window, p)?

The algebra is identical. The parameters differ (N, p). This is a
textbook case for a parametric type:

```rust
struct RollingPercentile<const N: usize> {
    window: VecDeque<f64>,  // bounded at N
}

impl<const N: usize> RollingPercentile<N> {
    fn push(&mut self, value: f64);
    fn percentile(&self, p: f64) -> f64;
    fn exceeds(&self, value: f64, p: f64) -> bool;
}
```

Two uses:

```rust
// Journey grading (043)
type JourneyGrade = RollingPercentile<500>;

// Pivot detection (045)  
type ConvictionThreshold = RollingPercentile<500>;
```

The const generic makes each instantiation a distinct type at
compile time. No runtime cost for the generality. The percentile
computation (nth-element selection on a sorted copy, or a
partial-sort) is shared. One implementation. Two uses. The
diagram factors through a common object.

But I want to push further. The percentile query on a VecDeque
of 500 elements requires sorting or partial-sorting every time.
That is O(N log N) per query. For a value that changes by one
element per candle, there is an incremental structure --
an order-statistic tree or a pair of heaps -- that maintains
the percentile in O(log N) per insertion. The proposal should
note this as an optimization opportunity. Not required now, but
the type should be designed so the internals can change without
affecting the interface. Encapsulation buys you that for free.

## The stream transducer question

The proposal's state machine (gap/pivot transitions) is a Mealy
machine. Input: `(conviction, direction, candle)`. Output:
`Option<PivotRecord>` (emitted on transitions). State: the
current period. This is a well-understood construction in
automata theory.

Where does a Mealy machine live in the architecture? It lives
where its input is produced and its output is consumed. The
input comes from the market observer. The output feeds the exit
observer and the broker (through the chain). The natural
composition site is the Post -- it is already the fan-out point
between market observers and the N x M grid.

Placing the Mealy machine on a consumer (the exit) means the
consumer must reconstruct a signal that was already available
at the production site. Placing it on a router (the broker) means
N x M redundant state machines. Placing it at the fan-out point
(the Post) means N state machines, each producing a stream that
fans out to M exits and N x M brokers. This is the minimal
factoring.

## Conditions for approval

1. **Move pivot detection to the Post.** One PivotTracker per
   market observer. The Post detects. The exit observer remembers
   (bounded view for its sequential encoding). The broker reads
   pivot atoms but does not detect.

2. **Extract RollingPercentile as a shared type.** The journey
   grading (043) and the pivot threshold (045) should share the
   same implementation. Parametric on window size. Encapsulated
   so internals can optimize later.

3. **Clarify the data flow.** The PivotRecord produced by the
   Post's tracker should flow through the existing chain --
   attached to the MarketChain that the Post already routes.
   The exit observer receives it as input, not as something it
   computes. The exit observer's new fields become:
   - `pivot_memory: VecDeque<PivotRecord>` (bounded at 20, fed
     from the chain)
   - `current_period: CurrentPeriod` (REMOVED -- the Post owns this)
   - `conviction_history: RollingPercentile<500>` (REMOVED --
     the Post owns this)

If these three conditions are met, the diagram commutes. The
factoring is minimal. The types are shared. The data flows
downhill. Approved.

## Notes

The pivot state machine itself is well-designed. The scheme
pseudocode is clear. The gap/pivot alternation with running
stats is the right abstraction. The bounded memory of 20
entries (10 pivots + 10 gaps) is reasonable for positional
encoding -- more would dilute the permutation signal. The
80th percentile is a reasonable starting point (the machine
will teach you if it's wrong). None of that changes. Only
the PLACEMENT changes.

The portfolio biography atoms (active-trade-count,
oldest-trade-pivots, etc.) correctly live on the broker.
The broker computes them FROM the pivot classification it
receives through the chain. The broker reads atoms. The
broker doesn't detect. This is already what the proposal
says. Good.

One mathematical note on the conviction history window: N=500
at 5-minute candles is ~42 hours. That is roughly 2 trading
days. The 80th percentile of a 2-day window is a local
measurement -- it adapts to regime changes within days. If the
market shifts from trending to choppy, the threshold adjusts
in ~500 candles. This is the right timescale for a pivot
detector that should breathe with the market. If it were
longer (2000 candles = 1 week), it would be too sticky. If
shorter (100 candles = 8 hours), it would flicker. 500 is
in the sweet spot. But the RollingPercentile type makes this
a parameter, not a commitment. Good.
