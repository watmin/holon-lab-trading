# Review: Beckman / Verdict: APPROVED (Option A)

## The categorical question

Let me set up the diagram from 045 and check which option
preserves it.

The current pipeline is a composition of functors:

```
F : Stream<Candle> --> Stream<MarketChain>       (market observers)
G : Stream<MarketChain> --> Stream<ExitChain>    (exit observers)
H : Stream<(MarketChain, ExitChain)> --> Stream<Resolution>  (brokers)
```

The Post is the composition site: `H . G . F`. The main thread
is the arrow between objects. The bounded(1) channels are the
morphisms. The diagram commutes because each stage consumes
exactly what the previous stage produces. No side channels. No
ambient state. Values flow forward through function composition.

Now. PivotDetect is a Mealy machine:

```
P : Stream<(conviction, direction, candle)> --> Stream<PivotRecord>
```

Its input is a PROJECTION of F's output. Its output must reach G.
The question is: where does P attach to the composition?

## Question 3: Which option composes?

**Option A composes. The others do not.**

Think of the MarketChain as an object in a category. The chain
is the carrier of a natural transformation between F and G -- it
IS the interface type. Option A enriches this carrier:

```
MarketChain  ~~>  MarketChain'  =  MarketChain + PivotContext
```

This is a functor from the old chain type to the enriched chain
type. Call it `E : Chain --> Chain'`. The enrichment is applied
at the composition site (the main thread, between steps 2 and 3).
The new pipeline is:

```
G' . E . F
```

Does this compose? Yes. E is a functor -- it maps each
MarketChain to a MarketChain' by attaching the PivotTracker's
output. It does not change the domain of F (market observers
still produce MarketChain). It does not change the codomain of
G (exit observers still consume whatever comes through the
channel). The exit observer's input type grows, but that is a
subtyping relationship -- MarketChain' is a strict supertype of
MarketChain in the informational sense. Everything the exit
observer could read before, it can still read. It gains new
fields. No existing morphisms are invalidated.

