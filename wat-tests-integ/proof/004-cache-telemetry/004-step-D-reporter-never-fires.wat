;; 004-step-D-reporter-never-fires.wat — stepping stone toward proof_004.
;;
;; Reporter closes over rundb's req-tx + ack-rx (clones held in the
;; cache thread's environment). But cadence is the substrate's
;; null-metrics-cadence — the reporter is NEVER invoked.
;;
;; What it proves: closure capture alone (without firing) doesn't
;; prevent shutdown. The cache thread holds the Arc<Sender> for the
;; whole run; when the cache thread ends, the closure drops, the
;; Sender clone drops, and rundb sees disconnect.
;;
;; If D passes: closure capture is fine; the bug is in the FIRE path.
;; If D hangs: closure capture itself prevents shutdown.

(:wat::test::make-deftest :deftest
  ((:wat::load-file! "wat/cache/reporter.wat")
   (:wat::load-file! "wat/telemetry/Sqlite.wat")))

(:deftest :trading::test::proofs::004::step-D-reporter-never-fires
  (:wat::core::let*
    (((now :wat::time::Instant) (:wat::time::now))
     ((epoch-str :wat::core::String)
      (:wat::core::i64::to-string (:wat::time::epoch-seconds now)))
     ((db-path :wat::core::String)
      (:wat::core::string::concat "runs/proof-004-D-" epoch-str ".db"))

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

         ;; Build the reporter (closure captures rundb-req-tx + ack-rx).
         ((reporter :wat::holon::lru::HologramCacheService::Reporter)
          (:trading::cache::reporter/make
            rundb-req-tx ack-rx :step-D :L2))

         ;; Spawn cache with the closure-capturing reporter, but
         ;; null-cadence so the reporter is NEVER invoked.
         ((cache-spawn :wat::holon::lru::HologramCacheService::Spawn)
          (:wat::holon::lru::HologramCacheService/spawn 1 64
            reporter
            (:wat::holon::lru::HologramCacheService::MetricsCadence/new
              ()
              (:wat::core::lambda
                ((g :())
                 (_s :wat::holon::lru::HologramCacheService::Stats)
                 -> :((),bool))
                (:wat::core::tuple g false)))))
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
