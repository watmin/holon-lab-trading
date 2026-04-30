;; 004-step-E-reporter-fires-once.wat — stepping stone toward proof_004.
;;
;; Same shape as step D, but cadence fires on FIRST call. Single Put
;; → cache handles it → tick-window invokes reporter → reporter sends
;; one batch to rundb → rundb dispatches + acks → reporter unblocks
;; → cache loop continues. Then inner exits, cache-req-tx drops,
;; cache loop sees disconnect, ends. _cache-join unblocks. Outer
;; exits, rundb-req-tx drops, _rundb-join unblocks.
;;
;; What it proves: the fire path completes one full cycle without
;; deadlock. If E hangs, the bug is in the synchronous reporter
;; cycle through batch-log; if E passes, the bug is in N>1 cycles
;; or in shutdown after the LAST fire.

(:wat::test::make-deftest :deftest
  ((:wat::load-file! "wat/cache/reporter.wat")
   (:wat::load-file! "wat/telemetry/Sqlite.wat")))

(:deftest :trading::test::proofs::004::step-E-reporter-fires-once
  (:wat::core::let*
    (((now :wat::time::Instant) (:wat::time::now))
     ((epoch-str :wat::core::String)
      (:wat::core::i64::to-string (:wat::time::epoch-seconds now)))
     ((db-path :wat::core::String)
      (:wat::core::string::concat "runs/proof-004-E-" epoch-str ".db"))

     ((rundb-spawn :wat::telemetry::Service::Spawn<wat::telemetry::Event>)
      (:trading::telemetry::Sqlite/spawn db-path 1
        (:wat::telemetry::Service/null-metrics-cadence)))
     ((rundb-pool :wat::telemetry::Service::HandlePool<wat::telemetry::Event>)
      (:wat::core::first rundb-spawn))
     ((rundb-driver :wat::kernel::ProgramHandle<()>)
      (:wat::core::second rundb-spawn))

     ((_inner :())
      (:wat::core::let*
        (((rundb-handle :wat::telemetry::Service::Handle<wat::telemetry::Event>)
          (:wat::kernel::HandlePool::pop rundb-pool))
         ((_finish-rundb :()) (:wat::kernel::HandlePool::finish rundb-pool))
         ((rundb-req-tx :wat::telemetry::Service::ReqTx<wat::telemetry::Event>)
          (:wat::core::first rundb-handle))
         ((ack-rx :wat::telemetry::Service::AckRx)
          (:wat::core::second rundb-handle))

         ((reporter :wat::holon::lru::HologramCacheService::Reporter)
          (:trading::cache::reporter/make
            rundb-req-tx ack-rx :step-E :L2))

         ;; Cadence that fires on EVERY tick (gate=0 → fires + reset).
         ((cadence :wat::holon::lru::HologramCacheService::MetricsCadence<i64>)
          (:wat::holon::lru::HologramCacheService::MetricsCadence/new
            0
            (:wat::core::lambda
              ((_g :wat::core::i64)
               (_s :wat::holon::lru::HologramCacheService::Stats)
               -> :(i64,bool))
              (:wat::core::tuple 0 true))))
         ((cache-spawn :wat::holon::lru::HologramCacheService::Spawn)
          (:wat::holon::lru::HologramCacheService/spawn 1 64 reporter cadence))
         ((cache-pool :wat::holon::lru::HologramCacheService::ReqTxPool)
          (:wat::core::first cache-spawn))
         ((cache-driver :wat::kernel::ProgramHandle<()>)
          (:wat::core::second cache-spawn))

         ((_inner2 :())
          (:wat::core::let*
            (((cache-req-tx :wat::holon::lru::HologramCacheService::ReqTx)
              (:wat::kernel::HandlePool::pop cache-pool))
             ((_finish-cache :()) (:wat::kernel::HandlePool::finish cache-pool))

             ((k :wat::holon::HolonAST) (:wat::holon::leaf "k"))
             ((v :wat::holon::HolonAST) (:wat::holon::leaf "v"))
             ((_p :wat::kernel::Sent)
              (:wat::kernel::send cache-req-tx
                (:wat::holon::lru::HologramCacheService::Request::Put k v))))
            ()))

         ((_cache-join :()) (:wat::kernel::join cache-driver)))
        ()))

     ((_rundb-join :()) (:wat::kernel::join rundb-driver)))
    (:wat::test::assert-eq true true)))
