;; wat-tests/cache/Service.wat — :trading::cache::Service tests.
;;
;; Building up from SERVICE-PROGRAMS.md's eight-step progression.
;; Each test is a strictly larger version of the prior one.
;;
;; Arc 076 + 077: HologramCache/make takes (filter, cap); Request enum
;; carries no pos field; substrate routes by form structure.

;; Custom deftest variant — splices step helpers into each test's
;; prelude (deftest sandbox doesn't carry outer-file defines;
;; per arc 075's closure note).
(:wat::test::make-deftest :deftest-hermetic
  ((:wat::load-file! "wat/cache/Service.wat")

   ;; ─── Step 1 helper ──────────────────────────────────────────
   ;; A trivial worker — make a HologramCache and return it. Verifies
   ;; spawn + join with HologramCache as the return type, without any
   ;; channel complexity.
   (:wat::core::define
     (:trading::test::cache::Service::trivial-worker
       -> :wat::holon::lru::HologramCache)
     (:wat::holon::lru::HologramCache/make
       (:wat::holon::filter-coincident)
       16))

   ;; ─── Step 2 helpers — counted recv loop ─────────────────────
   ;; Worker recv-loops over an i64 channel, counting each Some.
   ;; Returns count when all senders have dropped (channel closed).
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
   ;; HologramCache is thread-owned; we cannot return the cache itself
   ;; across the join boundary. Compute len inside the worker; only
   ;; the i64 crosses. Pass null-metrics-cadence + null-reporter — these
   ;; tests don't care about reporting.
   (:wat::core::define
     (:trading::test::cache::Service::run-loop-then-len
       (req-rxs :Vec<trading::cache::ReqRx>)
       (cap :i64)
       -> :i64)
     (:wat::core::let*
       (((cache :wat::holon::lru::HologramCache)
         (:wat::holon::lru::HologramCache/make
           (:wat::holon::filter-coincident)
           cap))
        ((initial :trading::cache::State)
         (:trading::cache::State/new cache (:trading::cache::Stats/zero)))
        ((final :trading::cache::State)
         (:trading::cache::Service/loop
           req-rxs initial
           :trading::cache::null-reporter
           (:trading::cache::null-metrics-cadence))))
       (:wat::holon::lru::HologramCache/len
         (:trading::cache::State/cache final))))))

;; ─── Step 1 — spawn + join, no channels ─────────────────────────

(:deftest-hermetic :trading::test::cache::Service::test-step1-spawn-join
  (:wat::core::let*
    (((handle :wat::kernel::ProgramHandle<wat::holon::lru::HologramCache>)
      (:wat::kernel::spawn
        :trading::test::cache::Service::trivial-worker)))
    (:wat::core::match (:wat::kernel::join-result handle) -> :()
      ((Ok _cache) ())
      ((Err _) (:wat::test::assert-eq "spawn-died" "")))))

;; ─── Step 2 — counted recv via nested let* ──────────────────────

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
            :trading::test::cache::Service::run-loop-then-len rxs 16))
         ((k1 :wat::holon::HolonAST) (:wat::holon::leaf :alpha))
         ((v1 :wat::holon::HolonAST) (:wat::holon::leaf :av))
         ((k2 :wat::holon::HolonAST) (:wat::holon::leaf :beta))
         ((v2 :wat::holon::HolonAST) (:wat::holon::leaf :bv))
         ((k3 :wat::holon::HolonAST) (:wat::holon::leaf :gamma))
         ((v3 :wat::holon::HolonAST) (:wat::holon::leaf :gv))
         ((_p1 :wat::kernel::Sent)
          (:wat::kernel::send tx (:trading::cache::Request::Put k1 v1)))
         ((_p2 :wat::kernel::Sent)
          (:wat::kernel::send tx (:trading::cache::Request::Put k2 v2)))
         ((_p3 :wat::kernel::Sent)
          (:wat::kernel::send tx (:trading::cache::Request::Put k3 v3))))
        h)))
    (:wat::core::match (:wat::kernel::join-result handle) -> :()
      ((Ok 3) ())
      ((Ok _) (:wat::test::assert-eq "wrong-len" ""))
      ((Err _) (:wat::test::assert-eq "service-died" "")))))

;; ─── Step 4 — Put then Get round-trip via reply-tx ──────────────

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
            :trading::cache::Service/run rxs 16 :trading::cache::null-reporter (:trading::cache::null-metrics-cadence)))

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
            (:trading::cache::Request::Put k v)))
         ((_g :wat::kernel::Sent)
          (:wat::kernel::send req-tx
            (:trading::cache::Request::Get k reply-tx)))
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

