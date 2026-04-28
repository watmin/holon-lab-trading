;; wat-tests/cache/Service.wat — :trading::cache::Service tests.
;;
;; Building up from SERVICE-PROGRAMS.md's eight-step progression.
;; Each test is a strictly larger version of the prior one.

;; Custom deftest variant — splices step helpers into each test's
;; prelude (deftest sandbox doesn't carry outer-file defines;
;; per arc 075's closure note).
(:wat::test::make-deftest :deftest-hermetic
  ((:wat::load-file! "wat/cache/Service.wat")

   ;; ─── Step 1 helper ──────────────────────────────────────────
   ;; A trivial worker — make a HologramLRU and return it. Verifies
   ;; spawn + join with HologramLRU as the return type, without any
   ;; channel complexity.
   (:wat::core::define
     (:trading::test::cache::Service::trivial-worker
       -> :wat::holon::HologramLRU)
     (:wat::holon::HologramLRU/make 10000 16))

   ;; ─── Step 2 helpers — counted recv loop ─────────────────────
   ;; Worker recv-loops over an i64 channel, counting each Some.
   ;; Returns count when all senders have dropped (channel closed).
   ;; Mirrors SERVICE-PROGRAMS.md step 3 / explore-handles.wat
   ;; count-recv. Establishes the nested-let* shutdown shape we'll
   ;; layer cache state onto in later steps.
   (:wat::core::define
     (:trading::test::cache::Service::count-recv
       (rx :wat::kernel::QueueReceiver<i64>)
       (acc :i64)
       -> :i64)
     (:wat::core::match (:wat::kernel::recv rx) -> :i64
       ((Some _v)
         (:trading::test::cache::Service::count-recv
           rx (:wat::core::i64::+ acc 1)))
       (:None acc)))

   (:wat::core::define
     (:trading::test::cache::Service::run-counter
       (rx :wat::kernel::QueueReceiver<i64>) -> :i64)
     (:trading::test::cache::Service::count-recv rx 0))

   ;; ─── Step 3 helper — drive Service/loop, return final len ──
   ;; HologramLRU is thread-owned (its inner LocalCache lives in a
   ;; ThreadOwnedCell), so we cannot return the cache itself across
   ;; the join boundary. Compute len inside the worker; only the i64
   ;; crosses. The Service constructor wraps Service/loop the same
   ;; way (returning :() instead of cache) for the same reason.
   (:wat::core::define
     (:trading::test::cache::Service::run-loop-then-len
       (req-rxs :Vec<trading::cache::ReqRx>)
       (d :i64)
       (cap :i64)
       -> :i64)
     (:wat::core::let*
       (((cache :wat::holon::HologramLRU)
         (:trading::cache::Service/loop
           req-rxs
           (:wat::holon::HologramLRU/make d cap))))
       (:wat::holon::HologramLRU/len cache)))))

;; ─── Step 1 — spawn + join, no channels ─────────────────────────

(:deftest-hermetic :trading::test::cache::Service::test-step1-spawn-join
  (:wat::core::let*
    (((handle :wat::kernel::ProgramHandle<wat::holon::HologramLRU>)
      (:wat::kernel::spawn
        :trading::test::cache::Service::trivial-worker)))
    (:wat::core::match (:wat::kernel::join-result handle) -> :()
      ((Ok _cache) ())
      ((Err _) (:wat::test::assert-eq "spawn-died" "")))))

;; ─── Step 2 — counted recv via nested let* ──────────────────────
;;
;; Worker recv-loops on an i64 channel; client sends 3 messages from
;; an inner scope; inner returns the ProgramHandle; on inner exit the
;; tx Arc drops, worker's next recv returns :None, returns count=3;
;; outer join-result yields Ok(3).
;;
;; Proves the canonical nested-let* shutdown shape inside our
;; deftest-hermetic harness. Once this passes, the same shape carries
;; richer state (HologramLRU) and richer messages (Request enum).

(:deftest-hermetic :trading::test::cache::Service::test-step2-counted-recv
  (:wat::core::let*
    (((handle :wat::kernel::ProgramHandle<i64>)
      (:wat::core::let*
        (((pair :wat::kernel::QueuePair<i64>)
          (:wat::kernel::make-bounded-queue :i64 1))
         ((tx :wat::kernel::QueueSender<i64>) (:wat::core::first pair))
         ((rx :wat::kernel::QueueReceiver<i64>) (:wat::core::second pair))
         ((h :wat::kernel::ProgramHandle<i64>)
          (:wat::kernel::spawn
            :trading::test::cache::Service::run-counter rx))
         ((_s1 :wat::kernel::Sent) (:wat::kernel::send tx 10))
         ((_s2 :wat::kernel::Sent) (:wat::kernel::send tx 20))
         ((_s3 :wat::kernel::Sent) (:wat::kernel::send tx 30)))
        h)))
    (:wat::core::match (:wat::kernel::join-result handle) -> :()
      ((Ok 3) ())
      ((Ok _) (:wat::test::assert-eq "wrong-count" ""))
      ((Err _) (:wat::test::assert-eq "worker-died" "")))))

;; ─── Step 3 — Service/loop drives the real Request enum (Put only) ──
;;
;; Spawn the actual Service/loop with a single-element Vec<ReqRx>;
;; client sends three Put requests through the matching ReqTx; inner
;; scope exits, rx disconnects, loop's :None arm prunes the only
;; channel, Vec is empty, loop returns the final HologramLRU. Outer
;; join-result yields Ok(cache); test asserts HologramLRU/len == 3.
;;
;; This is the first test that exercises the genuine Service/loop
;; over the real Request enum. Get with embedded reply-tx lands in
;; Step 4; multi-client HandlePool fan-in lands in Step 5.

(:deftest-hermetic :trading::test::cache::Service::test-step3-put-only
  (:wat::core::let*
    (((handle :wat::kernel::ProgramHandle<i64>)
      (:wat::core::let*
        (((pair :wat::kernel::QueuePair<trading::cache::Request>)
          (:wat::kernel::make-bounded-queue :trading::cache::Request 1))
         ((tx :trading::cache::ReqTx) (:wat::core::first pair))
         ((rx :trading::cache::ReqRx) (:wat::core::second pair))
         ((rxs :Vec<trading::cache::ReqRx>)
          (:wat::core::conj
            (:wat::core::vec :trading::cache::ReqRx)
            rx))
         ((h :wat::kernel::ProgramHandle<i64>)
          (:wat::kernel::spawn
            :trading::test::cache::Service::run-loop-then-len rxs 10000 16))
         ((k1 :wat::holon::HolonAST) (:wat::holon::leaf :alpha))
         ((v1 :wat::holon::HolonAST) (:wat::holon::leaf :av))
         ((k2 :wat::holon::HolonAST) (:wat::holon::leaf :beta))
         ((v2 :wat::holon::HolonAST) (:wat::holon::leaf :bv))
         ((k3 :wat::holon::HolonAST) (:wat::holon::leaf :gamma))
         ((v3 :wat::holon::HolonAST) (:wat::holon::leaf :gv))
         ((_p1 :wat::kernel::Sent)
          (:wat::kernel::send tx (:trading::cache::Request::Put 5.0 k1 v1)))
         ((_p2 :wat::kernel::Sent)
          (:wat::kernel::send tx (:trading::cache::Request::Put 5.0 k2 v2)))
         ((_p3 :wat::kernel::Sent)
          (:wat::kernel::send tx (:trading::cache::Request::Put 5.0 k3 v3))))
        h)))
    (:wat::core::match (:wat::kernel::join-result handle) -> :()
      ((Ok 3) ())
      ((Ok _) (:wat::test::assert-eq "wrong-len" ""))
      ((Err _) (:wat::test::assert-eq "service-died" "")))))

;; ─── Step 4 — Put then Get round-trip via reply-tx ──────────────
;;
;; First test that exercises the per-request reply channel pattern.
;; Client owns req-tx + reply-pair (tx and rx both); embeds reply-tx
;; in the Get request; worker dispatches Get → coincident-get →
;; send reply-tx Some(val); client recv's on reply-rx.
;;
;; After the round-trip, inner scope drops req-tx, the worker's only
;; req-rx disconnects, the loop prunes it and exits with :() through
;; Service/run. join-result yields Ok(()).
;;
;; Spawns Service/run (the :() wrapper) instead of run-loop-then-len
;; because we observe state through the Get reply, not via join.

(:deftest-hermetic :trading::test::cache::Service::test-step4-put-get-roundtrip
  (:wat::core::let*
    (((handle :wat::kernel::ProgramHandle<()>)
      (:wat::core::let*
        (((req-pair :wat::kernel::QueuePair<trading::cache::Request>)
          (:wat::kernel::make-bounded-queue :trading::cache::Request 1))
         ((req-tx :trading::cache::ReqTx) (:wat::core::first req-pair))
         ((req-rx :trading::cache::ReqRx) (:wat::core::second req-pair))
         ((rxs :Vec<trading::cache::ReqRx>)
          (:wat::core::conj
            (:wat::core::vec :trading::cache::ReqRx)
            req-rx))
         ((h :wat::kernel::ProgramHandle<()>)
          (:wat::kernel::spawn
            :trading::cache::Service/run rxs 10000 16))

         ((reply-pair :wat::kernel::QueuePair<Option<wat::holon::HolonAST>>)
          (:wat::kernel::make-bounded-queue :Option<wat::holon::HolonAST> 1))
         ((reply-tx :trading::cache::GetReplyTx)
          (:wat::core::first reply-pair))
         ((reply-rx :trading::cache::GetReplyRx)
          (:wat::core::second reply-pair))

         ((k :wat::holon::HolonAST) (:wat::holon::leaf :alpha))
         ((v :wat::holon::HolonAST) (:wat::holon::leaf :av))

         ((_p :wat::kernel::Sent)
          (:wat::kernel::send req-tx
            (:trading::cache::Request::Put 5.0 k v)))
         ((_g :wat::kernel::Sent)
          (:wat::kernel::send req-tx
            (:trading::cache::Request::Get 5.0 k reply-tx)))
         ((maybe-reply :Option<Option<wat::holon::HolonAST>>)
          (:wat::kernel::recv reply-rx))
         ((_check :())
          (:wat::core::match maybe-reply -> :()
            ((Some inner)
              (:wat::core::match inner -> :()
                ((Some _val) ())
                (:None (:wat::test::assert-eq "cache-miss" ""))))
            (:None (:wat::test::assert-eq "no-reply" "")))))
        h)))
    (:wat::core::match (:wat::kernel::join-result handle) -> :()
      ((Ok _) ())
      ((Err _) (:wat::test::assert-eq "service-died" "")))))

;; ─── Step 5 — full Service constructor + HandlePool fan-in ──────
;;
;; Test the real `:trading::cache::Service` factory: it builds the
;; bounded request pairs, pools the senders, spawns the driver. The
;; client pops 2 handles, finish()es the pool (orphan check), runs a
;; Put + Get round-trip on each handle, exits inner scope.
;;
;; Inner exit drops both popped req-txs AND the pool's tail (none —
;; we popped all 2 and finished). Both worker rxs disconnect; loop
;; prunes both; Service/run wrapper returns :(); join-result yields
;; Ok(()).

