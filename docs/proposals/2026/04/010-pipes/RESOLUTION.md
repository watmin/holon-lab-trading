# Resolution: Proposal 010 — Everything Is a Pipe

**Date:** 2026-04-10
**Decision:** CONDITIONALLY ACCEPTED

## Designers' verdict

Both conditionally accepted. Both recognized this is NOT what they
rejected in Proposal 001.

**Hickey:** "No, I was not wrong about channels. And no, this is not
what I rejected." `bounded(1)` is a rendezvous, not a queue. The fold
is preserved — fractally. Each pipe has its own heartbeat. Three
conditions: replay determinism, error/shutdown semantics, no `select!`.

**Beckman:** "Bounded(1) channels are the identity natural transformation
on composition. The diagram commutes." Four invariants: bounded(1),
one-in-one-out, product fan-out (clone, not compete), propagation
outside the pipes.

## The conditions

Both designers converge on the same constraints from different axioms:

1. **bounded(1) is sacred.** No buffering. No backpressure. Pure
   rendezvous. The producer yields, blocks, the consumer takes.
   Lazy enumerator across thread boundaries.

2. **Replay determinism.** Fan-out must be product (each observer
   gets a clone), not coproduct (observers compete). Scheduling
   order must not affect final state. Prove observer independence.

3. **Propagation outside the pipes.** Shared observer mutation
   (step 3b) must happen at a synchronization barrier, not inside
   the concurrent pipes. The `collect()` pattern.

4. **No select.** The moment `select!` appears, the fold is lost.
   That is the line.

## The decision

Build it. The binary changes. The library doesn't. Each unit becomes
a thread with bounded(1) channels. The N×M grid IS the channel
topology. The fold IS the pipe. The pipe IS the fold.

The conditions are the implementation contract. Violate any one and
the catamorphism breaks.

## What the designers taught us

They were not wrong. They rejected nondeterministic channels (`select!`,
unbounded queues, event-driven soup). They approved the fold. The
fold IS bounded(1) channels. The approval was always there — we just
hadn't found the form that both names describe the same thing.

The lazy enumerator IS the bounded(1) channel IS the fold across
thread boundaries IS the pipe. Four names. One mechanism.
