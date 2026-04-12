# Ignorant Ward — Services Review (Third Pass)

Reviewed: 2026-04-11
Files: `src/services/queue.rs`, `src/services/topic.rs`, `src/services/mailbox.rs`, `src/services/mod.rs`
Ward: /ignorant — reads as a stranger, knows nothing about the project.
Prior passes: two rounds. All reported findings fixed. This pass seeks the fixed point.

---

## What the prior passes found and fixed

**Pass 1 findings (all fixed before pass 2):**
- Topic bypassed the queue abstraction — raw crossbeam channels, not `QueueSender`/`QueueReceiver`. FIXED.
- mod.rs comment said "thin wrapper today; threads come later." FIXED — now describes threads correctly.

**Pass 2 carry-forwards (documented, not structural bugs):**
- F1: topic.rs backpressure stall — one slow subscriber's full bounded queue blocks the fan-out thread, stalling all others. The comment in the fan-out loop now documents this explicitly.
- F2: mailbox.rs silent consumer-gone — `let _ = out_tx.send(msg)` discards errors when the consumer drops. The comment now documents this explicitly.

Both carry-forwards were noted as needing documentation. The question for this pass: is that documentation present?

---

## queue.rs — Third Pass

No changes since pass 2. Clean. The atom.

`inner()` scoped correctly at `pub(crate)`. Error types are project-local. Contracts match crossbeam semantics. Four tests covering send, order, backpressure, and disconnect.

**New findings: 0**

---

## topic.rs — Third Pass

The fan-out thread comment (lines 67–72):

```rust
// Bounded send: blocks if this subscriber's queue is full.
// One slow subscriber stalls all others — intentional
// backpressure propagation. The producer slows to match
// the slowest consumer. If a subscriber disconnected,
// the error is ignored (skipped).
let _ = tx.send(msg.clone());
```

The F1 carry-forward is resolved. The stall behavior is now documented inline with an explicit statement of intent: "intentional backpressure propagation." A stranger reading this will understand both what happens and why. No ambiguity remains.

Tests: three. One message to all subscribers, 50 messages in order, shutdown cascade. Partial-subscriber-disconnect remains untested — but the code path (`let _ = tx.send(...)` discards the error) is visible and commented. Not a finding.

**New findings: 0**

---

## mailbox.rs — Third Pass

The fan-in thread comment (lines 93–100):

```rust
// If the consumer (MailboxReceiver) dropped, the send
// fails silently. Messages are discarded. Producers
// receive no signal — they keep sending until they
// themselves drop. This is intentional: the fan-in
// thread's lifecycle is governed by its INPUTS, not
// its output. When all inputs disconnect, the thread
// exits and the output drops.
let _ = out_tx.send(msg);
```

The F2 carry-forward is resolved. The silent consumer-gone behavior is now documented with a rationale: "the fan-in thread's lifecycle is governed by its INPUTS, not its output." The design choice is visible. A stranger will find it and understand it.

Four tests: multi-sender single-receiver, threaded interleave, full shutdown, partial sender drop. The partial-disconnect case is tested. The consumer-drop case is not exercised in tests, but the code comment covers it.

**New findings: 0**

---

## mod.rs — Third Pass

```rust
//! Messaging services — the foundational primitives of the wat-vm.
//!
//! The queue is the only atom. One in, one out. Contention-free.
//! Topic and mailbox are composed of queues:
//!   - Topic: one input queue, N output queues. Fan-out thread.
//!   - Mailbox: N input queues, one output queue. Fan-in thread via select.
//!
//! These are independent of the enterprise. Pure infrastructure.
```

Correct. Matches the implementation exactly. No divergence.

**New findings: 0**

---

## Verdict

**Fixed point reached.**

All pass-1 structural findings are fixed. All pass-2 carry-forwards are documented. The code now explains every non-obvious decision at the point of decision. A stranger reading any of these four files encounters no gap between what the code does and what it says.

| File | Pass 1 | Pass 2 | Pass 3 |
|---|---|---|---|
| queue.rs | 0 findings | 0 findings | 0 findings |
| topic.rs | 1 structural | 1 carry-forward (doc gap) | 0 findings |
| mailbox.rs | 1 structural | 1 carry-forward (doc gap) | 0 findings |
| mod.rs | 1 structural | 0 findings | 0 findings |

**New findings this pass: 0. The code teaches.**
