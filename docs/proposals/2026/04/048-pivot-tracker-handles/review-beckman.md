# Review: Beckman / Verdict: APPROVED

## The three questions

### 1. The query signal: is `()` (unit) the right message?

Yes. This is categorically correct. The handle is a morphism from
a specific caller to a specific tracker. The identity of the caller
is the pipe itself — the structural position in the wiring. A unit
signal is the terminal object in this category: it carries no
information because no information is needed. The pipe IS the
information. The cache's get carries a key because the cache is a
key-value store — the caller doesn't know which slot it wants until
runtime. The pivot handle knows at construction time. The key is
baked into the wiring. Unit is the only honest signal.

One caveat: if you later need staleness checking (did I already
get this candle's snapshot?), the candle number would ride on
the query. But that's a future refinement, not a structural
change — the handle type can grow without changing the topology.
Don't add it until you need it.

### 2. Queue type for queries: unbounded or bounded(1)?

Bounded(1). The exit blocks on the reply. It sends exactly one
query per candle. Bounded(1) is not just an optimization — it is
a type-level assertion that the protocol is lock-step. An
unbounded queue here would be a lie: it would claim the exit
might pipeline multiple queries, which it never does. Let the
capacity declare the protocol. bounded(1) for query, bounded(1)
for reply. Symmetric.

### 3. The slot-to-market mapping: Vec\<usize\> or array?

An array `[usize; 22]` is more precise. The length is known at
compile time. But this is a wiring-time constant, not a hot path.
`Vec<usize>` works. The important thing is that it's computed once
at construction and never mutated. Either representation satisfies
that. I'd use the array if Rust makes it convenient, but I wouldn't
block on it.

---

## The 044-048 arc: does the diagram commute?

Let me trace the factoring.

**044** defines the domain objects: what a pivot IS (a period of
elevated conviction), what a biography IS (the trade's history
through pivots), what a series IS (positional encoding of
alternating pivots and gaps). This is the objects and morphisms
of the domain category.

**045** resolves ownership: who detects pivots (the post, not the
exit observer, not the broker). It defines the state machine
(pivot/gap transitions driven by a rolling percentile threshold).
This is the algebra on the objects — the transition function.

**046** asks how the data moves. Three options. All three were
wrong, but in instructive ways:
- Option A (enrich the chain on main thread) complects
  orchestration with domain logic.
- Option B (dedicated pipes) creates a join problem — two
  channels that must be synchronized per candle.
- Option C (trackers on exit threads) duplicates the state
  machine across M exit observers — the "M redundant Mealy
  machines" I flagged.

**047** corrects all three by recognizing the pivot tracker as a
**program** — the single-writer service pattern. One thread owns
the state. N writers push observations. M readers query. Drain
writes before reads. No contention. No duplication. The main
thread stays a kernel.

**048** corrects 047's read interface: the shared mailbox was a
fan-in pattern applied where a per-caller pattern was needed.
Per-caller handles replace the mailbox. The pipe IS the identity.
No routing in the message. Zero allocation per query.

### Does it commute?

Yes. The diagram:

```
044 (domain objects)
 ↓
045 (state machine + ownership)
 ↓
046 (data flow — three wrong options)
 ↓
047 (correct factoring: program pattern)
 ↓
048 (correct read interface: per-caller handles)
```

Each arrow is a refinement. Each corrects without invalidating
the prior. 044's vocabulary is unchanged. 045's state machine is
unchanged. 046's analysis was necessary to reach 047 — the three
wrong options are the evidence that a program was needed. 047's
write interface and program loop are unchanged by 048. The
correction is local: only the read side changes.

The composition 044 ; 045 ; 046 ; 047 ; 048 produces a fully
specified pivot tracking service. The intermediate objects
(046's three options) are not in the final composition — they
were explored and discarded. The diagram commutes because each
refinement is a restriction (narrowing the solution space), not
a redefinition.

### Is the categorical factoring complete?

Almost. The factoring decomposes into:

1. **Domain** (044): PivotRecord, CurrentPeriod, PivotSnapshot,
   trade biography, portfolio biography, Sequential AST form.
2. **Algebra** (045): state machine transitions, rolling
   percentile, debounce.
3. **Topology** (047 + 048): program thread, N write channels
   (unbounded, fire-and-forget), M read channels (per-caller
   handles, bounded(1), request/response), slot-to-market
   mapping.

These three concerns are cleanly separated. The domain doesn't
know about channels. The topology doesn't know about conviction
thresholds. The algebra doesn't know about threads. This is
correct factoring.

### Is the single-writer service pattern fully specified?

As a pattern, yes. The specification in 047+048 gives:

- **State**: owned by one thread, never shared.
- **Writes**: N producers, each with a dedicated unbounded queue.
  Fire and forget. The driver drains all write queues before
  servicing reads.
- **Reads**: M consumers, each with a dedicated handle (query-tx,
  reply-rx). The driver loops over query queues with try_recv.
  The pipe is the identity — no routing in the message.
- **Loop**: drain writes, service reads, select-ready on all
  receivers.

This is the same pattern as the composition cache service. It
recurs. It should be recognized as a stdlib pattern — not
because the application code should call a generic library, but
because the SHAPE is invariant across instances. Cache, pivot
tracker, database writer, console — they all have this shape.
The invariant is: single owner, fan-in writes, per-caller reads,
drain-before-serve.

The pattern IS fully specified. What varies per instance is:

- The state type (TrackerState vs CacheState vs ...)
- The write message type (PivotTick vs CacheSet vs ...)
- The read query/response types (() / PivotSnapshot vs Key / Value vs ...)
- The number of writers and readers

Everything else is structural.

### The remaining gap between specification and implementation

Three gaps:

**1. The `select-ready` primitive.** The program loop ends with
"wait for next observation or query." This requires a select/poll
over 11 + 22 = 33 receivers. In Rust, this is either
`crossbeam::Select` or a custom poll loop. The wat specification
uses `select-ready` as if it exists. It doesn't exist as a
primitive yet. This is the one mechanism the pattern needs that
isn't defined. It's not hard — but it must be specified before
implementation.

**2. The snapshot copy semantics.** `PivotSnapshot` contains a
`Vec<PivotRecord>` (up to 20 entries) and a `CurrentPeriod`.
The driver builds this and sends it through a bounded(1) channel.
Is this a clone? A move? The bounded(1) channel means there's at
most one snapshot in flight per handle — the exit consumes it
before querying again. Move semantics are natural here. But the
wat doesn't say. The Rust will need to decide: Clone + send, or
move the Vec out and rebuild. Given bounded(1), move is correct
and the Vec can be reused via a return path or simply reallocated
(20 PivotRecords is ~2KB — allocation is not the bottleneck).

**3. The debounce from 045.** Question 3 in 045 asks whether a
direction change within a pivot period should force a new period.
Question 4 asks about minimum gap duration to prevent flickering.
These are specified as open questions but never resolved in
046-048. The state machine in 045 has no debounce — a single
candle below threshold starts a gap immediately. This will
produce noisy transitions. The implementation will need a
debounce parameter (minimum N candles to confirm a transition).
This is a tuning constant, not an architectural gap — but it
should be specified before the Rust is written, or the first
runs will produce pivot sequences full of single-candle gaps.

---

## Summary

The 044-048 arc is a clean categorical decomposition: domain
objects, then algebra, then three wrong topologies, then the
correct topology, then the correct read interface. Each proposal
refines without invalidating. The single-writer service pattern
is fully specified as a shape. The three remaining gaps are
mechanical (select primitive, copy semantics, debounce parameter),
not architectural. The diagram commutes. The factoring is complete.
The pattern is ready for implementation.

The REALIZATION document is particularly good. "Mailbox = fan-in
for writes. Dedicated queues = per-caller for reads." This is
the kind of sentence that should survive into whatever stdlib
documentation eventually describes this pattern. It's the
one-line version of the categorical distinction between
coproducts (fan-in, identity lost) and products (per-caller,
identity preserved).

Approved.
