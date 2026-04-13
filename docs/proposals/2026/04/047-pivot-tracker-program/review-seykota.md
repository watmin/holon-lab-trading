# Review: Seykota / Verdict: APPROVED

I approved Option A in 046. I was wrong. This proposal is right
to correct it, and it is right about WHY it was wrong. I will
answer the two questions, then say why I changed my mind.

---

## Question 1: 22 queries per candle — is this the right frequency?

Yes. Twenty-two queries per candle is the right frequency because
it is the natural frequency. Each exit observer, for each market
pairing, needs the pivot state at the moment it composes its
thought. Not before. Not batched. At the moment of composition.

The exit observer is on its own thread. It thinks when the
orchestrator tells it to think. When it thinks, it needs the
current pivot state for the specific market observer it is
paired with. One query, one snapshot, one composition. That is
22 queries because there are 2 exits and 11 markets. If we had
5 exits it would be 55. The frequency is determined by the
topology, not by a tuning parameter.

The cost is nothing. Each query returns a bounded snapshot — at
most 20 PivotRecords plus a CurrentPeriod. The tracker builds
the snapshot from memory it already holds. No computation. No
allocation beyond the reply. The tracker thread drains ticks
first, then serves queries. The exit blocks on bounded(1) — it
gets an answer in microseconds. Twenty-two microsecond queries
per candle against milliseconds of encoding is not a concern.

The alternative — pushing snapshots eagerly to all exits every
candle — is what 046 Option A did. That pushes 22 snapshots
whether the exit needs them or not. The query model is pull,
not push. The exit asks when it needs. The tracker answers when
asked. Pull is always right when the consumer's timing matters.

---

## Question 2: Is the tick ordering guaranteed?

Yes, by the existing topology. Here is the sequence:

1. Main thread sends candle to 11 market observer threads.
2. Market observers encode, predict, and send ticks to the
   tracker. Then they return their MarketChain.
3. Main thread collects all 11 MarketChains (blocking).
4. Main thread sends MarketChains to exit observer slots.
5. Exit observers receive chains, begin composing, and query
   the tracker for pivot state.

Between step 2 and step 5, the ticks have been sent. Between
step 3 and step 5, the main thread has collected — meaning all
11 market observers have completed their work, including sending
their ticks. By the time the exit observer queries the tracker,
the ticks are in the queues. The tracker drains all ticks before
serving queries. The ordering is guaranteed by the pipeline
topology, not by timestamps or sequence numbers.

The one subtlety: what if the tracker thread has not yet drained
the tick queue when the exit queries? The answer: the tracker
drains ALL ticks before ANY queries. If a tick is in the queue,
it gets processed before the query is served. The drain-before-
read invariant is the guarantee. This is the same invariant the
cache uses. It works.

---

## Why I changed my mind

In 046 I said Option A was "the simplest pipe that works." I
said "it widens an existing pipe" and "adds zero moving parts."
I was measuring the wrong thing.

Option A was simple in terms of pipes. But it placed domain
state on the orchestrator. Eleven PivotTrackers living on the
main thread. The main thread computing ticker-tick between
steps 2 and 3. The main thread enriching the chain with pivot
records. The main thread THINKING.

I said "the main thread is the orchestrator" and then I
approved putting computation on the orchestrator. That is a
contradiction. The proposal's principle is correct: the main
thread is a kernel. It wires. It schedules. It routes. It does
not hold domain state. It does not compute domain transitions.
The moment it does, orchestration is complected with thinking.

I missed it because I was counting pipes instead of counting
concerns. Option A had zero new pipes but it had one new
concern on the wrong thread. This proposal has one new thread
and several new pipes, but every concern lives where it belongs.
The tracker is a program because it maintains state, processes
a stream, and serves queries. That is not orchestration. That
is thinking. Thinkers get their own threads.

The cache pattern is the proof. The cache does the same thing:
N writers (market observers setting composition vectors), M
readers (exit observers getting composition vectors), one
thread, drain writes before reads. The pivot tracker is the
same shape. Recognizing a pattern that already works is simpler
than inventing a new arrangement — even when the new arrangement
has fewer pipes.

I was right about one thing in 046: one tape, many readers.
This proposal keeps that property. It just puts the tape on its
own spool instead of threading it through the orchestrator.

---

## The trend follower's concern

The pivot tracker IS the trend. It is the structure of the
market's recent behavior — the alternation between conviction
and indecision, the duration and amplitude of each phase. The
exit observer reads this structure to set its distances. How
wide is the trailing stop? Look at how long the pivots last.
How tight is the take-profit? Look at how compressed the gaps
are.

This data must be fresh. The exit must see the ticks from THIS
candle's market encoding, not the previous candle's. The drain-
before-read invariant guarantees freshness. The bounded(1)
query/reply guarantees the exit blocks until it has the answer.
No stale reads. No race conditions. The exit sees exactly the
current state of the tracker, which includes the tick from the
market observer that just predicted.

A trend follower does not tolerate stale data. This design
does not produce stale data. Approved.
