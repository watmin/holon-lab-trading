# Review: Beckman / Verdict: APPROVED

## Preamble

This is correct. And it's correct in a way that makes me
want to say "obviously correct," which is the highest
compliment in architecture. Let me address the three
questions directly, then make one observation.

## Question 3 — The program pattern: stdlib or application?

This is a stdlib pattern. It's an instance of the
**single-writer service**: one thread owns mutable state,
N producers write through fire-and-forget channels,
M consumers query through request-response channels, and
the service drains writes before serving reads to maintain
causal consistency.

The encoder service (`encoder-service.wat`) is exactly this
pattern. The log service (`log-service.wat`) is a degenerate
case — N writers, zero readers, same drain loop. The pivot
tracker is a third instance. Three instances of the same
shape is a pattern.

Categorically, this is a presheaf. The state lives in one
place. The morphisms (channels) connect producers and
consumers to that state. The drain-before-serve discipline
is a natural transformation that ensures every query sees
all preceding writes — it's the colimit over the tick
streams, computed incrementally. This is the right
factoring because it makes the commutativity constraint
trivial: there's only one thread mutating the state, so
there's nothing to commute.

The fact that each of the 11 trackers is independent —
market observer 3's ticks don't touch market observer 7's
state — means the tracker program is actually a product
of 11 independent Mealy machines sharing a thread for
scheduling convenience. This is important because it means
the program could be split into 11 separate programs if
throughput demanded it, without changing the semantics.
The current design is the right one (one thread, 11
independent automata) because the work per tick is trivial
and the scheduling overhead of 11 threads would dominate.

The diagram commutes. The tick channel from market observer
i to the tracker, composed with the query channel from the
tracker to exit observer j, equals the data path that 046's
Option A achieved by enriching the chain — but factored
through a proper state owner instead of hanging domain logic
on the kernel. Same result, correct factoring.

## Question 4 — Tick ordering

Safe. And provably so.

The 11 trackers are independent state machines indexed by
`market_idx`. Tracker i only processes ticks with
`market_idx = i`. There is no cross-tracker dependency.
The tick from market observer 3 cannot affect the state of
tracker 7. This is not an accident of the current design —
it's structural. The trackers are a product type, not a
dependent type.

Within a single tracker, ticks arrive in order because each
market observer has its own dedicated unbounded queue and
each market observer sends ticks sequentially (one per
candle, in candle order). An unbounded FIFO preserves
insertion order. So tracker i sees candle 100 before
candle 101 from market observer i. Always.

The nondeterminism is *across* trackers — the program
might drain market observer 7's tick for candle 101 before
market observer 3's tick for candle 100. This is harmless
because the trackers are independent. The arrival order
across trackers is observationally irrelevant.

The query timing is also safe. The proposal says "drain
ticks before queries." This means every query sees all
ticks that arrived before the drain pass. If exit observer
j queries tracker i, it sees every tick that market observer
i sent before the drain. The only question is whether the
*current candle's* tick has arrived yet. It has, because of
the pipeline topology: market observers complete before exit
observers query (the main thread collects market chains
before dispatching to exits, and the tick is sent during
market observer processing). By the time the exit observer
sends its query, the tick is already in the queue. The
drain pass picks it up.

This is a happens-before argument. The tick send
happens-before the chain collection. The chain collection
happens-before the exit dispatch. The exit dispatch
happens-before the query send. The drain happens-before
the query service. The chain is: tick-send < collect <
dispatch < query-send < drain < query-service. QED.

## Question 5 — Telemetry

Yes, `emit_metric` through the existing `db-tx` channel.
The pivot tracker should report:

1. **Per-tracker pivot transitions** — when a tracker moves
   from gap to pivot or pivot to gap, emit a metric with
   the completed period's summary (duration, direction,
   conviction-avg). This is event-driven, not per-candle.

2. **Per-candle aggregate** — once per drain pass, emit
   the 11-element summary: how many trackers are in pivot
   mode vs gap mode, the mean conviction percentile across
   trackers. This is the heartbeat.

Do NOT emit per-tick telemetry. 11 ticks per candle is
fine operationally but pointless as data — the tick itself
IS the data, already captured in the tracker state. Emit
on state transitions and on the drain heartbeat.

The log service already handles unbounded fire-and-forget
telemetry channels. The pivot tracker gets one `db-tx` like
every other program. No new pattern needed.

## One observation

The proposal says "046's Option A was wrong because it
placed tracker state and tick logic on the main thread."
This is exactly right, but I want to name the categorical
reason: **the main thread is the identity morphism of the
scheduling category.** It routes. It composes. It does not
transform. Placing a Mealy machine on the identity morphism
complects scheduling with computation. The pivot tracker is
a morphism from tick-streams to pivot-snapshots. Morphisms
belong on objects (programs), not on the identity.

The builder's principle — "the main thread is ONLY a
kernel" — is the operational statement of this categorical
fact. This proposal honors it.

Approved without conditions.
