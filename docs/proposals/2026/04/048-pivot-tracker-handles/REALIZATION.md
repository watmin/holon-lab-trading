# Realization: Why a mailbox is wrong for reads

**Linked to:** Proposal 047 (pivot tracker program)
**Corrected by:** Proposal 048

## The error

047 specified reads through a shared mailbox:

```scheme
;; 047's design (WRONG):
;; All exit slots send queries through one mailbox.
;; The query carries a reply-tx so the driver can respond.
(send! query-tx (pivot-query market-idx reply-tx))
```

This is wrong. The cache does not do this. The cache uses
dedicated per-caller queues for reads.

## Why it's wrong

A mailbox is fan-in: N producers → 1 consumer. The consumer
drains all messages from all producers through one receiver.
The messages are interleaved. The consumer does not know WHO
sent what until it reads the message.

For writes this is fine — the pivot tracker drains all
observations and processes them. The observation carries the
market-idx. The tracker routes to the right internal state.
Who sent it doesn't matter — only what's in the message.

For reads this is wrong. A read is request/response. The
caller sends a query and BLOCKS waiting for a reply. If all
callers share one mailbox:

1. **Lost routing.** The driver receives a query from the
   mailbox but the mailbox consumed the message from an
   arbitrary queue. The driver must route the response back
   through the reply-tx embedded in the query. This works
   but it means every query allocates and carries a sender.
   Wasteful. The routing was known at construction time.

2. **Head-of-line blocking.** If exit-slot-0 and exit-slot-1
   both send queries, the mailbox interleaves them. The driver
   processes them in arrival order. Exit-slot-1's query might
   sit behind exit-slot-0's. With dedicated queues, the driver
   loops over all queues with try_recv — no ordering dependency.

3. **The identity is the pipe.** With per-caller queues, the
   driver knows WHO asked by WHICH queue the message arrived on.
   No routing field in the message. No reply-tx in the query.
   The pipe IS the identity. Query arrives on queue[3] → the
   answer goes back on reply[3]. The wiring is structural, not
   data.

4. **The cache pattern.** The cache gives each client a
   CacheHandle with its own get_tx/get_rx pair. The driver
   loops over all get queues with try_recv after draining
   sets. This is proven. It works. It's contention-free.
   The pivot tracker should follow the same pattern.

## The fix

Per-caller handles. Each exit slot gets a PivotHandle with
its own dedicated query/reply queue pair. The driver loops
over all query queues. The pipe IS the identity.

## The lesson

Mailbox = fan-in for writes. Dedicated queues = per-caller
for reads. The cache already knew this. We forgot to look.
