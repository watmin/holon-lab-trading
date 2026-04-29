;; wat-tests/io/log/telemetry.wat — smoke tests for the lab telemetry
;; surface post arcs 083/084/085.
;;
;; Two deftests:
;;   1. Variant + dispatch round-trip — build a
;;      LogEntry::Telemetry, batch-log via the substrate-derived
;;      sink to a temp DB, no crash. Out-of-band verification via
;;      the sqlite3 CLI on /tmp/telemetry-test-001.db.
;;   2. emit-metric helper equivalence — construct via
;;      `:trading::log::emit-metric` and via the raw
;;      `:trading::log::LogEntry::Telemetry` constructor with the
;;      same field values; assert structurally equal.
;;
;; Lifetime discipline: outer let* holds driver; inner let* owns
;; the popped req-tx + ack pair. Per CIRCUIT.md.

(:wat::test::make-deftest :deftest
  ((:wat::load-file! "wat/io/telemetry/Sqlite.wat")
   (:wat::load-file! "wat/io/log/telemetry.wat")))


;; ─── deftest 1 — Telemetry variant survives sink dispatch ─────────

(:deftest :trading::test::io::log::telemetry::test-telemetry-batch-log
  (:wat::core::let*
    (((path :String) "/tmp/telemetry-test-001.db")
     ((spawn :trading::telemetry::Spawn)
      (:trading::telemetry::Sqlite/spawn path 1
        (:wat::std::telemetry::Service/null-metrics-cadence)))
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
         ;; Three Telemetry rows — Treasury-style (per-Tick batch
         ;; with several metrics).
         ((entries :Vec<trading::log::LogEntry>)
          (:wat::core::vec :trading::log::LogEntry
            (:trading::log::LogEntry::Telemetry
              "treasury" "tick" "{\"window\":\"smoke\"}"
              1700000000000000000
              "deposits" 10000.0 "Count")
            (:trading::log::LogEntry::Telemetry
              "treasury" "tick" "{\"window\":\"smoke\"}"
              1700000000000000000
              "in-trade" 0.0 "Count")
            (:trading::log::LogEntry::Telemetry
              "treasury" "tick" "{\"window\":\"smoke\"}"
              1700000000000000000
              "papers-active" 0.0 "Count"))))
        (:wat::std::telemetry::Service/batch-log req-tx ack-tx ack-rx entries)))
     ((_join :()) (:wat::kernel::join driver)))
    (:wat::test::assert-eq true true)))


;; ─── deftest 2 — emit-metric equivalence ──────────────────────────

(:deftest :trading::test::io::log::telemetry::test-emit-metric-equivalence
  (:wat::core::let*
    (((via-helper :trading::log::LogEntry)
      (:trading::log::emit-metric
        "cache" "encode-cache" "{\"id\":\"main\"}"
        1700000000000000000
        "hits" 42.0 "Count"))
     ((via-raw :trading::log::LogEntry)
      (:trading::log::LogEntry::Telemetry
        "cache" "encode-cache" "{\"id\":\"main\"}"
        1700000000000000000
        "hits" 42.0 "Count")))
    (:wat::test::assert-eq via-helper via-raw)))