(:deftest-hermetic :trading::test::cache::Service::test-step5-multi-client-via-constructor
  (:wat::core::let*
    (((handle :wat::kernel::ProgramHandle<()>)
      (:wat::core::let*
        (((spawn :trading::cache::Spawn)
          (:trading::cache::Service/spawn 2 16 :trading::cache::null-reporter (:trading::cache::null-metrics-cadence)))
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
            (:trading::cache::Request::Put k-a v-a)))
         ((_ga :wat::kernel::Sent)
          (:wat::kernel::send tx-a
            (:trading::cache::Request::Get k-a reply-tx-a)))
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
            (:trading::cache::Request::Put k-b v-b)))
         ((_gb :wat::kernel::Sent)
          (:wat::kernel::send tx-b
            (:trading::cache::Request::Get k-b reply-tx-b)))
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

;; ─── T6: LRU eviction visible through Service Get/Put round-trips ──
;;
;; Probe T6 from DESIGN.md, lab-side. cap=2 cache; Put k1, Put k2,
;; Put k3 — k1 should be evicted. Subsequent Get(k1) returns None;
;; Get(k2) returns Some. This proves the queue-addressed wrapper
;; preserves the HologramCache eviction semantics — eviction visible
;; from the client's view, not just at the substrate.

(:deftest-hermetic :trading::test::cache::Service::test-step6-lru-eviction-via-service
  (:wat::core::let*
    (((handle :wat::kernel::ProgramHandle<()>)
      (:wat::core::let*
        (((spawn :trading::cache::Spawn)
          (:trading::cache::Service/spawn 1 2 :trading::cache::null-reporter (:trading::cache::null-metrics-cadence)))
         ((pool :trading::cache::ReqTxPool) (:wat::core::first spawn))
         ((driver :wat::kernel::ProgramHandle<()>) (:wat::core::second spawn))
         ((tx :trading::cache::ReqTx) (:wat::kernel::HandlePool::pop pool))
         ((_finish :()) (:wat::kernel::HandlePool::finish pool))

         ((reply-pair :wat::kernel::QueuePair<Option<wat::holon::HolonAST>>)
          (:wat::kernel::make-bounded-queue :Option<wat::holon::HolonAST> 1))
         ((reply-tx :trading::cache::GetReplyTx)
          (:wat::core::first reply-pair))
         ((reply-rx :trading::cache::GetReplyRx)
          (:wat::core::second reply-pair))

         ((k1 :wat::holon::HolonAST) (:wat::holon::leaf :first))
         ((k2 :wat::holon::HolonAST) (:wat::holon::leaf :second))
         ((k3 :wat::holon::HolonAST) (:wat::holon::leaf :third))
         ((v :wat::holon::HolonAST) (:wat::holon::leaf :payload))

         ;; Three puts at cap=2; k1 gets evicted by k3.
         ((_p1 :wat::kernel::Sent)
          (:wat::kernel::send tx (:trading::cache::Request::Put k1 v)))
         ((_p2 :wat::kernel::Sent)
          (:wat::kernel::send tx (:trading::cache::Request::Put k2 v)))
         ((_p3 :wat::kernel::Sent)
          (:wat::kernel::send tx (:trading::cache::Request::Put k3 v)))

         ;; Get k1 — evicted, expect None.
         ((_g1 :wat::kernel::Sent)
          (:wat::kernel::send tx
            (:trading::cache::Request::Get k1 reply-tx)))
         ((reply-1 :Option<Option<wat::holon::HolonAST>>)
          (:wat::kernel::recv reply-rx))
         ((_check-1 :())
          (:wat::core::match reply-1 -> :()
            ((Some inner)
              (:wat::core::match inner -> :()
                ((Some _) (:wat::test::assert-eq "k1-not-evicted" ""))
                (:None ())))
            (:None (:wat::test::assert-eq "no-reply-1" ""))))

         ;; Get k2 — survived, expect Some.
         ((_g2 :wat::kernel::Sent)
          (:wat::kernel::send tx
            (:trading::cache::Request::Get k2 reply-tx)))
         ((reply-2 :Option<Option<wat::holon::HolonAST>>)
          (:wat::kernel::recv reply-rx))
         ((_check-2 :())
          (:wat::core::match reply-2 -> :()
            ((Some inner)
              (:wat::core::match inner -> :()
                ((Some _) ())
                (:None (:wat::test::assert-eq "k2-evicted" ""))))
            (:None (:wat::test::assert-eq "no-reply-2" "")))))
        driver)))
    (:wat::core::match (:wat::kernel::join-result handle) -> :()
      ((Ok _) ())
      ((Err _) (:wat::test::assert-eq "service-died" "")))))
