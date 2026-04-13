# Resolution: Proposal 047 — Pivot Tracker Program

**Decision: APPROVED. Unanimous. No debate needed.**

Five designers. Five approvals. Zero tensions.

## The pivot tracker is a program

Like the cache. Like the database. Like the console. The
pivot tracker is a stdlib program — a single-writer service.
One thread. N writers (11 market observer tick queues). M
readers (exit observer query/reply channels). Drain writes
before reads. No contention. No Mutex.

## The principle — confirmed by all five

The main thread is the kernel. It provides mechanism. Programs
provide policy. The kernel wires, schedules, routes. It does
NOT compute, enrich, transform, or hold domain state.

046's Option A was wrong. All three options in 046 placed
domain logic on the orchestrator. None asked "should this
state be on the main thread at all?" The answer: no.

## The invariant — Van Tharp's condition

The market observer must send the tick to the pivot tracker
BEFORE sending its MarketChain back to the main thread.

```scheme
;; In the market observer thread:
(send! tick-tx (pivot-tick ...))    ;; unbounded — to pivot tracker
(send! chain-tx (market-chain ...)) ;; bounded(1) — to main thread
```

This guarantees: by the time the main thread collects the
chain and dispatches to exit observers, the tick is already
in the pivot tracker's queue. The drain-before-read invariant
seals the freshness.

This ordering is an explicit contract, not a structural
assumption.

## The factoring — Beckman + Hickey

The pivot tracker is the third instance of the single-writer
service pattern (after the encoder cache and the log service).
This is a stdlib pattern:

```
Single-writer service:
  - One thread owns state
  - N producers write through unbounded queues
  - M consumers query through bounded(1) request/reply
  - Drain writes before serving reads
  - Channels are the boundary
```

If written a fourth time, extract as a generic stdlib form.

## Telemetry — Beckman's recommendation

`emit_metric` through `db-tx`. Emit on state transitions
(pivot/gap boundary completions), not per-tick. One aggregate
heartbeat per drain pass. Same pattern as every other program.

## The full 044-047 picture

```
044: WHAT — pivot vocabulary, biography, Sequential, gaps
045: WHO  — post detects, exit interprets, N=500, 80th pctile
046: HOW  — (corrected by 047)
047: WHERE — a dedicated program. Cache pattern. Kernel is only kernel.
```

Four proposals. One architecture. Ready to build.
