# Proposal 048 — Pivot Tracker Handles

**Scope:** userland

**Corrects:** Proposal 047 (shared mailbox for reads → per-caller handles)

**See:** [REALIZATION.md](REALIZATION.md) — why a mailbox is wrong for reads.

## The correction

047 specified a shared mailbox for exit observer queries. The
cache uses dedicated per-caller queues. The pivot tracker
should follow the same pattern.

## The handle

Each exit slot gets a PivotHandle — its own dedicated
query/reply pair. Like the cache's CacheHandle.

```scheme
(struct pivot-handle
  market-idx    ;; which tracker this handle reads — known at construction
  query-tx      ;; QueueSender<()> — "I need a snapshot" (the who is the pipe)
  reply-rx)     ;; QueueReceiver<PivotSnapshot> — the answer

(define (pivot-query! handle)
  ;; The handle already knows which market-idx it reads.
  ;; The query doesn't carry the idx — the pipe IS the identity.
  ;; Send a unit signal. Block on reply.
  (send! (:query-tx handle) ())
  (recv! (:reply-rx handle)))
```

The query is `()` — a unit. The handle knows its market-idx.
The driver knows which handle maps to which tracker because
the wiring is structural. No routing field. No reply-tx in
the message. The pipe IS the identity.

## The driver

```scheme
(define (pivot-tracker-program
          observation-rxs     ;; 11 QueueReceivers — writes from market observers
          query-rxs           ;; Vec<QueueReceiver<()>> — one per exit slot
          reply-txs           ;; Vec<QueueSender<PivotSnapshot>> — one per exit slot
          slot-to-market      ;; Vec<usize> — maps slot index to market observer idx
          db-tx               ;; telemetry
          )

  (let ((trackers (make-vector 11 (new-tracker))))

    (loop
      ;; Phase 1: drain ALL observations
      (for-each-with-index observation-rxs
        (lambda (idx rx)
          (drain! rx
            (lambda (obs)
              (tracker-observe! (ref trackers idx) obs)))))

      ;; Phase 2: service ALL pending queries — per-caller try_recv
      (for-each-with-index query-rxs
        (lambda (slot-idx rx)
          (when (try-recv! rx)
            ;; This slot wants a snapshot. Which tracker?
            (let* ((market-idx (ref slot-to-market slot-idx))
                   (snapshot (tracker-snapshot (ref trackers market-idx))))
              (send! (ref reply-txs slot-idx) snapshot)))))

      ;; Wait for next observation or query
      (select-ready observation-rxs query-rxs))))
```

The driver loops over query-rxs with try_recv — same as the
cache loops over get queues. Each slot's query arrives on its
own queue. The driver knows the slot index from the loop.
`slot-to-market` maps slot → market observer idx. The snapshot
goes back on the matching reply-tx.

## The wiring

```scheme
;; At construction:

;; 11 observation queues — one per market observer (writes)
(define observation-queues (map (lambda (_) (new-queue :unbounded)) (range 11)))
(define observation-txs (map queue-sender observation-queues))
(define observation-rxs (map queue-receiver observation-queues))

;; Per-exit-slot query/reply pairs (reads)
;; With 2 exit observers × 11 market pairings = 22 slots
(define num-slots 22)
(define query-queues  (map (lambda (_) (new-queue :unbounded)) (range num-slots)))
(define reply-queues  (map (lambda (_) (new-queue :unbounded)) (range num-slots)))

(define query-txs  (map queue-sender query-queues))
(define query-rxs  (map queue-receiver query-queues))
(define reply-txs  (map queue-sender reply-queues))
(define reply-rxs  (map queue-receiver reply-queues))

;; slot-to-market mapping: slot 0 → market 0, slot 1 → market 0,
;; slot 2 → market 1, slot 3 → market 1, ...
;; (2 exit observers per market observer)
(define slot-to-market (map (lambda (i) (/ i 2)) (range num-slots)))

;; Build handles — one per exit slot
(define pivot-handles
  (map (lambda (i)
    (pivot-handle (ref slot-to-market i) (ref query-txs i) (ref reply-rxs i)))
    (range num-slots)))

;; Wire market observers: each gets observation-txs[idx]
;; Wire exit slots: each gets pivot-handles[slot-idx]
;; Spawn the program
(spawn pivot-tracker-program
  observation-rxs query-rxs reply-txs slot-to-market db-tx)
```

## The topology

```
WRITES (fire and forget, unbounded, into mailbox):
  market-observer-0  → observation-rx[0]  ┐
  market-observer-1  → observation-rx[1]  │
  ...                                     ├→ pivot-tracker-program
  market-observer-10 → observation-rx[10] ┘

READS (per-caller, dedicated queues):
  exit-slot-0:  query-tx[0]  →  program  →  reply-tx[0]
  exit-slot-1:  query-tx[1]  →  program  →  reply-tx[1]
  ...
  exit-slot-21: query-tx[21] →  program  →  reply-tx[21]
```

22 dedicated read channels. 11 write channels into a mailbox.
The driver drains writes, then loops over reads with try_recv.
The pipe IS the identity. No routing in the messages.

## The exit observer's usage

```scheme
;; The exit observer has a pivot-handle per slot. Provided at construction.
(define (exit-observer-on-slot slot chain pivot-handle)
  ;; Query the tracker — one line. Blocks on reply.
  (let* ((snapshot (pivot-query! pivot-handle))

         ;; Apply significance filter — stateless
         (significant (filter significant? (:records snapshot)))

         ;; Build Sequential thought
         (series (sequential (map period->thought significant)))

         ;; Bundle with trade atoms and market extraction
         ...)
    ...))
```

One function call. `(pivot-query! handle)`. The handle knows
its market-idx. The pipe routes. The driver responds. The exit
gets a snapshot. Clean.

## What this corrects from 047

| 047 | 048 |
|-----|-----|
| Shared mailbox for reads | Per-caller dedicated queues |
| Query carries market-idx + reply-tx | Query is `()` — the pipe IS the identity |
| Driver routes by message content | Driver routes by queue index |
| Allocates sender per query | Zero allocation per query |

## What doesn't change from 047

- The program pattern (one thread, drain writes before reads)
- The data store (11 TrackerStates)
- The observation protocol (fire and forget from market observers)
- The state machine (pivot/gap with debounce and direction flip)
- The principle (kernel is only kernel)

## Questions for designers

1. **The query signal:** is `()` (unit) the right message?
   Or should the query carry context (e.g., the candle number
   for staleness checking)? The cache's get carries a key.
   The pivot handle's key is structural (the pipe). Is unit
   sufficient?

2. **Queue type for queries:** unbounded or bounded(1)?
   The exit blocks on the reply — it only sends one query
   at a time. Bounded(1) enforces this. Unbounded is
   unnecessary slack. Which is correct?

3. **The slot-to-market mapping:** is a Vec<usize> the right
   structure? It's fixed at construction. An array would be
   more precise. Does it matter?
