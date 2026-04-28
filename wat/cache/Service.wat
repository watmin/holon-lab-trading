;; :trading::cache::Service — L2 cache as a queue-addressed program.
;;
;; A long-running spawned program that owns a HologramLRU and serves
;; cache requests via a request queue. Each client gets a per-client
;; reply channel for Get; Put is fire-and-forget.
;;
;; Slice 1 minimal:
;;   - Request: Get(pos, probe, reply-tx) | Put(pos, key, val)
;;   - State:   HologramLRU (one per Service instance — cache-next or
;;              cache-terminal lives in its own Service)
;;   - Reply:   GetReply (Option<HolonAST>) sent on reply-tx
;;   - No telemetry yet (slice-1-followup); no L1 promotion yet
;;     (caller side concern); no cooperation between services
;;     (each one is independent).
;;
;; Pattern mirrors :svc::Request from wat-rs's service-template.wat:
;; one enum, three reply shapes, one handle fn per variant, one
;; driver loop selecting over the request queue.

;; ─── Reply channel typealiases ──────────────────────────────────

(:wat::core::typealias :trading::cache::GetReplyTx
  :wat::kernel::QueueSender<Option<wat::holon::HolonAST>>)

(:wat::core::typealias :trading::cache::GetReplyRx
  :wat::kernel::QueueReceiver<Option<wat::holon::HolonAST>>)

;; ─── Request enum ───────────────────────────────────────────────

(:wat::core::enum :trading::cache::Request
  (Get
    (pos :f64)
    (probe :wat::holon::HolonAST)
    (reply-tx :trading::cache::GetReplyTx))
  (Put
    (pos :f64)
    (key :wat::holon::HolonAST)
    (val :wat::holon::HolonAST)))

;; ─── Per-broker channel typealiases ─────────────────────────────

(:wat::core::typealias :trading::cache::ReqTx
  :wat::kernel::QueueSender<trading::cache::Request>)

(:wat::core::typealias :trading::cache::ReqRx
  :wat::kernel::QueueReceiver<trading::cache::Request>)

(:wat::core::typealias :trading::cache::ReqTxPool
  :wat::kernel::HandlePool<trading::cache::ReqTx>)

(:wat::core::typealias :trading::cache::Spawn
  :(trading::cache::ReqTxPool,wat::kernel::ProgramHandle<()>))

;; ─── Per-variant request handler ────────────────────────────────
;;
;; Get: cosine-readout via coincident-get (the strict variant —
;;      caller can promote to L1 if it wants); send Option<AST>
;;      back on the reply-tx. Send returns :wat::kernel::Sent;
;;      we discard (the caller may have dropped the reply channel
;;      and we move on).
;; Put: insert into the HologramLRU; no reply.
;;
;; Each variant returns the same (mutable) HologramLRU. The cell
;; mutates in place; threading the same store through the loop is
;; an Arc bump.

(:wat::core::define
  (:trading::cache::Service/handle
    (req :trading::cache::Request)
    (cache :wat::holon::HologramLRU)
    -> :wat::holon::HologramLRU)
  (:wat::core::match req -> :wat::holon::HologramLRU
    ((:trading::cache::Request::Get pos probe reply-tx)
      (:wat::core::let*
        (((result :Option<wat::holon::HolonAST>)
          (:wat::holon::HologramLRU/coincident-get cache pos probe))
         ((_send :wat::kernel::Sent)
          (:wat::kernel::send reply-tx result)))
        cache))
    ((:trading::cache::Request::Put pos key val)
      (:wat::core::let*
        (((_ :()) (:wat::holon::HologramLRU/put cache pos key val)))
        cache))))

;; ─── Driver loop — select over Vec<ReqRx> ──────────────────────
;;
;; Same shape as service-template's Service/loop. Empty rxs → exit
;; with the final state. Otherwise select; on Some(req) dispatch +
;; recurse; on :None prune the closed channel and recurse.

