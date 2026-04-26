;; wat-tests-integ/experiment/008-treasury-program/explore-treasury.wat
;;
;; Treasury skeleton, built up from the smallest pieces. explore-handles.wat
;; proved the substrate (spawn/join, channels, scope-based close, select,
;; HandlePool, struct accumulator). This file builds the Treasury domain
;; on top of that proven foundation, one step at a time.
;;
;; Namespace: `:exp::*`. Experiments are a reference for future code, not
;; a production registration — keep names short so future readers grok
;; the SHAPE without being buried in the path.
;;
;; T1 — empty Service shell with single-variant Request enum (Ping)
;;      and ack-only handler. Proves: Service constructor returns
;;      (pool, driver); driver routes by variant; per-request reply-tx
;;      idiom round-trips ack; nested-scope shutdown still works.
;; T2 — add a second variant (Tick — fire-and-forget; no reply).
;; T3 — add the State struct accumulator.
;; T4+ — replace Ping/Tick with real Treasury verbs (SubmitPaper,
;;       SubmitExit, Tick-with-state-mutation), filling in bodies
;;       one at a time.

(:wat::test::make-deftest :deftest
  (;; Reply channel — for T1 the worker only needs to ack receipt.
   ;; T3+ will swap () for real Verdict / PositionReceipt types.
   (:wat::core::typealias :exp::ReplyTx :wat::kernel::QueueSender<()>)
   (:wat::core::typealias :exp::ReplyRx :wat::kernel::QueueReceiver<()>)

   ;; Request — enum variants embed their own reply-tx so the driver
   ;; can route responses without a sender-index map. CacheService
   ;; uses this exact shape in wat-rs/crates/wat-lru/wat/lru/CacheService.wat.
   ;;
   ;; Mixed reply shapes:
   ;;   Ping(reply-tx)  — request/response; caller blocks on its reply-rx
   ;;   Tick(price)     — fire-and-forget; no reply, no embedded tx
   ;;
   ;; Treasury's real verbs will follow the same split: SubmitPaper /
   ;; SubmitExit carry reply-tx for receipts; Tick is the silent clock
   ;; that integrates state without acknowledging.
   (:wat::core::enum :exp::Request
     (Ping (reply-tx :exp::ReplyTx))
     (Tick (price :f64)))

   ;; Per-broker request channel typealiases.
   (:wat::core::typealias :exp::ReqTx :wat::kernel::QueueSender<exp::Request>)
   (:wat::core::typealias :exp::ReqRx :wat::kernel::QueueReceiver<exp::Request>)
   (:wat::core::typealias :exp::ReqTxPool :wat::kernel::HandlePool<exp::ReqTx>)
   (:wat::core::typealias :exp::Spawn
     :(exp::ReqTxPool,wat::kernel::ProgramHandle<()>))


   ;; ─── Service driver loop ─────────────────────────────────────
   ;;
   ;; select over Vec<ReqRx>; on Some(req) match the Request variant
   ;; and dispatch (T1: Ping ⇒ send () on reply-tx, then recurse on
   ;; same Vec); on :None for any rx, prune that channel and recurse;
   ;; exit when the Vec is empty (all callers' scopes have exited).
   ;;
   ;; The driver IS stateless in T1 — no accumulator parameter. T3
   ;; lifts this into a struct-carrying loop (the explore-handles
   ;; step 8 shape). For now the pattern is pure substrate-step-5+7.
   (:wat::core::define
     (:exp::Service/loop (req-rxs :Vec<exp::ReqRx>) -> :())
     (:wat::core::if (:wat::core::empty? req-rxs) -> :()
       ()
       (:wat::core::let*
         (((chosen :wat::kernel::Chosen<exp::Request>) (:wat::kernel::select req-rxs))
          ((idx :i64) (:wat::core::first chosen))
          ((maybe :Option<exp::Request>) (:wat::core::second chosen)))
         (:wat::core::match maybe -> :()
           ((Some req)
             (:wat::core::let*
               (((_handled :()) (:exp::Service/handle req)))
               (:exp::Service/loop req-rxs)))
           (:None
             (:exp::Service/loop (:wat::std::list::remove-at req-rxs idx)))))))

   ;; Per-request dispatch — match the Request variant and execute its
   ;; placeholder body. Lives as a separate define so each variant's
   ;; body grows independently as we fill them in.
   ;;
   ;; T1 added Ping → ack on embedded reply-tx.
   ;; T2 adds Tick → no-op (silent integration; placeholder for the
   ;; real per-Tick state update that lands at T3+).
   (:wat::core::define
     (:exp::Service/handle (req :exp::Request) -> :())
     (:wat::core::match req -> :()
       ((:exp::Request::Ping reply-tx)
         (:wat::core::let*
           (((_ack :Option<()>) (:wat::kernel::send reply-tx ())))
           ()))
       ((:exp::Request::Tick _price)
         ())))

   ;; ─── Service constructor ─────────────────────────────────────
   ;;
   ;; Build N request channels, pool the senders (orphan detector at
   ;; construction), spawn the driver with the receivers Vec, return
   ;; (pool, driver). This is the canonical service-program shape per
   ;; SERVICE-PROGRAMS.md "the full service template".
   (:wat::core::define
     (:exp::Service (count :i64) -> :exp::Spawn)
     (:wat::core::let*
       (((pairs :Vec<wat::kernel::QueuePair<exp::Request>>)
         (:wat::core::map
           (:wat::core::range 0 count)
           (:wat::core::lambda ((_i :i64) -> :wat::kernel::QueuePair<exp::Request>)
             (:wat::kernel::make-bounded-queue :exp::Request 1))))

        ((req-txs :Vec<exp::ReqTx>)
         (:wat::core::map pairs
           (:wat::core::lambda ((p :wat::kernel::QueuePair<exp::Request>) -> :exp::ReqTx)
             (:wat::core::first p))))

        ((req-rxs :Vec<exp::ReqRx>)
         (:wat::core::map pairs
           (:wat::core::lambda ((p :wat::kernel::QueuePair<exp::Request>) -> :exp::ReqRx)
             (:wat::core::second p))))

        ((pool :exp::ReqTxPool)
         (:wat::kernel::HandlePool::new "treasury" req-txs))

        ((driver :wat::kernel::ProgramHandle<()>)
         (:wat::kernel::spawn :exp::Service/loop req-rxs)))
       (:wat::core::tuple pool driver)))))


;; ─── T1 — single Ping round-trip through the Service ──────────
;;
;; Smallest end-to-end Treasury proof: spawn the Service with one
;; broker handle, pop it, send a Ping (carrying our own reply-rx side),
;; recv the ack, exit. Outer scope holds the driver handle; inner scope
;; owns the popped req-tx + the reply-pair. When inner exits, every
;; client-side Sender drops; the driver's last rx disconnects; the
;; loop exits; the outer join unblocks.

(:deftest :exp::t1-ping-roundtrip
  (:wat::core::let*
    (((spawn :exp::Spawn) (:exp::Service 1))
     ((pool :exp::ReqTxPool) (:wat::core::first spawn))
     ((driver :wat::kernel::ProgramHandle<()>) (:wat::core::second spawn))

     ;; Inner scope owns the popped handle and the reply channel.
     ;; All client-side Senders die when this scope exits.
     ((_inner :())
      (:wat::core::let*
        (((req-tx :exp::ReqTx) (:wat::kernel::HandlePool::pop pool))
         ((_finish :()) (:wat::kernel::HandlePool::finish pool))

         ((reply-pair :wat::kernel::QueuePair<()>)
          (:wat::kernel::make-bounded-queue :() 1))
         ((reply-tx :exp::ReplyTx) (:wat::core::first reply-pair))
         ((reply-rx :exp::ReplyRx) (:wat::core::second reply-pair))

         ;; Send Ping carrying our reply-tx; driver acks; we recv.
         ((_send :Option<()>)
          (:wat::kernel::send req-tx (:exp::Request::Ping reply-tx)))
         ((got :Option<()>) (:wat::kernel::recv reply-rx))
         ((_check :())
          (:wat::core::match got -> :()
            ((Some _) ())
            (:None (:wat::test::assert-eq "no-ack" "")))))
        ()))

     ;; Inner scope exited → req-tx + reply-tx dropped → driver's only
     ;; ReqRx disconnected → Service/loop pruned the rx, Vec empty,
     ;; loop exited. join is the bookend.
     ((_join :()) (:wat::kernel::join driver)))
    (:wat::test::assert-eq true true)))


;; ─── T2 — Tick interleaved with Ping (mixed-shape variants) ───
;;
;; Send Tick (no reply expected), then Ping (recv ack), then Tick
;; again. Proves the dispatch table holds variants of different reply
;; shapes — fire-and-forget interleaved with request/response — and
;; that the Tick arm doesn't accidentally try to use a reply channel
;; that isn't there. Same shutdown story as T1.

(:deftest :exp::t2-tick-interleaved
  (:wat::core::let*
    (((spawn :exp::Spawn) (:exp::Service 1))
     ((pool :exp::ReqTxPool) (:wat::core::first spawn))
     ((driver :wat::kernel::ProgramHandle<()>) (:wat::core::second spawn))

     ((_inner :())
      (:wat::core::let*
        (((req-tx :exp::ReqTx) (:wat::kernel::HandlePool::pop pool))
         ((_finish :()) (:wat::kernel::HandlePool::finish pool))

         ((reply-pair :wat::kernel::QueuePair<()>)
          (:wat::kernel::make-bounded-queue :() 1))
         ((reply-tx :exp::ReplyTx) (:wat::core::first reply-pair))
         ((reply-rx :exp::ReplyRx) (:wat::core::second reply-pair))

         ;; Tick first — no reply channel, no recv. Worker silently
         ;; consumes. bounded(1) means this send returns once the
         ;; worker has dequeued.
         ((_t1 :Option<()>)
          (:wat::kernel::send req-tx (:exp::Request::Tick 100.0)))

         ;; Ping — reply round-trip.
         ((_p :Option<()>)
          (:wat::kernel::send req-tx (:exp::Request::Ping reply-tx)))
         ((got :Option<()>) (:wat::kernel::recv reply-rx))
         ((_check :())
          (:wat::core::match got -> :()
            ((Some _) ())
            (:None (:wat::test::assert-eq "no-ack" ""))))

         ;; Tick again — proves the dispatch returns to a clean state
         ;; after a reply-bearing variant.
         ((_t2 :Option<()>)
          (:wat::kernel::send req-tx (:exp::Request::Tick 101.0))))
        ()))

     ((_join :()) (:wat::kernel::join driver)))
    (:wat::test::assert-eq true true)))
