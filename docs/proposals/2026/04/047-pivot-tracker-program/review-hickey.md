# Review: Hickey / Verdict: APPROVED

The correction is honest and the factoring is right.

## The correction

In 046 I approved Option A because it was the simplest of the
three options presented. And it was. None of those three options
proposed a program. All three assumed the main thread would hold
the tracker state. I evaluated what was in front of me and chose
the least braided option.

But the builder is correct: the simplest option among three wrong
framings is still wrong. The main thread holding domain state is
complecting orchestration with computation. I said in that review
that "a value that travels through an existing channel is simpler
than a new channel for the same purpose." That principle stands.
What I missed is that the existing channel was the wrong carrier
because the main thread was the wrong owner.

The kernel should schedule. It should not think. I have said this
in other contexts -- the runtime should not contain application
logic. The moment the main thread maintains PivotTrackers and
enriches chains, it has become a participant in the domain. It
knows about conviction. It knows about pivot classification. It
knows about period transitions. That is domain knowledge living
on the orchestrator. The orchestrator should be ignorant of what
it routes.

The correction convinces me. I was wrong about Option A.

## Question 3: Is this the right factoring?

Yes. This is the right factoring because it is the cache pattern,
and the cache pattern is already proven in this system.

N writers, M readers, one thread, drain writes before reads. The
cache does this. The database does this. The pivot tracker does
this. The pattern is: a component that holds state, accepts
updates from producers, and serves queries from consumers, all
through channels, all on a single thread, with no contention.

Is it a stdlib pattern or an application pattern? It is a stdlib
pattern. The shape -- N producers, M consumers, single-threaded
state owner, write-priority draining -- is domain-independent.
The pivot tracker is an instance. The cache is an instance. Any
component that mediates between writers and readers through
channels is an instance. If you find yourself writing this a
third time, extract it. But the recognition that it IS the same
pattern is more valuable than premature abstraction.

The key insight in the proposal is the separation of write
topology from read topology. Market observers write. Exit
observers read. These are different populations with different
timing requirements. Writers are fire-and-forget (unbounded).
Readers are request-response (bounded(1)). The program
mediates between these two modes. That is what makes it a
program and not a function call on the main thread.

The 11 independent tick queues are correct. Each market observer
writes to its own queue. The program drains all 11. No contention
between writers. No ordering dependency between writers. This is
the same independence the proposal identifies in Question 4 --
market observer 3's tick does not affect market observer 7's
state. Independent queues for independent producers.

## Question 4: Tick ordering

Arrival order is sufficient. The proposal already states why:
each tracker is independent. Market observer 3's state machine
does not read market observer 7's conviction history. The
trackers are indexed. The ticks carry the index. The program
routes by index. No cross-tracker dependency means no ordering
requirement across trackers.

Within a single tracker, the ticks from one market observer
arrive in order because they come from one thread through one
queue. FIFO is guaranteed by the channel. There is no
reordering problem within a tracker and no dependency problem
across trackers. Arrival order is causal order.

## Question 5: Telemetry

The same `emit_metric` pattern as the other programs. The
tracker has a `db-tx` in its signature. It should emit:

- Period completions (pivot or gap finalized, with duration
  and direction)
- Per-tracker conviction percentile at each tick (the
  threshold that determines pivot vs gap)

Do not emit per-tick telemetry at high frequency. Emit on
state transitions -- when a period closes. That is the
interesting event. The conviction percentile is useful at
lower frequency for debugging threshold drift.

The telemetry interface should be the same channel type as
the cache and database use. One more thing that is the same
pattern. Do not invent a new telemetry mechanism for this
program.

## The deeper observation

046 presented three options. All three were flavors of "where
does this state live relative to the main thread?" None asked
"should this state be on the main thread at all?" The builder
saw what five designers missed: the question was wrong.

The principle the builder states is precise: "the main thread
is ONLY a kernel for programs. Putting anything on it that
isn't scheduling will be a failure." This is the separation
between mechanism and policy. The kernel provides mechanism
(channels, scheduling, fan-out). The programs provide policy
(pivot detection, caching, persistence). When policy creeps
onto the kernel, you get a monolith that knows too much.

I approved 046's Option A because it was simple relative to
the alternatives. The builder is proposing something simpler
in absolute terms: a program that owns its own state, its own
thread, its own channels, and its own lifecycle. The main
thread does not know what a pivot is. It does not enrich
chains. It sends candles and collects outputs. That is all it
should ever do.

Approved.