(:wat::core::define
  (:trading::cache::Service/loop
    (req-rxs :Vec<trading::cache::ReqRx>)
    (cache :wat::holon::HologramLRU)
    -> :wat::holon::HologramLRU)
  (:wat::core::if (:wat::core::empty? req-rxs) -> :wat::holon::HologramLRU
    cache
    (:wat::core::let*
      (((chosen :wat::kernel::Chosen<trading::cache::Request>)
        (:wat::kernel::select req-rxs))
       ((idx :i64) (:wat::core::first chosen))
       ((maybe :Option<trading::cache::Request>) (:wat::core::second chosen)))
      (:wat::core::match maybe -> :wat::holon::HologramLRU
        ((Some req)
          (:wat::core::let*
            (((next :wat::holon::HologramLRU)
              (:trading::cache::Service/handle req cache)))
            (:trading::cache::Service/loop req-rxs next)))
        (:None
          (:trading::cache::Service/loop
            (:wat::std::list::remove-at req-rxs idx)
            cache))))))

;; ─── Worker entry — owns the cache for its full lifetime ──────
;;
;; HologramLRU's underlying LocalCache is thread-owned (lives in a
;; ThreadOwnedCell), so the cache MUST stay on the worker thread.
;; The driver loop returns the final cache at shutdown but the only
;; valid thing to do with it is drop it. Service/run wraps Service/loop
;; so the spawned handle resolves to :() — caller-friendly type, no
;; thread-affinity foot-gun. Live cache state is only observable via
;; Get queries during operation, never via the join return.

(:wat::core::define
  (:trading::cache::Service/run
    (req-rxs :Vec<trading::cache::ReqRx>)
    (d :i64)
    (cap :i64)
    -> :())
  (:wat::core::let*
    (((_cache :wat::holon::HologramLRU)
      (:trading::cache::Service/loop
        req-rxs
        (:wat::holon::HologramLRU/make d cap))))
    ()))

;; ─── Service constructor ───────────────────────────────────────
;;
;; Build N bounded request channels (capacity 1 each — back-pressure
;; under load), pool the senders (HandlePool's orphan detector
;; surfaces over/under-claim at finish), spawn the driver with a
;; fresh HologramLRU. Returns (ReqTxPool, ProgramHandle).
;;
;; Caller pops up to N handles from the pool, finishes the pool,
;; sends Get/Put requests through their handles, exits the inner
;; scope (drops the pool's tail), and joins the driver.

(:wat::core::define
  (:trading::cache::Service
    (count :i64)
    (d :i64)
    (cap :i64)
    -> :trading::cache::Spawn)
  (:wat::core::let*
    (((pairs :Vec<wat::kernel::QueuePair<trading::cache::Request>>)
      (:wat::core::map
        (:wat::core::range 0 count)
        (:wat::core::lambda
          ((_i :i64)
           -> :wat::kernel::QueuePair<trading::cache::Request>)
          (:wat::kernel::make-bounded-queue :trading::cache::Request 1))))
     ((req-txs :Vec<trading::cache::ReqTx>)
      (:wat::core::map pairs
        (:wat::core::lambda
          ((p :wat::kernel::QueuePair<trading::cache::Request>)
           -> :trading::cache::ReqTx)
          (:wat::core::first p))))
     ((req-rxs :Vec<trading::cache::ReqRx>)
      (:wat::core::map pairs
        (:wat::core::lambda
          ((p :wat::kernel::QueuePair<trading::cache::Request>)
           -> :trading::cache::ReqRx)
          (:wat::core::second p))))
     ((pool :trading::cache::ReqTxPool)
      (:wat::kernel::HandlePool::new "trading-cache" req-txs))
     ((driver :wat::kernel::ProgramHandle<()>)
      (:wat::kernel::spawn :trading::cache::Service/run
        req-rxs d cap)))
    (:wat::core::tuple pool driver)))
