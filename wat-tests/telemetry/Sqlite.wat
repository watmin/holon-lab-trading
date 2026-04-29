;; wat-tests/telemetry/Sqlite.wat — smoke tests for the lab
;; telemetry::Sqlite wrapper.
;;
;; Slice 6 (arc 091): the wrapper now spawns
;; `Service<:wat::telemetry::Event,_>`. Schema derives from the
;; substrate Event enum (metric + log tables); the lab provides
;; only the pre-install pragma policy. Per-paper resolution data
;; rides on Event::Log via :trading::PaperResolved (Tagged data).
;;
;; Verification beyond "no crash" happens out-of-band via sqlite3
;; CLI on /tmp/telemetry-sqlite-*.db. The deftest passes if
;; (:wat::kernel::join driver) doesn't panic.

(:wat::test::make-deftest :deftest
  ((:wat::load-file! "wat/telemetry/Sqlite.wat")
   (:wat::load-file! "wat/types/paper-resolved.wat")))


;; ─── Test 1: spawn + drop + join (no batches sent) ───────────────

(:deftest :trading::test::io::telemetry::Sqlite::test-lifecycle
  (:wat::core::let*
    (((path :String) "/tmp/telemetry-sqlite-test-001.db")
     ((cadence :wat::telemetry::Service::MetricsCadence<()>)
      (:wat::telemetry::Service/null-metrics-cadence))
     ((spawn :wat::telemetry::Service::Spawn<wat::telemetry::Event>)
      (:trading::telemetry::Sqlite/spawn path 1 cadence))
     ((pool :wat::telemetry::Service::HandlePool<wat::telemetry::Event>)
      (:wat::core::first spawn))
     ((driver :wat::kernel::ProgramHandle<()>) (:wat::core::second spawn))
     ((_inner :())
      (:wat::core::let*
        (((handle :wat::telemetry::Service::Handle<wat::telemetry::Event>)
          (:wat::kernel::HandlePool::pop pool))
         ((_finish :()) (:wat::kernel::HandlePool::finish pool)))
        ()))
     ((_join :()) (:wat::kernel::join driver)))
    (:wat::test::assert-eq true true)))


;; ─── Test 2: one batch round-trip ────────────────────────────────
;;
;; Builds two Event::Log rows directly (no wu) — one with a
;; :trading::PaperResolved payload as Tagged data, one synthetic
;; observation. Ships as one 2-element batch via Service/batch-log.

(:deftest :trading::test::io::telemetry::Sqlite::test-batch-roundtrip
  (:wat::core::let*
    (((path :String) "/tmp/telemetry-sqlite-test-002.db")
     ((cadence :wat::telemetry::Service::MetricsCadence<()>)
      (:wat::telemetry::Service/null-metrics-cadence))
     ((spawn :wat::telemetry::Service::Spawn<wat::telemetry::Event>)
      (:trading::telemetry::Sqlite/spawn path 1 cadence))
     ((pool :wat::telemetry::Service::HandlePool<wat::telemetry::Event>)
      (:wat::core::first spawn))
     ((driver :wat::kernel::ProgramHandle<()>) (:wat::core::second spawn))
     ((_inner :())
      (:wat::core::let*
        (((handle :wat::telemetry::Service::Handle<wat::telemetry::Event>)
          (:wat::kernel::HandlePool::pop pool))
         ((_finish :()) (:wat::kernel::HandlePool::finish pool))
         ((req-tx :wat::telemetry::Service::ReqTx<wat::telemetry::Event>)
          (:wat::core::first handle))
         ((ack-rx :wat::telemetry::Service::AckRx)
          (:wat::core::second handle))
         ((time-ns :i64) 1700000000000000000)
         ((uuid :String) (:wat::telemetry::uuid::v4))
         ((ns-ast    :wat::holon::HolonAST) (:wat::holon::Atom :trading.smoke))
         ((cal-ast   :wat::holon::HolonAST) (:wat::holon::Atom :smoke))
         ((level-ast :wat::holon::HolonAST) (:wat::holon::Atom :info))
         ((tags :wat::telemetry::Tags)
          (:wat::core::HashMap :wat::telemetry::Tag))
         ;; Slice 6: data is a quoted constructor FORM. Atom's
         ;; watast_to_holon arm structurally lowers it to HolonAST
         ;; for the Tagged column.
         ((pr-form :wat::WatAST)
          (:wat::core::quote
            (:trading::PaperResolved/new
              "smoke" "always-up" "cosine"
              1 "Up" 100 388 "Grace" 0.04 0.0)))
         ((event :wat::telemetry::Event)
          (:wat::telemetry::Event::Log
            time-ns
            (:wat::edn::NoTag/new ns-ast)
            (:wat::edn::NoTag/new cal-ast)
            (:wat::edn::NoTag/new level-ast)
            uuid
            tags
            (:wat::edn::Tagged/new (:wat::holon::Atom pr-form))))
         ((entries :Vec<wat::telemetry::Event>)
          (:wat::core::vec :wat::telemetry::Event event)))
        (:wat::telemetry::Service/batch-log req-tx ack-rx entries)))
     ((_join :()) (:wat::kernel::join driver)))
    (:wat::test::assert-eq true true)))
