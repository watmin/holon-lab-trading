# Review: Van Tharp / Verdict: APPROVED

## The principle is correct

The main thread is the kernel. Full stop. 046's Option A placed
a stateful domain object — a tracker with rolling percentiles,
period state machines, bounded memory — on the orchestrator.
That is complecting scheduling with thinking. The correction
is right: the pivot tracker is a program with the same shape
as the cache.

The position sizing implications are what matter to me, and
the architecture serves them well. The exit observer needs
pivot context to size its stops. That context must be fresh
and it must be available on demand. A program with drain-writes-
before-reads guarantees both.

## Question 1: Query frequency

22 queries per candle (2 exit observers x 11 market pairings).
Each query returns a snapshot — a copy of bounded memory (20
records + 1 current period). No computation on the tracker
thread. The exit blocks on bounded(1) reply, gets it back
immediately.

**This is the right frequency.** Each exit observer needs the
pivot context for EACH market observer it's paired with. The
exit is composing market thoughts with exit-specific facts.
The pivot series is part of that composition. If you query
less frequently — say, once per exit per candle with all 11
trackers batched — you introduce a new message type and the
exit must demultiplex. 22 simple queries is cleaner than 2
complex ones.

The cost is negligible. 22 channel round-trips per candle is
nothing compared to the encoding work. The tracker responds
from pre-existing state — no percentile computation, no
allocation, just a bounded copy. This is O(20) per query,
O(440) per candle. The encoding pipeline does thousands of
vector operations per candle.

One observation: as the enterprise grows to multiple posts
and more exit observers, the query count scales as
(exit_observers x market_observers). With 4 exits and 11
markets, that is 44. With 6 exits, 66. Still cheap — the
snapshot is small and the tracker thread is idle most of the
time. But worth noting the scaling law explicitly so a future
designer does not accidentally introduce per-query computation.

## Question 2: Tick ordering

The proposal claims: "The main thread collects market chains
before sending to exits — the ticks arrive first."

**This is correct, but the guarantee is structural, not
temporal.** Let me trace it:

1. Market observer threads encode a candle and send their
   MarketChain back to the main thread (bounded(1) — they
   block until collected).

2. The market observer sends a tick to the pivot tracker
   (unbounded — fire and forget). This happens on the market
   observer's thread, during or after producing the chain.

3. The main thread collects all 11 MarketChains (step 2).

4. The main thread dispatches to exit observers (step 3).

5. The exit observer receives its slot data, does its work,
   and queries the pivot tracker.

The ordering guarantee comes from the pipeline stages. Between
step 3 (main sends to exit) and step 5 (exit queries tracker),
there are multiple channel hops. The tick was sent in step 2
on an unbounded queue. By the time the exit observer has
received its data, decoded the channel message, and formed
its query, the tracker has had ample time to drain.

But "ample time" is not a proof. The actual guarantee is:

- The market observer sends the tick BEFORE or CONCURRENTLY
  with sending the MarketChain back.
- The main thread BLOCKS on collecting all 11 chains (step 2).
- Only after collection does it dispatch to exits (step 3).
- The exit observer receives, processes, THEN queries.

So the causal chain is: tick-send happens-before chain-collect
happens-before exit-dispatch happens-before exit-query. The
tracker drains ticks before queries (by design). Even if one
market observer's tick is slightly delayed on the unbounded
queue, the exit observer's query arrives AFTER multiple
synchronization points.

**One edge to nail down:** the proposal says each market
observer has its own tick queue (11 queues). The program
drains ALL 11 before serving reads. This is the right design.
But the select-ready at the bottom of the loop — what happens
if the tracker is in the select-ready wait and a query arrives
before all ticks for that candle? The drain-ticks-first
invariant holds only if ticks arrive before queries. The
pipeline structure makes this overwhelmingly likely, but
the spec should state: **the tick send MUST precede the
MarketChain send on the market observer thread.** This makes
the ordering a local invariant on each market observer, not
a global timing assumption.

If the market observer does:
```
1. send tick (unbounded, non-blocking)
2. send chain (bounded(1), blocks until main collects)
```

Then the tick is in the queue before the chain is even
collected. The main thread cannot dispatch to exits until it
has all chains. The exit cannot query until it receives data.
The ticks are guaranteed to be drained before any query for
that candle arrives. This is a proof, not a hope.

**Recommendation:** make the tick-before-chain ordering
explicit in the market observer's contract. One line in the
wat spec. That turns a structural guarantee into a stated
invariant.

## Position sizing perspective

The pivot tracker serves the exit observer. The exit observer
determines stop distances. Stop distances determine position
size (through the treasury's funding logic). The pivot series
gives the exit observer context: how long do pivots last, how
far do they move, what is the conviction when they are real.

This is exactly the kind of contextual information that should
inform sizing. A pivot that has lasted 40 candles with high
conviction deserves a different stop profile than a 3-candle
blip. The exit observer can only make that distinction if it
has the full series, fresh, on demand.

The bounded(20) memory is the right size. 20 completed periods
at ~10-50 candles each covers 200-1000 candles of history.
That is roughly 17-83 hours at 5-minute resolution. Enough
to see the current market character without carrying stale
regimes.

## Summary

The pivot tracker as a program is the correct factoring. The
22 queries per candle are cheap and necessary. The tick ordering
is guaranteed by the pipeline structure, provided the market
observer sends the tick before the chain. State that invariant
explicitly. The rest follows from the drain-writes-before-reads
pattern that the cache already proved.
