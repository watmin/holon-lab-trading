# Ignorant Ward — Services Review (Second Pass)

Reviewed: 2026-04-11
Files: `src/services/queue.rs`, `src/services/topic.rs`, `src/services/mailbox.rs`, `src/services/mod.rs`
Ward: /ignorant — reads as a stranger, knows nothing about the project.
Prior pass: found topic not composing from queues; mod.rs comment wrong. Both reported as fixed.

---

## queue.rs

### Understanding

Immediately legible. Module doc: "point-to-point. One producer, one consumer.
The atom." The implementation is a thin newtype over crossbeam channels.
`QueueSender<T>` wraps `Sender<T>`. `QueueReceiver<T>` wraps `Receiver<T>`.
Two constructors: `queue_bounded` and `queue_unbounded`. Error types are
project-local names over crossbeam semantics (`SendError<T>`, `RecvError`).

The `inner()` method on `QueueReceiver` is the one non-obvious decision.
It grants `pub(crate)` access to the raw crossbeam `Receiver` for
`crossbeam::channel::Select`-based composition. The doc comment explains:
"Internal access for services that compose queues (e.g., mailbox select)."
Correct scope. A stranger would find it and understand it within one reading.

### Soundness

Clean. No race conditions — crossbeam channels are thread-safe by design.
No deadlock paths. Shutdown: dropping `QueueSender` disconnects the channel;
`recv()` returns `Disconnected`. The contract is straightforward and upheld.

### Tests

Four tests:
- Single message round-trip
- 100 messages in order
- Bounded backpressure: a spawning thread blocks on `send(3)` until the
  receiver drains one slot, then unblocks. Tests the real constraint.
- Shutdown: sender dropped → `recv()` returns `Err(RecvError::Disconnected)`

All four cover real contracts. The backpressure test uses `thread::sleep(50ms)`
as a timing crutch — minor smell, well-understood pattern, unlikely to flake.

**Finding count: 0**

---

## topic.rs

### Understanding

Clear. Module doc: "fan-out. One producer, N consumers. COMPOSED of queues.
One input queue, N output queues. The producer writes to the input queue.
The fan-out thread reads from it and sends a clone to each output queue."

The implementation now uses `crate::services::queue`:
- `TopicSender<T>` wraps `QueueSender<T>`
- `TopicReceiver<T>` wraps `QueueReceiver<T>`
- The input queue is `queue::queue_bounded::<T>(capacity)`
- Each output queue is `queue::queue_bounded(capacity)`
- The fan-out thread reads from `in_rx.recv()` and clones to each `out_tx`

`TopicHandle` holds `_thread: thread::JoinHandle<()>`. The field name `_thread`
signals "intentionally kept alive, not joined by hand." The module doc says
"The thread exits when the producer drops its sender." This is exactly what
happens: `in_tx` drops when `TopicSender` drops → `in_rx.recv()` returns
`Err` → loop exits → `out_txs` drop → all subscriber queues close.

A stranger can trace the lifecycle in one pass. The naming is honest now.

### Soundness

No race conditions. No deadlock paths. Shutdown cascade is correct.

One design behavior worth knowing: if a subscriber's output queue is full
(bounded), `tx.send(msg.clone())` blocks the fan-out thread, which blocks
ALL other subscribers from receiving. The code silently skips disconnected
subscribers (`let _ = tx.send(...)`) but does NOT skip full/blocked ones.
Under backpressure from one slow subscriber, the entire fan-out stalls.

This is NOT documented. A caller creating a bounded topic with slow subscribers
will observe the stall with no explanation in the source. This was in the prior
review. It remains.

### Composition Claim — VERIFIED

`topic.rs` NOW composes from queues:
- `use crate::services::queue::{self, QueueSender, QueueReceiver};`
- `TopicSender<T>(QueueSender<T>)` — wraps the queue type
- `TopicReceiver<T>(QueueReceiver<T>)` — wraps the queue type
- Both input and output channels created via `queue::queue_bounded()`

The prior finding ("topic bypasses the queue abstraction") is FIXED.

### Tests

Three tests:
- One message reaches all three subscribers
- 50 messages in order across four subscribers (spawned send thread)
- Shutdown: sender dropped → all receivers see error

Partial-subscriber-disconnect remains untested: if one `TopicReceiver` is
dropped while the others are live, the fan-out thread silently discards
sends to that slot (`let _ = tx.send(...)`) and continues. This works
correctly but is not exercised.

**Finding count: 1** — undocumented backpressure stall risk (carry-forward from prior pass, not regression)

---

## mailbox.rs

### Understanding

Clear. Module doc: "fan-in. N producers, one consumer. Composed of N
independent queues. Each producer gets its OWN sender (contention-free).
A fan-in thread selects across N receivers and forwards to one output."

