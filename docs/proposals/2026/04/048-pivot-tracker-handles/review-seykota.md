# Review: Seykota / Verdict: APPROVED

The correction is obvious once seen. A shared mailbox for reads
was a design error. 048 fixes it by following the pattern that
already works in the encoder service. I have reviewed the full
044-048 arc. This closes the architecture.

## Answers to the three questions

### 1. The query signal: is `()` sufficient?

Yes. Unit is correct.

The cache carries a key because lookup is content-addressed --
"do you have THIS ast?" The pivot tracker is identity-addressed --
"give ME my snapshot." The handle IS the identity. The query
carries no content because it needs no content. The candle
number is not the caller's concern; the driver drains all
observations before serving reads (047's invariant). By the time
any reply is sent, the tracker state is current. Staleness
checking would be the caller second-guessing the protocol. If
you trust the drain-before-read invariant, unit is the only
honest message.

Adding a candle number would create a false contract: the caller
would expect the snapshot to reflect exactly that candle, but the
tracker processes ALL pending ticks in the drain pass, not just
one. The snapshot reflects everything drained so far. That is
what you want. Unit says "I trust the protocol." That is what
you should say.

### 2. Queue type: bounded(1) or unbounded?

Bounded(1).

The exit observer sends one query and blocks on the reply. It
cannot send a second query before receiving the first answer.
The bounded(1) queue enforces this structurally. Unbounded would
permit a bug where queries pile up -- an impossibility today,
but bounded(1) makes the impossibility a compile-time fact
rather than a runtime hope. The encoder service uses bounded(1)
for its lookup pipes. Same reasoning. Same answer.

One subtlety: bounded(1) means a send blocks if the slot is
full. Since the caller always blocks on recv before sending
again, the slot is always empty at send time. The bound never
triggers. It exists as documentation, not as flow control.

### 3. The slot-to-market mapping: Vec or array?

It does not matter for correctness. Use what Rust makes easy.

A `[usize; N]` array is more precise when N is known at compile
time. With 22 slots (2 exit observers x 11 market pairings), N
is fixed at construction. But Rust const generics are still
awkward for this kind of wiring code. A `Vec<usize>` built once
at startup and never mutated is a heap allocation you pay once.
The indexing cost is identical. The driver loops over it 22 times
per candle -- the cost is noise.

If the number of exit observers per market pairing ever becomes
configurable, Vec is the only option anyway. Use Vec. Move on.

## The 044-048 arc: is anything missing?

The arc is complete for what it covers:

```
044: WHAT  -- vocabulary (pivots, gaps, Sequential, biography)
045: WHO   -- post detects, exit interprets, mechanics
046: (superseded)
047: WHERE -- dedicated program, single-writer service
048: HOW   -- per-caller handles, the pipe IS the identity
```

This is a clean architecture. Four proposals that converge on
one service. I see nothing structurally missing between "the
pivot tracker exists as a program" and "the exit observer can
query it."

## What is worth examining

### The significance filter (045) is unspecified

045 says the exit observer applies "its own learned significance
filter" to decide which pivots enter its bounded memory. This is
the right principle. But no proposal specifies what that filter
IS. Is it a threshold on pivot duration? Conviction magnitude?
Volume ratio? Is it a reckoner that learns, or a static rule?

This matters because the filter determines what the exit
actually sees. Two exit observers looking at the same tracker
but applying different filters will build different Sequential
thoughts. That is the design intent -- diversity of
interpretation. But the filter needs a specification before
implementation. Otherwise the first implementer will guess, and
the guess will calcify.

I would not block implementation on this. The tracker and handle
architecture stands independent of what the exit does with the
snapshot. But the filter is the next proposal-worthy question.

### The PivotSnapshot struct is not defined

048 specifies that the reply carries a `PivotSnapshot`. 044
defines the vocabulary (pivot thoughts, gap thoughts, series
scalars). But no proposal defines the PivotSnapshot struct --
what fields it contains, whether it includes raw PivotRecords
or pre-computed thoughts, whether it includes the series scalars
or just the records.

My instinct: the snapshot should be raw records. Let the exit
compute its own thoughts after applying its significance filter.
If the tracker pre-computes thoughts, the exit cannot filter.
If the tracker sends raw records, the exit owns interpretation.
This aligns with 045's principle: "post detects, exit
interprets."

Define the struct. It is one paragraph of work, but it closes
the interface contract.

### Shutdown and lifecycle

The encoder service has explicit shutdown semantics: handles
drop, channels close, the thread exits. 048 does not specify
this for the pivot tracker. It should follow the same cascade.
When all handles drop, the query channels close. The driver
detects all-disconnected and exits. The observation channels
close when market observers drop. Both conditions must be met
for clean shutdown.

This is not a design question -- the answer is obvious (follow
the encoder service). But it should be stated once, in the wat,
so the implementer does not have to infer it.

## Blind spots

### The 22-queue polling cost

22 try_recv calls per iteration is trivially cheap. But this
is one tracker for one asset pair. The multi-asset enterprise
(per memory: treasury manages wealth, desks per asset) will
have N trackers. With 10 asset pairs: 220 query queues. Still
cheap. With 100: 2200. Still cheap for try_recv. But the
select-ready at the bottom of the loop now watches 2200 + 1100
= 3300 channels. At some scale, this design needs sharding --
one tracker program per asset pair, not one global tracker.

This is not a problem today. One pair. 22 + 11 = 33 channels.
But the architecture should be aware that the single-program
design implies one tracker per post, not one global tracker for
the enterprise. 047's resolution already implies this ("one
PivotTracker per market observer" in 045 became "the post holds
the trackers"). Just confirm it: one pivot-tracker-program per
post. Not global.

### The ordering contract is still a comment

047 specifies that the market observer must send the tick to the
pivot tracker BEFORE sending its chain to the main thread. This
is the freshness guarantee. It is currently an English sentence
in a resolution document. In Rust, it is two lines of code in
the right order. If someone reorders them, the guarantee breaks
silently.

There is no structural enforcement. The borrow checker cannot
help here -- both sends are legal in either order. This is a
protocol invariant that lives in programmer discipline. It
should at minimum be a comment at the call site. Ideally, it
would be a single function (`market-observer-emit!`) that
encapsulates both sends in the required order, making misordering
impossible.

### No backpressure on observations

The observation queues are unbounded. If the pivot tracker
program stalls (blocked on a slow telemetry write, for example),
all 11 market observers keep sending ticks that pile up in the
observation queues. Unbounded is correct for fire-and-forget
writes -- you do not want market observers blocking on the
tracker. But it means the tracker must never stall. The
telemetry write (`db-tx`) should be fire-and-forget into an
unbounded queue (which it likely already is). Just confirm that
no blocking call exists inside the tracker's drain loop.

## Summary

048 is a clean correction. The shared mailbox was wrong. The
per-caller handle is right. The pattern is proven in the encoder
service. The three questions have clear answers: unit, bounded(1),
Vec.

The 044-048 arc is architecturally complete. What remains is
specification work: the PivotSnapshot struct, the significance
filter interface, and the shutdown cascade. None of these block
the implementation of the tracker program itself. They can be
resolved in parallel or in the next proposal.

The trend is intact. Build it.