(:deftest-hermetic :trading::test::cache::Service::test-step5-multi-client-via-constructor
  (:wat::core::let*
    (((handle :wat::kernel::ProgramHandle<()>)
      (:wat::core::let*
        (((spawn :trading::cache::Spawn)
          (:trading::cache::Service 2 10000 16))
         ((pool :trading::cache::ReqTxPool) (:wat::core::first spawn))
         ((driver :wat::kernel::ProgramHandle<()>) (:wat::core::second spawn))

         ((tx-a :trading::cache::ReqTx) (:wat::kernel::HandlePool::pop pool))
         ((tx-b :trading::cache::ReqTx) (:wat::kernel::HandlePool::pop pool))
         ((_finish :()) (:wat::kernel::HandlePool::finish pool))

         ((reply-pair-a :wat::kernel::QueuePair<Option<wat::holon::HolonAST>>)
          (:wat::kernel::make-bounded-queue :Option<wat::holon::HolonAST> 1))
         ((reply-tx-a :trading::cache::GetReplyTx)
          (:wat::core::first reply-pair-a))
         ((reply-rx-a :trading::cache::GetReplyRx)
          (:wat::core::second reply-pair-a))

         ((reply-pair-b :wat::kernel::QueuePair<Option<wat::holon::HolonAST>>)
          (:wat::kernel::make-bounded-queue :Option<wat::holon::HolonAST> 1))
         ((reply-tx-b :trading::cache::GetReplyTx)
          (:wat::core::first reply-pair-b))
         ((reply-rx-b :trading::cache::GetReplyRx)
          (:wat::core::second reply-pair-b))

         ((k-a :wat::holon::HolonAST) (:wat::holon::leaf :alpha))
         ((v-a :wat::holon::HolonAST) (:wat::holon::leaf :av))
         ((k-b :wat::holon::HolonAST) (:wat::holon::leaf :beta))
         ((v-b :wat::holon::HolonAST) (:wat::holon::leaf :bv))

         ;; Client A: Put + Get on alpha
         ((_pa :wat::kernel::Sent)
          (:wat::kernel::send tx-a
            (:trading::cache::Request::Put 5.0 k-a v-a)))
         ((_ga :wat::kernel::Sent)
          (:wat::kernel::send tx-a
            (:trading::cache::Request::Get 5.0 k-a reply-tx-a)))
         ((reply-a :Option<Option<wat::holon::HolonAST>>)
          (:wat::kernel::recv reply-rx-a))
         ((_check-a :())
          (:wat::core::match reply-a -> :()
            ((Some inner)
              (:wat::core::match inner -> :()
                ((Some _val) ())
                (:None (:wat::test::assert-eq "client-a-miss" ""))))
            (:None (:wat::test::assert-eq "client-a-no-reply" ""))))

         ;; Client B: Put + Get on beta
         ((_pb :wat::kernel::Sent)
          (:wat::kernel::send tx-b
            (:trading::cache::Request::Put 5.0 k-b v-b)))
         ((_gb :wat::kernel::Sent)
          (:wat::kernel::send tx-b
            (:trading::cache::Request::Get 5.0 k-b reply-tx-b)))
         ((reply-b :Option<Option<wat::holon::HolonAST>>)
          (:wat::kernel::recv reply-rx-b))
         ((_check-b :())
          (:wat::core::match reply-b -> :()
            ((Some inner)
              (:wat::core::match inner -> :()
                ((Some _val) ())
                (:None (:wat::test::assert-eq "client-b-miss" ""))))
            (:None (:wat::test::assert-eq "client-b-no-reply" "")))))
        driver)))
    (:wat::core::match (:wat::kernel::join-result handle) -> :()
      ((Ok _) ())
      ((Err _) (:wat::test::assert-eq "service-died" "")))))
