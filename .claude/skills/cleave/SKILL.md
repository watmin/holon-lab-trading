---
name: cleave
description: Split cleanly along the grain. Verify that parallel boundaries are disjoint. Parts that do not touch.
argument-hint: [file-path or directory]
---

# Cleave

> A cleaver divides into parts that do not touch.

The eleventh ward. Parallelism safety. When the guide says "parallel —
disjoint slots, lock-free," does the wat's logic guarantee it?

## How it works

The agent reads the guide's CSP section and the enterprise's four-step
loop. Then reads the wat files that contain parallel operations (pmap,
pfor-each, par_iter). For each parallel boundary, the agent verifies:

1. **Disjoint writes** — does each parallel invocation write to its
   own slot? If two iterations could write to the same field, the
   cleave is dirty. The slots must be disjoint. The borrow checker
   in Rust will enforce this — but the wat should make it obvious.

2. **No shared mutation** — during a parallel phase, is any shared
   state mutated? The ThoughtEncoder cache was the original example:
   parallel observers writing to the same LRU. The fix was miss-queues.
   Are there other shared mutations hiding in the parallel phase?

3. **collect() synchronization** — after a parallel phase, does
   collect() (or its equivalent) gather all results before the
   sequential phase begins? Is there a gap where parallel results
   exist but haven't been collected?

4. **Sequential phases are sequential** — the propagation step, the
   trigger update step, the fund step — these must NOT be parallel.
   They touch shared observers, shared treasury state. Verify that
   no parallel form appears in a sequential step.

## What the agent reads

- `wat/GUIDE.md` — the CSP section, the four-step loop, the parallelism claims
- `wat/enterprise.wat` — the step orchestration
- `wat/post.wat` — the N×M composition loop (pmap over market observers)
- `wat/broker.wat` — tick-papers (parallel per broker)
- Any file that uses `pmap` or `pfor-each`

## The principle

Parallel code that shares state is broken code. The cleave verifies
that every parallel boundary is a clean split — disjoint writes,
no shared mutation, proper synchronization. The enterprise claims
"lock-free" and "disjoint slots." The cleave proves it — or finds
where the claim is a lie.

A cleaver divides along the grain. If the grain is wrong — if the
data doesn't naturally separate into disjoint slots — the cleave
reveals it. You can't cleave against the grain without violence.
