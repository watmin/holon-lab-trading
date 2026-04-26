;; wat-tests/io/log/telemetry.wat — smoke tests for arc 030 slice 1.
;;
;; Two deftests:
;;   1. Variant + dispatch round-trip — build a
;;      LogEntry::Telemetry, batch-log via the Service to a
;;      temp DB, no crash. Out-of-band verification via the
;;      sqlite3 CLI on /tmp/telemetry-test-001.db (per arc 027/029
;;      no-read-API-in-wat scope).
;;   2. emit-metric helper equivalence — construct via
;;      `:trading::log::emit-metric` and via the raw
;;      `:trading::log::LogEntry::Telemetry` constructor with the
;;      same field values; assert structurally equal. Per arc 025
;;      slice 2's substrate uplift, enum equality is structural
;;      across variants + fields.
;;
;; Lifetime discipline: same inner-let* trick as
;; wat-tests/io/RunDbService.wat — client ReqTxs must drop before
;; (join driver), or the loop never converges. See that file's
;; header comment for the full rationale.


;; ─── deftest 1 — Telemetry variant survives Service dispatch ──────

(:wat::test::deftest :trading::test::io::log::telemetry::test-telemetry-batch-log
  ()
  (:wat::core::let*
    (((path :String) "/tmp/telemetry-test-001.db")
     ((spawn :trading::rundb::Service::Spawn) (:trading::rundb::Service path 1))
     ((pool :trading::rundb::Service::ReqTxPool) (:wat::core::first spawn))
     ((driver :wat::kernel::ProgramHandle<()>) (:wat::core::second spawn))
     ((_inner :())
      (:wat::core::let*
        (((req-tx :trading::rundb::Service::ReqTx)
          (:wat::kernel::HandlePool::pop pool))
         ((_finish :()) (:wat::kernel::HandlePool::finish pool))
         ((ack-channel :trading::rundb::Service::AckChannel)
          (:wat::kernel::make-bounded-queue :() 1))
         ((ack-tx :trading::rundb::Service::AckTx) (:wat::core::first ack-channel))
         ((ack-rx :trading::rundb::Service::AckRx) (:wat::core::second ack-channel))
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
        (:trading::rundb::Service/batch-log req-tx ack-tx ack-rx entries)))
     ((_join :()) (:wat::kernel::join driver)))
    (:wat::test::assert-eq true true)))


;; ─── deftest 2 — emit-metric equivalence ──────────────────────────

(:wat::test::deftest :trading::test::io::log::telemetry::test-emit-metric-equivalence
  ()
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
