# Ignorant Ward — Services Review

Reviewed: 2026-04-11
Files: `src/services/queue.rs`, `src/services/topic.rs`, `src/services/mailbox.rs`, `src/services/mod.rs`
Ward: /ignorant — reads as a stranger, knows nothing about the project.

---

## queue.rs

### Understanding

Clear immediately. The module comment says it all: "point-to-point. One
producer, one consumer. The atom." The implementation is a thin newtype
wrapper over crossbeam channels. `QueueSender` wraps `Sender<T>`,
`QueueReceiver` wraps `Receiver<T>`. Two constructors: bounded and unbounded.
Error types are project-local re-exports of crossbeam's semantics.

Nothing confused me. The `inner()` method on `QueueReceiver` is the one
unusual decision — it grants `pub(crate)` access to the raw crossbeam
`Receiver` for select-based composition. The comment explains why
("services that compose queues"). That is the right scope.

### Soundness

No bugs found. No race conditions — crossbeam channels are thread-safe by
design. No deadlock paths visible. Shutdown is handled correctly: dropping
`QueueSender` disconnects the channel; `recv()` returns `Disconnected`.

### Tests

Four tests. They cover:
- Single message round-trip
- Ordering over 100 messages
- Bounded backpressure (actually blocks a thread and unblocks it)
- Shutdown: sender dropped → receiver gets `Disconnected`

All four test real contracts, not just happy-path mechanics. The backpressure
test uses `thread::sleep(50ms)` as a timing crutch — this is a minor smell
(it assumes 50ms is enough for the blocking thread to reach the send call
before the receiver drains), but it is a well-understood pattern for
bounded-channel tests and unlikely to flake in practice.

---

## topic.rs

### Understanding

Clear. Module comment: "fan-out. One producer, N consumers. The producer
writes once. All consumers receive a clone." The implementation spawns a
fan-out thread: one inbound channel, N outbound channels, one clone per
subscriber per message.

One thing a stranger must notice: `TopicHandle` holds a `JoinHandle` prefixed
with `_`. The comment says "Dropping this does NOT stop the thread — the
thread exits when the sender is dropped." This is correct — the fan-out thread
blocks on `in_rx.recv()` and exits when `in_rx` disconnects (i.e., when
`TopicSender` is dropped). The `_handle` field exists only to keep the
`JoinHandle` alive so the thread is not detached. The naming (`_handle`)
implies "intentionally unused" which is slightly misleading — it IS used
(to keep the thread joinable), it just isn't manually joined. A clearer name
would be `_keepalive` or `_thread`.

A subtle consequence: if the caller drops `_handle` independently of the
sender (e.g., destructures the tuple and ignores it), the `JoinHandle` is
dropped, the thread becomes detached but continues running until the sender
drops. This is not a bug — it is the documented contract — but it is
non-obvious for a stranger.

### Soundness

No race conditions. No deadlock paths. Shutdown cascade is correct:
`TopicSender` dropped → `in_tx` dropped → fan-out thread `in_rx.recv()`
returns `Err` → loop exits → `out_txs` dropped → all `TopicReceiver`s
see `Disconnected`.

One design question: if a subscriber's channel is full (bounded), `tx.send()`
on that subscriber will block the fan-out thread, which blocks ALL other
subscribers from receiving. The code silently skips disconnected subscribers
(`let _ = tx.send(...)`) but does NOT skip full/blocked ones. Under backpressure
from one slow subscriber, the entire fan-out stalls. This may be intentional
(the system wants backpressure to propagate) but it is not documented.

### Consistency with queue.rs

Error types follow the same pattern (`SendError<T>`, `RecvError`). Method
names match (`send`, `recv`, `try_recv`). The pattern is consistent.

`topic.rs` does NOT use `QueueSender`/`QueueReceiver` — it reaches directly
into `crossbeam::channel`. See the composition claim section below.

### Tests

Three tests:
- One message reaches all subscribers
- N messages in order for each subscriber
- Shutdown: sender dropped → all receivers get `Disconnected`

Shutdown IS tested. Order IS tested. What is NOT tested: partial subscriber
disconnect (one receiver drops mid-run — does the fan-out thread continue
serving remaining subscribers?). The code says `let _ = tx.send(...)` which
means yes, but this is untested. Also untested: backpressure behavior (one
slow subscriber stalling the others).

---

## mailbox.rs

### Understanding

Clear. Module comment: "fan-in. N producers, one consumer. Composed of N
independent queues. Each producer gets its OWN sender (contention-free)."
The implementation creates N independent input queues, one output queue, and
a fan-in thread that uses `crossbeam::channel::Select` to multiplex them.