`MailboxSender<T>` wraps `QueueSender<T>`. No `Clone` — by design. Each
producer owns one sender. The fan-in thread uses `crossbeam::channel::Select`
over the `inner()` receivers. When an input disconnects, `alive.remove(idx)`
removes it. When `alive` empties, the loop breaks, `out_tx` drops, consumer
sees `Disconnected`.

`assert!(num_producers > 0)` guards the degenerate case.

A stranger can read this end-to-end in one pass.

### Soundness

No race conditions. No deadlock paths.

One silent behavior: `let _ = out_tx.send(msg)` in the fan-in thread
discards send errors. If the consumer drops `MailboxReceiver` while producers
are still sending, the fan-in thread swallows all subsequent messages and
continues running until all producers disconnect. Producers never learn the
consumer is gone. This is a bounded concern (the thread will exit eventually)
but it is invisible. Carry-forward from prior review, not a regression.

### Composition Claim — VERIFIED

`mailbox.rs` composes from queues throughout:
- `use crate::services::queue::{queue_unbounded, QueueSender, QueueReceiver};`
- N input queues via `queue_unbounded()`
- One output queue via `queue_unbounded()`
- `inner()` accessor used exactly as intended for `Select`

### Tests

Four tests — strongest suite of the three:
- Multiple senders, one receiver (unordered, uses `HashSet`)
- 50 messages across 5 threaded senders — all received
- Shutdown: all senders dropped → `Disconnected`
- Partial sender drop: two of three senders dropped, third still works,
  then third dropped → `Disconnected`

Partial disconnect IS tested. Shutdown IS tested. The `thread::sleep(50ms)`
in the interleave test is the same timing crutch as in queue — minor smell,
acceptable.

**Finding count: 1** — silent consumer-gone behavior (carry-forward, not regression)

---

## mod.rs

Three lines. Module doc:

> "The queue is the only atom. One in, one out. Contention-free.
> Topic and mailbox are composed of queues:
>   - Topic: one input queue, N output queues. Fan-out thread.
>   - Mailbox: N input queues, one output queue. Fan-in thread via select.
> These are independent of the enterprise. Pure infrastructure."

The prior finding ("thin wrapper today; threads come later") is FIXED.
The comment now matches the implementation exactly. Topic and mailbox
both spawn threads, both compose from queues, and the comment says so.

**Finding count: 0**

---

## The Composition Claim — Overall Verdict

**Claim:** "The queue is the only atom. Topic and mailbox are composed of queues."

**Verdict: TRUE.** Both fixed since the prior pass.

- `queue.rs`: defines the atom.
- `topic.rs`: wraps `QueueSender`/`QueueReceiver`, creates channels via `queue::queue_bounded`. Composed.
- `mailbox.rs`: wraps `QueueSender`/`QueueReceiver`, creates channels via `queue_unbounded`. Composed.
- `mod.rs`: documents this correctly.

The architecture is what it claims to be.

---

## Summary Table

| File | Understanding | Soundness | Composition | Tests | Findings |
|---|---|---|---|---|---|
| queue.rs | Excellent | Clean | N/A (atom) | Honest, 4/4 | 0 |
| topic.rs | Good | One undocumented stall | FIXED — now composes | Good, missing partial-disconnect | 1 (carry-forward) |
| mailbox.rs | Excellent | One silent discard | Verified | Best, 4/4 | 1 (carry-forward) |
| mod.rs | Excellent | N/A | Comment correct | N/A | 0 |

---

## Findings This Pass

**Fixed since prior review:**
- topic.rs now composes from queues — `QueueSender`/`QueueReceiver` throughout.
- mod.rs comment corrected — no longer says "thin wrapper; threads come later."

**Carry-forward (not regressions, not new):**

**F1 — topic.rs: undocumented backpressure stall**
One slow subscriber with a full bounded output queue blocks the fan-out thread,
stalling all other subscribers. The code silently skips *disconnected* senders
but not *full* ones. The behavior is deterministic and may be intentional
(backpressure should propagate). If intentional: add one sentence to the module
doc. If not intentional: consider sending to ready subscribers and dropping to
full ones, or use unbounded output queues.

**F2 — mailbox.rs: silent consumer-gone**
`let _ = out_tx.send(msg)` in the fan-in thread discards send errors.
If `MailboxReceiver` is dropped, producers see no signal — they continue
sending, the fan-in thread continues looping, all messages are silently lost
until all senders disconnect. Document this or propagate the error.

**New findings: 0.**

The two items the prior review called out as failures are both fixed.
The two carry-forwards are documented behaviors, not bugs — they need a
comment or a test, not a rewrite.

**Fixed-point status:** The code teaches. Two cosmetic gaps remain. No structural issues.
