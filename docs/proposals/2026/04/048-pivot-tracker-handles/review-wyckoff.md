# Review: Wyckoff / Verdict: APPROVED

## The correction is correct

047 was right about the program pattern. 048 is right about the
read topology. The realization document identifies the error
precisely: a mailbox is fan-in for writes, not for reads. The
tape reader receives prints from the floor through one stream --
that is the mailbox, the observation queues, 11 wires carrying
conviction from 11 market observers. But when 22 exit slots ask
"what does the tape look like?" each one needs its own conversation
with the reader. They do not queue behind each other at a single
window. Each has a dedicated line. The pipe IS the identity.

I approved 047 because the program pattern was sound. 048 does not
change the program. It changes the wiring of the read side. This
is a refinement, not a redesign. The drain-writes-before-reads
discipline, the bounded memory, the fire-and-forget observations,
the state machine -- all unchanged. The improvement is that the
read path now matches the cache pattern exactly: per-caller handles,
zero allocation per query, no routing in the message.

## Question 1: The query signal

Unit is sufficient. The query is not "give me something specific."
The query is "give me the current state of my tracker." The handle
already knows which tracker -- `market-idx` is structural, fixed
at construction. The candle number for staleness checking is
unnecessary because the ordering guarantee from 047 already ensures
freshness: the market observer sends the tick BEFORE sending its
chain back to the main thread, the main thread collects all chains
BEFORE dispatching to exits, the tracker drains all ticks BEFORE
servicing queries. By the time the exit queries, the tick is
already processed. There is nothing to check.

If the ordering guarantee ever fails -- and I argued in 047 that
even if it did, one candle of staleness is irrelevant to a pivot
period that spans many candles -- the correct response is to fix
the ordering, not to add staleness metadata to the query. The
query carries no data because the query HAS no data. It is a
knock on the door. The handle is the identity. Unit is correct.

The cache's get carries a key because the cache holds MANY items
and the caller requests a SPECIFIC one. The pivot handle is
already bound to a specific tracker. The key is the pipe. There
is nothing left for the message to carry.

## Question 2: Queue type for queries

Bounded(1). The exit observer sends one query and blocks on the
reply. It cannot send a second query until it receives the answer
to the first. This is a structural invariant -- the exit observer
is single-threaded within its slot, and it blocks on `recv!`.
Bounded(1) makes the invariant a type constraint. Unbounded would
silently allow a programming error (sending multiple queries
without reading replies) to accumulate garbage in the queue. The
bounded queue turns that error into a backpressure signal or a
panic, depending on the send semantics. Either way, the error
becomes visible immediately rather than corrupting state over time.

For the reply queues: also bounded(1). The driver sends exactly
one reply per query. Same argument. One question, one answer.

## Question 3: The slot-to-market mapping

A `Vec<usize>` is fine. It is fixed at construction, indexed by
slot, read-only during the loop. An array (`[usize; 22]`) would
be marginally more precise -- the size is known at compile time --
but the difference is zero at runtime. Both are a single bounds-
checked index operation. The Vec is simpler to construct from the
wiring loop. Use whichever the Rust code prefers. This is not an
architectural decision.

## The tape reader: is it fully specified?

The pivot tracker program is now fully specified across four
proposals:

- **044** defined WHAT the tape reader produces: pivot thoughts
  with direction, conviction, duration, volume ratio, and effort-
  result. Gap thoughts with duration, drift, and volume. The
  Sequential encoding that preserves the order of events. The
  biography atoms that summarize the series.

- **045** defined WHO detects and WHO interprets: the program
  detects (one tracker per market observer), each exit observer
  applies its own significance filter to decide which pivots
  enter its bounded memory.

- **047** defined WHERE the tracker lives: a dedicated program,
  not the main thread. Single-writer service pattern. Drain
  writes before reads.

- **048** defined HOW the reads are wired: per-caller handles,
  unit queries, structural routing via the pipe.

The state machine (pivot/gap alternation with direction-change
splitting and 3-candle debounce) is specified in 045. The data
structures (TrackerState, PivotRecord, PivotSnapshot) are
specified in 047. The write path (fire-and-forget from market
observers) is specified in 047. The read path (per-caller handles)
is specified here. The ordering guarantee (tick before chain) is
specified in 047.

The tape reader is specified. It can be built.

## What the tape reader captures

From the Wyckoff perspective, the pivot tracker gives the machine
the essential elements of tape reading:

1. **The rhythm of the market.** Pivot-gap-pivot-gap alternation.
   Accelerating rhythm (short gaps) means urgency. Decelerating
   rhythm (long gaps) means exhaustion. The Sequential encoding
   preserves this.

2. **Effort vs result at each event.** Volume ratio and effort-
   result at each pivot position. High effort early (climax) looks
   different from high effort late (sign of strength). The
   positional permutation preserves this.

3. **The character of the pauses.** Gap duration, drift, and
   volume distinguish quiet accumulation from dead indifference
   from contested distribution. The gap thoughts at their positions
   in the sequence preserve this.

4. **Springs and upthrusts.** Direction-change splitting (045)
   ensures that a false breakdown followed by a reversal produces
   two events in the sequence: down then up, rapidly. The geometry
   captures the spring pattern without naming it.

5. **Freshness at the moment of decision.** The ordering guarantee
   and per-caller handles ensure the exit observer sees the tape
   as of THIS candle when it decides. Not stale. Not pushed. Fresh.

## What is missing

Two things. Neither is blocking.

**First: the opening print of a new pivot period.** I noted this
in my 047 review. The conviction at the first candle of a new
pivot -- how far above the threshold it jumped -- tells you the
force of the new campaign. A pivot that opens at the 82nd
percentile is tentative. A pivot that opens at the 99th percentile
is violent. The tracker records running sum and count (average
conviction), but not the entry conviction separately. This can be
added to PivotRecord as a single field. Future proposal. Not
blocking.

**Second: the gap's internal volatility.** I noted this in my
044-v2 review. A long gap could be a smooth grind or a choppy
fight. Duration and drift alone do not distinguish these. A
`gap-chop` atom (standard deviation of candle returns within the
gap) would complete the gap characterization. The three existing
gap atoms cover 90% of what the tape shows. This is an
enhancement, not a deficiency. Future proposal. Not blocking.

The pivot tracker as specified across 044-048 captures what a
tape reader needs to read market phases. The Sequential encoding
preserves the Wyckoff narrative. The significance filter (per exit
observer) allows each observer to discover its own reading
sensitivity. The program pattern ensures clean, fresh,
contention-free access to the tape.

APPROVED. No conditions.

Richard D. Wyckoff
