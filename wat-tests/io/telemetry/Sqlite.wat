;; wat-tests/io/telemetry/Sqlite.wat — smoke tests for the lab
;; telemetry::Sqlite wrapper. Post arc 085: the wrapper delegates
;; to the substrate's `:wat::std::telemetry::Sqlite/auto-spawn`
;; which derives schemas + INSERTs + per-entry binders from the
;; `:trading::log::LogEntry` enum decl. Test pattern unchanged from
;; the pre-085 wrapper: spawn → pop handle → batch-log → drop → join.
;;
;; Verification beyond "no crash" happens out-of-band via sqlite3
;; CLI on /tmp/telemetry-sqlite-*.db (per arc 027/029 no-read-API
;; scope). The deftest passes if (:wat::kernel::join driver) doesn't
;; panic.
;;
;; Lifetime discipline: outer let* holds driver; inner let* owns
;; the popped req-tx + ack pair. Per CIRCUIT.md.

(:wat::test::make-deftest :deftest
  ((:wat::load-file! "wat/io/telemetry/Sqlite.wat")))


;; ─── Test 1: spawn + drop + join (no batches sent) ───────────────

(:deftest :trading::test::io::telemetry::Sqlite::test-lifecycle
  (:wat::core::let*
    (((path :String) "/tmp/telemetry-sqlite-test-001.db")
     ((cadence :wat::std::telemetry::Service::MetricsCadence<()>)
      (:wat::std::telemetry::Service/null-metrics-cadence))
     ((spawn :wat::std::telemetry::Service::Spawn<trading::log::LogEntry>)
      (:trading::telemetry::Sqlite/spawn path 1 cadence))
     ((pool :wat::std::telemetry::Service::ReqTxPool<trading::log::LogEntry>)
      (:wat::core::first spawn))
     ((driver :wat::kernel::ProgramHandle<()>) (:wat::core::second spawn))
     ((_inner :())
      (:wat::core::let*
        (((req-tx :wat::std::telemetry::Service::ReqTx<trading::log::LogEntry>)
          (:wat::kernel::HandlePool::pop pool))
         ((_finish :()) (:wat::kernel::HandlePool::finish pool)))
        ()))
     ((_join :()) (:wat::kernel::join driver)))
    (:wat::test::assert-eq true true)))


;; ─── Test 2: one batch round-trip ────────────────────────────────

(:deftest :trading::test::io::telemetry::Sqlite::test-batch-roundtrip
  (:wat::core::let*
    (((path :String) "/tmp/telemetry-sqlite-test-002.db")
     ((cadence :wat::std::telemetry::Service::MetricsCadence<()>)
      (:wat::std::telemetry::Service/null-metrics-cadence))
     ((spawn :wat::std::telemetry::Service::Spawn<trading::log::LogEntry>)
      (:trading::telemetry::Sqlite/spawn path 1 cadence))
     ((pool :wat::std::telemetry::Service::ReqTxPool<trading::log::LogEntry>)
      (:wat::core::first spawn))
     ((driver :wat::kernel::ProgramHandle<()>) (:wat::core::second spawn))
     ((_inner :())
      (:wat::core::let*
        (((req-tx :wat::std::telemetry::Service::ReqTx<trading::log::LogEntry>)
          (:wat::kernel::HandlePool::pop pool))
         ((_finish :()) (:wat::kernel::HandlePool::finish pool))
         ((ack-channel :wat::std::telemetry::Service::AckChannel)
          (:wat::kernel::make-bounded-queue :() 1))
         ((ack-tx :wat::std::telemetry::Service::AckTx)
          (:wat::core::first ack-channel))
         ((ack-rx :wat::std::telemetry::Service::AckRx)
          (:wat::core::second ack-channel))
         ((entries :Vec<trading::log::LogEntry>)
          (:wat::core::vec :trading::log::LogEntry
            (:trading::log::LogEntry::PaperResolved
              "smoke" "always-up" "cosine"
              1 "Up" 100 388 "Grace" 0.04 0.0)
            (:trading::log::LogEntry::Telemetry
              "treasury" "tick" "{\"window\":\"smoke\"}"
              1700000000000
              "deposits" 10000.0 "Count"))))
        (:wat::std::telemetry::Service/batch-log
          req-tx ack-tx ack-rx entries)))
     ((_join :()) (:wat::kernel::join driver)))
    (:wat::test::assert-eq true true)))
