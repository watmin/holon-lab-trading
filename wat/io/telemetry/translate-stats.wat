;; :trading::telemetry::translate-stats — substrate Stats →
;; Vec<LogEntry>.
;;
;; Lab proposal 059-002. The stats-translator half of the substrate
;; service contract. Substrate's :wat::std::telemetry::Service<E,G>
;; tick-window calls translate(stats) on cadence-fire to produce
;; entries of E that the dispatcher can write. Three Telemetry
;; entries — one per substrate counter.
;;
;; Tagged with `{"service":"telemetry"}` so SQL queries can filter
;; the rundb's own heartbeat from consumer-driven metrics.

(:wat::load-file! "../log/LogEntry.wat")
(:wat::load-file! "maker.wat")


;; Build the standard rundb-self Telemetry entries from a substrate
;; Stats. Takes an EntryMaker so the test can inject a frozen clock
;; for deterministic timestamps.
(:wat::core::define
  (:trading::telemetry::translate-stats
    (maker :trading::telemetry::EntryMaker)
    (stats :wat::std::telemetry::Service::Stats)
    -> :Vec<trading::log::LogEntry>)
  (:wat::core::let*
    (((dimensions :String) "{\"service\":\"telemetry\"}")
     ((batches-f :f64)
      (:wat::core::i64::to-f64
        (:wat::std::telemetry::Service::Stats/batches stats)))
     ((entries-f :f64)
      (:wat::core::i64::to-f64
        (:wat::std::telemetry::Service::Stats/entries stats)))
     ((max-f :f64)
      (:wat::core::i64::to-f64
        (:wat::std::telemetry::Service::Stats/max-batch-size stats))))
    (:wat::core::vec :trading::log::LogEntry
      (:trading::telemetry::EntryMaker/metric maker
        "rundb" "self" dimensions
        "batches" batches-f "Count")
      (:trading::telemetry::EntryMaker/metric maker
        "rundb" "self" dimensions
        "entries" entries-f "Count")
      (:trading::telemetry::EntryMaker/metric maker
        "rundb" "self" dimensions
        "max-batch-size" max-f "Count"))))
