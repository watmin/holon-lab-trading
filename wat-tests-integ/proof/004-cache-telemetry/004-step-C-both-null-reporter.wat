;; 004-step-C-both-null-reporter.wat — stepping stone toward proof_004.
;;
;; BOTH services running concurrently — but no cross-talk. Cache uses
;; the substrate's null-reporter (top-level fn, NO closure capture).
;; Rundb is spawned and joined separately.
;;
;; What it proves: two services can shut down cleanly when run side
;; by side WITHOUT either holding a sender to the other. If C passes
;; and D fails, the closure-capture is what breaks shutdown.

(:wat::test::make-deftest :deftest
  ((:wat::load-file! "wat/telemetry/Sqlite.wat")))

(:deftest :trading::test::proofs::004::step-C-both-null-reporter
  (:wat::core::let*
    (((now :wat::time::Instant) (:wat::time::now))
     ((epoch-str :wat::core::String)
      (:wat::core::i64::to-string (:wat::time::epoch-seconds now)))
     ((db-path :wat::core::String)
      (:wat::core::string::concat "runs/proof-004-C-" epoch-str ".db"))

     ;; Spawn rundb (count=1).
     ((rundb-spawn :wat::telemetry::Service::Spawn<wat::telemetry::Event>)
      (:trading::telemetry::Sqlite/spawn db-path 1
        (:wat::telemetry::Service/null-metrics-cadence)))
     ((rundb-pool :wat::telemetry::Service::HandlePool<wat::telemetry::Event>)
      (:wat::core::first rundb-spawn))
     ((rundb-driver :wat::kernel::ProgramHandle<()>)
      (:wat::core::second rundb-spawn))

     ;; Spawn cache (count=1, cap=64) with NULL reporter — no closure.
     ((cache-spawn :wat::holon::lru::HologramCacheService::Spawn)
      (:wat::holon::lru::HologramCacheService/spawn 1 64
        :wat::holon::lru::HologramCacheService/null-reporter
        (:wat::holon::lru::HologramCacheService/null-metrics-cadence)))
     ((cache-pool :wat::holon::lru::HologramCacheService::ReqTxPool)
      (:wat::core::first cache-spawn))
     ((cache-driver :wat::kernel::ProgramHandle<()>)
      (:wat::core::second cache-spawn))

     ;; Inner — pop both, drive a tiny workload, drop everything.
     ((_inner :())
      (:wat::core::let*
        (((rundb-handle :wat::telemetry::Service::Handle<wat::telemetry::Event>)
          (:wat::kernel::HandlePool::pop rundb-pool))
         ((_finish-rundb :()) (:wat::kernel::HandlePool::finish rundb-pool))
         ((rundb-req-tx :wat::telemetry::Service::ReqTx<wat::telemetry::Event>)
          (:wat::core::first rundb-handle))
         ((ack-rx :wat::telemetry::Service::AckRx)
          (:wat::core::second rundb-handle))

         ((cache-req-tx :wat::holon::lru::HologramCacheService::ReqTx)
          (:wat::kernel::HandlePool::pop cache-pool))
         ((_finish-cache :()) (:wat::kernel::HandlePool::finish cache-pool))

         ;; Send one Put to cache.
         ((k :wat::holon::HolonAST) (:wat::holon::leaf "k"))
         ((v :wat::holon::HolonAST) (:wat::holon::leaf "v"))
         ((_p :())
          (:wat::core::result::expect -> :()
            (:wat::kernel::send cache-req-tx
              (:wat::holon::lru::HologramCacheService::Request::Put k v))
            "step-C: send Put: driver died?"))

         ;; Send one batch to rundb (independent — not from a closure).
         ((time-ns :wat::core::i64) (:wat::time::epoch-nanos (:wat::time::now)))
         ((uuid :wat::core::String) (:wat::telemetry::uuid::v4))
         ((tags :wat::telemetry::Tags)
          (:wat::core::HashMap :wat::telemetry::Tag))
         ((event :wat::telemetry::Event)
          (:wat::telemetry::Event::Log
            time-ns
            (:wat::edn::NoTag/new (:wat::holon::Atom :step-C))
            (:wat::edn::NoTag/new (:wat::holon::Atom :step-C.caller))
            (:wat::edn::NoTag/new (:wat::holon::Atom :info))
            uuid
            tags
            (:wat::edn::Tagged/new (:wat::holon::Atom :hello))))
         ((entries :Vec<wat::telemetry::Event>)
          (:wat::core::vec :wat::telemetry::Event event))
         ((_send-recv :())
          (:wat::telemetry::Service/batch-log rundb-req-tx ack-rx entries)))
        ()))

     ;; Inner exited — both services see disconnect.
     ((_cache-join :()) (:wat::kernel::join cache-driver))
     ((_rundb-join :()) (:wat::kernel::join rundb-driver)))
    (:wat::test::assert-eq true true)))
