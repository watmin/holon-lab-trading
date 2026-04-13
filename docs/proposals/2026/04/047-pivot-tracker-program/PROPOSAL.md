# Proposal 047 — Pivot Tracker Program

**Scope:** userland

**Depends on:** 045 (pivot mechanics), 046 (pivot pipes)

**Corrects:** 046's Option A (enrich chain on main thread).

**Principle:** The main thread is the kernel. It wires programs.
It sends candles. It collects outputs. It schedules. It does
NOT compute, enrich, transform, or hold domain state. The
moment domain logic lives on the main thread, orchestration
is complected with thinking. The main thread must be ONLY a
kernel for programs. Putting anything on it that isn't
scheduling will be a failure.

046's Option A was wrong because it placed tracker state and
tick logic on the main thread. The five designers missed it
because all three options were flavors of the same mistake —
none proposed a program. The pivot tracker is a PROGRAM, like
the cache, like the database, like the console. Many writers,
many readers, concurrent access. The program owns the state.
The channels are the boundary.

## Why a program

The market observers are on their own threads. They produce
conviction every candle. They need to WRITE to the tracker.

The exit observers are on their own threads. They need to
READ the tracker when THEY need it — not when the main thread
pushes data to them.

This is the cache pattern:

```scheme
;; The cache:
;;   N writers send sets (fire and forget, unbounded)
;;   M readers send gets (request/response, bounded(1))
;;   One thread. Drain sets before gets. No contention.

;; The pivot tracker:
;;   11 market observers send ticks (fire and forget, unbounded)
;;   exit observers send queries (request/response, bounded(1))
;;   One thread. Drain ticks before queries. No contention.
```

## The data store

```scheme
(struct pivot-tracker-state
  trackers)   ;; Vec<TrackerState>, length 11, indexed by market_observer_idx

(struct tracker-state
  conviction-history    ;; RollingPercentile, N=500
  current-period        ;; CurrentPeriod — what we're in right now
  pivot-memory)         ;; VecDeque<PivotRecord>, bounded 20

(struct current-period
  kind            ;; :pivot or :gap
  direction       ;; :up or :down (pivots only)
  start-candle    ;; when it began
  close-sum       ;; running
  volume-sum      ;; running
  high            ;; running max
  low             ;; running min
  conviction-sum  ;; running (pivots only)
  count)          ;; candles in this period

(struct pivot-record
  kind            ;; :pivot or :gap
  direction       ;; :up or :down (pivots only)
  candle-start
  candle-end
  duration
  close-avg
  volume-avg
  high
  low
  conviction-avg) ;; pivots only, 0.0 for gaps
```

## The write interface

The market observer thread sends a tick after encoding each
candle. Fire and forget. Unbounded queue — the tracker drains
at its own pace.

```scheme
(struct pivot-tick
  market-idx      ;; which of the 11 market observers
  conviction      ;; this candle's conviction
  direction       ;; :up or :down — the prediction
  candle          ;; candle number
  close           ;; close price
  volume)         ;; volume

;; From the market observer thread:
(send! tick-tx (pivot-tick idx conviction direction candle close volume))
```

Each market observer has its own tick queue (unbounded).
11 queues. The program drains all 11 before serving reads.

## The read interface

The exit observer thread queries for a specific market
observer's pivot state. Request/response. Bounded(1) reply
channel — the exit blocks until the tracker responds.

```scheme
(struct pivot-query
  market-idx      ;; which tracker to read
  reply-tx)       ;; bounded(1) QueueSender — where to send the answer

(struct pivot-snapshot
  records         ;; Vec<PivotRecord>, bounded 20 — completed periods
  current-period) ;; CurrentPeriod — what we're in now

;; From the exit observer thread:
(send! query-tx (pivot-query market-idx reply-tx))
(let ((snapshot (recv! reply-rx)))
  ;; snapshot.records = the series, bounded 20
  ;; snapshot.current-period = in-progress period
  ;; Apply significance filter
  ;; Build Sequential thought
  ...)
```

Each exit observer has its own query queue (bounded(1)) and
reply queue (bounded(1)). The exit sends a query, blocks on
the reply. The tracker responds immediately from its internal
state — no computation, just a snapshot.

## The program