**Option B breaks composition.** A dedicated pivot pipe creates
a SECOND morphism between F and G. The exit observer now has
TWO inputs: the chain and the pivot pipe. This is a product
in the category -- the exit's input becomes `MarketChain x
PivotUpdate`. But these two streams must be synchronized (the
proposal correctly identifies the "join problem"). A product
with a synchronization constraint is not a free product -- it
is a pullback. And pulling back two asynchronous streams over a
shared candle index is exactly the kind of complection that Hickey
would flag. The diagram now has a diamond that must commute, and
the commutativity depends on ordering guarantees that the
bounded(1) channels do not provide by construction.

**Option C breaks factoring.** I said this in 045 and I will say
it again: M identical Mealy machines on the same input stream is
a factoring error. The diagram has M redundant paths from the
conviction stream to the PivotRecord stream. They all compute the
same function. They all produce the same output. The only reason
to duplicate is if each instance DIVERGES -- but the proposal
explicitly says they don't (same threshold, same debounce, same
state machine). The divergence is in the significance FILTER,
not the detection. The filter is a separate morphism that
composes AFTER the shared detection. Factor it:

```
P : conviction --> PivotRecord       (one, on the Post)
S_j : PivotRecord --> SignificantPivot  (one per exit j)
```

Option C collapses P and S into a single morphism per exit.
That means you cannot share P. That means you cannot test P
independently. That means the factoring is minimal only if M=1.
For M>1, it is redundant. Redundancy is the categorical symptom
of incorrect factoring.

## Question 4: Is the chain-as-carrier a natural transformation?

Yes. Here is why.

A natural transformation eta between functors F and G assigns
to each object X a morphism eta_X : F(X) --> G(X) such that
for every morphism f : X --> Y, the naturality square commutes.

In our case:
- F maps each candle to a MarketChain (the current functor)
- F' maps each candle to a MarketChain' (the enriched functor)
- eta is the enrichment: for each candle c, eta_c attaches
  PivotTracker[i]'s output to MarketChain[i]

The naturality condition says: if you process candle c and then
candle d, you get the same result as if you first enrich c,
then process d and enrich d. Does this hold?

Yes, because the PivotTracker is a sequential state machine
that processes candles in order. The enrichment at candle c
depends only on the conviction stream up to and including c.
The enrichment at candle d depends on the stream up to d. The
tracker's state after processing c is the same regardless of
whether you enrich c's chain or not -- the enrichment is a READ
of the tracker's state, not a WRITE. The tracker state advances
by ticking, not by enriching. So the two operations (tick the
tracker, read the state into the chain) can be composed in
either order with the same result. The square commutes.

More concretely: the main thread ticks the tracker (step 2.5),
then reads the state into the chain. The next candle ticks the
tracker again. The chain from candle c carries the tracker's
state AS OF candle c. The chain from candle d carries the
tracker's state AS OF candle d. The tracker's evolution is
independent of the enrichment. Natural.

This would NOT hold for Option C. If the exit observer maintains
its own tracker, the tracker's state depends on WHEN the exit
observer processes its input. If the exit observer falls behind
(backpressure on the bounded channel), its tracker state diverges
from what the Post would have computed. The naturality square
does not commute because the exit observer's processing order is
not guaranteed to match the main thread's candle order. With
bounded(1) channels and the main thread as sole sequencer, this
divergence cannot happen TODAY -- but it is not enforced by the
type system. It is enforced by accident of the pipeline topology.
Option A makes the guarantee structural.

## Question 5: Which option matches "post detects, exit interprets"?

**Option A. Precisely.**

The 045 resolution said: "Post detects. Exit interprets." Let me
map each option to this contract:

- **Option A:** The Post's main thread ticks the PivotTracker
  (detection). The main thread attaches the records to the chain
  (transport). The exit observer reads the chain and applies its
  significance filter (interpretation). Detection happens before
  the chain is sent. Interpretation happens after the chain is
  received. The chain is the boundary between detection and
  interpretation. Clean.

- **Option B:** The Post detects (same as A). But the transport
  is split across two pipes. The exit observer must JOIN the
  two streams before it can interpret. The join is neither
  detection nor interpretation -- it is synchronization
  bookkeeping. It is a new concern that exists only because
  the transport was split. Option B inserts a third verb between
  "detect" and "interpret": "synchronize." The resolution did
  not ask for this.

- **Option C:** The exit observer detects AND interprets. This
  directly contradicts the 045 resolution. The post does NOT
  detect. The exit does. The resolution is violated.

## The Mealy machine and the message

You ask: does attaching the transducer's output to the CSP
message make the diagram commute?

Yes. The PivotTracker is a Mealy machine. Its output is a
function of its current state and its current input. The main
thread ticks the machine (state transition), reads the output
(PivotRecords + CurrentPeriod), and copies that output into the
MarketChain message. The message now carries the transducer's
snapshot at this candle.

The key insight: the transducer's output is a VALUE, not a
reference. The chain carries a Vec<PivotRecord> -- owned data,
not a pointer to the tracker. Once the chain is sent through
the bounded(1) channel, the exit observer owns a copy. The
tracker continues to evolve on the main thread. No aliasing.
No contention. The CSP message is the natural delineation
between the writer's state and the reader's view. This is
exactly what CSP was designed for.

The diagram commutes because:

1. The tracker ticks BEFORE the chain is sent (causal ordering)
2. The chain carries a snapshot, not a reference (value semantics)
3. The exit observer reads the snapshot AFTER the chain arrives
   (channel ordering)
4. No other writer touches the tracker between tick and send
   (single-threaded main loop)

These four properties are structural -- they follow from the
pipeline topology, not from programmer discipline.

## The 2KB question

The proposal asks whether 2KB per chain complects the snapshot
with the history. No. The PivotRecords are not "history" in the
streaming sense. They are the CURRENT STATE of a bounded window.
The tracker maintains a bounded set of records (up to 20). This
is the same kind of state as the conviction score itself -- a
summary of recent behavior, not an unbounded log.

If the chain carried the entire conviction history (all 500
values in the rolling window), that would be complection. But
carrying 20 completed PivotRecords (each a summary of a period
that has ALREADY BEEN CLASSIFIED) is carrying facts, not raw
data. Facts are what chains are for.

## Summary

Option A is the unique factoring that:

1. Preserves the existing composition `H . G . F`
2. Constitutes a natural transformation from F to F'
3. Satisfies "post detects, exit interprets"
4. Maintains value semantics through CSP channels
5. Has zero redundant computation (N trackers, not M*N)
6. Introduces no new synchronization concerns

The diagram commutes. The factoring is minimal. Ship it.