`MailboxSender` is explicitly documented as NOT cloneable — each producer
owns its own sender. This is enforced structurally (no `#[derive(Clone)]`).

The fan-in thread's `alive.remove(idx)` path is correct: when an input
disconnects, it is removed from the select set. When the set empties, the
loop breaks, `out_tx` drops, and the consumer sees `Disconnected`.

### Soundness

No race conditions. No deadlock paths.

One soundness issue: `out_tx.send(msg)` is silently discarded with `let _ =`.
If the consumer drops `MailboxReceiver` while producers are still sending, the
fan-in thread silently swallows messages rather than propagating the
disconnect back to producers. This is consistent with how `QueueSender::send`
returns a `Result` that callers can ignore — but the fan-in thread ignores it
unconditionally, which means producers never learn the consumer is gone. This
is a bounded concern (the thread will eventually exit when all inputs
disconnect), but it is worth noting.

### Composition claim

`mailbox.rs` DOES compose from queues. It imports `queue_unbounded`,
`QueueSender`, `QueueReceiver` from `crate::services::queue`. The N input
queues are `queue_unbounded()` calls. The output queue is `queue_unbounded()`.
The `inner()` accessor on `QueueReceiver` is used here exactly as intended.

### Consistency with queue.rs and topic.rs

Error types follow the same pattern. Method names match. Pattern is consistent.

One minor asymmetry: `MailboxSender` does not expose `try_recv` (it is a
sender, so that is correct), but `MailboxReceiver` exposes both `recv` and
`try_recv`. This matches the queue and topic receivers. Consistent.

### Tests

Four tests:
- Multiple senders, one receiver (ordering not required — uses `HashSet`)
- Messages from different threads interleave (50 total, all received)
- Shutdown: all senders dropped → receiver gets `Disconnected`
- Partial sender drop: two of three senders dropped, third still works,
  then third dropped → `Disconnected`

This is the strongest test suite of the three. Shutdown is tested. Partial
disconnect is tested. The `thread::sleep(50ms)` before `try_recv` in the
interleave test is the same timing crutch as in queue — acceptable but
fragile on a very loaded machine.

---

## mod.rs

Three lines. Re-exports the three modules. The comment says "Pure
infrastructure. Each service is a thin wrapper today; threads come later
for observability." The phrase "thin wrapper today" is slightly inconsistent
— topic and mailbox already spawn threads. The comment reads as if the
modules are currently synchronous and threading is deferred, which is false.

---

## The Composition Claim

**Claim:** "The queue is the only atom — topic and mailbox compose from queues."

**Verdict:** Half true.

- `mailbox.rs`: TRUE. It imports and uses `queue_unbounded`, `QueueSender`,
  `QueueReceiver`. It composes from the queue abstraction. The `inner()`
  accessor exists precisely for this use case.

- `topic.rs`: FALSE. It reaches directly into `crossbeam::channel` and
  creates raw `Sender<T>` / `Receiver<T>` channels. It does not use
  `QueueSender` or `QueueReceiver` at all. This breaks the layering claim.
  A stranger reading the code cannot determine why topic bypasses the queue
  abstraction while mailbox does not.

The inconsistency is not a bug — `crossbeam::channel` is the correct tool
either way — but it violates the stated design principle. If the queue is
the atom, topic should build from it.

---

## Summary

| | Understanding | Soundness | Tests |
|---|---|---|---|
| queue.rs | Excellent | Clean | Honest, 4/4 |
| topic.rs | Good, one naming ambiguity | One undocumented stall risk | Good, missing partial-disconnect |
| mailbox.rs | Excellent | One silent discard | Best, 4/4 |

**Primary findings:**

1. `topic.rs` bypasses the queue abstraction — it is NOT composed from queues.
   The composition claim is only true for mailbox.

2. `topic.rs` has an undocumented backpressure behavior: one slow subscriber
   can stall all others. This may be intentional but should be stated.

3. `TopicHandle._handle` naming implies "unused" when it is used (to keep the
   thread joinable). Consider `_thread` or `_keepalive`.

4. `mod.rs` comment ("thin wrapper today; threads come later") is factually
   wrong — threads are already present in topic and mailbox.

5. `mailbox.rs` silently discards `out_tx.send()` errors — producers cannot
   detect a dead consumer. Minor but worth knowing.

6. No test exercises: topic partial-subscriber-disconnect, topic backpressure
   stall, or mailbox dead-consumer detection.

None of the above are blocking issues. The code is clean, readable, and
structurally correct. The biggest gap is the composition claim failing for
topic.