```scheme
(define (pivot-tracker-program
          tick-rxs        ;; 11 QueueReceivers — one per market observer
          query-rx        ;; MailboxReceiver — queries from all exit slots
          db-tx           ;; telemetry
          trackers)       ;; the initial state (11 TrackerStates)

  (loop
    ;; 1. Drain ALL ticks from ALL market observers.
    ;;    Process every pending write before serving any read.
    ;;    Same as cache: drain sets before gets.
    (for-each tick-rxs
      (lambda (rx idx)
        (drain! rx
          (lambda (tick)
            (tracker-tick! (ref trackers (:market-idx tick))
              (:conviction tick)
              (:direction tick)
              (:candle tick)
              (:close tick)
              (:volume tick))))))

    ;; 2. Service ALL pending queries.
    ;;    Each query: look up the tracker, build a snapshot, reply.
    (drain! query-rx
      (lambda (query)
        (let* ((tracker (ref trackers (:market-idx query)))
               (snapshot (pivot-snapshot
                           (:pivot-memory tracker)
                           (:current-period tracker))))
          (send! (:reply-tx query) snapshot))))

    ;; 3. Wait for the next tick or query.
    (select-ready tick-rxs query-rx)))
```

## The wiring (in wat-vm)

```scheme
;; At construction time:

;; 11 tick queues — one per market observer
(define tick-queues (map (lambda (_) (new-queue :unbounded)) (range 11)))
(define tick-txs (map queue-sender tick-queues))
(define tick-rxs (map queue-receiver tick-queues))

;; Query mailbox — all exit slots send queries here
(define query-queues (map (lambda (_) (new-queue :bounded 1)) exit-slots))
(define query-mailbox (new-mailbox (map queue-receiver query-queues)))

;; Reply queues — one per exit slot
(define reply-queues (map (lambda (_) (new-queue :bounded 1)) exit-slots))

;; Wire market observers: each gets a tick-tx
;; Wire exit observers: each gets a query-tx + reply-rx
;; Spawn the program on its own thread
(spawn pivot-tracker-program tick-rxs query-mailbox db-tx (initial-trackers))
```

## The topology

```
market-observer-0 ──tick-tx──→ ┐
market-observer-1 ──tick-tx──→ │
...                            ├──→ pivot-tracker-program ──→ (telemetry)
market-observer-10 ──tick-tx──→┘         ↑↓
                                    query/reply
                                     ↑↓    ↑↓
                              exit-slot-0  exit-slot-1 ...
```

Market observers write. Exit observers query. The program
mediates. One thread. Drain writes before reads. No contention.
No Mutex. Channels are the boundary.

## What this corrects from 046

046 said "enrich the chain on the main thread." That placed
the tracker logic on the orchestrator. The orchestrator should
orchestrate, not think. The pivot tracker is a thinker — it
maintains state, processes a stream, serves queries. That's a
program.

The MarketChain does NOT grow. The pivot records do NOT ride
the chain. The exit observer queries the tracker directly
through its own channel. The chain stays lean. The programs
stay separate. Each program does one thing.

## Questions for designers

### Strategy designers (Seykota, Van Tharp, Wyckoff)

1. **The query timing:** the exit observer queries the tracker
   per-slot, per-candle. With 2 exit observers × 11 market
   pairings = 22 queries per candle. Each query returns a
   snapshot immediately (no computation — just copy the
   bounded memory). Is this the right frequency?

2. **The tick timing:** the market observer sends a tick AFTER
   encoding and predicting. The tracker receives it before the
   exit observer queries. Is this ordering guaranteed by the
   pipe topology? (The main thread collects market chains
   before sending to exits — the ticks arrive first.)

### Architecture designers (Hickey, Beckman)

3. **The program pattern:** is this the right factoring? A
   program that receives writes from N producers and serves
   reads from M consumers. The cache does this. The database
   does this. The pivot tracker does this. Is this a stdlib
   pattern or an application pattern?

4. **Tick ordering:** market observers are on separate threads.
   Their ticks arrive in nondeterministic order. Does the
   tracker need to process ticks in candle order? Or is it
   safe to process in arrival order? (Each tracker is
   independent — market observer 3's tick doesn't affect
   market observer 7's state.)

5. **Telemetry:** the pivot tracker should report to the
   database. Pivot counts, period durations, conviction
   distributions. What is the telemetry interface? The same
   `emit_metric` pattern as the other programs?
