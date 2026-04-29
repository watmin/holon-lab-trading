;; :trading::cache::reporter — closure-over-telemetry-handles factory
;; for HologramCacheService::Reporter.
;;
;; Arc 078 ships :wat::holon::lru::HologramCacheService::Reporter as
;; :fn(Report) -> :() — a pure function from the substrate's typed
;; emission to whatever sink the lab wants. This file is the lab's
;; sink: a Reporter that translates Report::Metrics stats into 5
;; LogEntry::Telemetry rows and flushes them through the substrate
;; telemetry sink's batch-log.
;;
;; Why a factory and not a top-level fn: the substrate's Reporter
;; type takes one arg (Report). The flush needs three telemetry
;; handles (req-tx, ack-tx, ack-rx). Wat lambdas close over their
;; enclosing environment (per runtime.rs:30 — "evaluation time
;; captures the enclosing Environment"), so make-reporter binds the
;; handles in a let* scope and returns a lambda that uses them on
;; call. The substrate calls reporter(report); the closure builds
;; rows + flushes synchronously through the telemetry queue.
;;
;; Why cache-side and not telemetry-side: the inversion arc 078
;; closed. If the sink provided make-reporter for cache, then for
;; broker, then for treasury, the sink would re-acquire knowledge
;; of every consumer's typed events — recoupling what the
;; service-contract decoupling just separated. Each
;; service-with-reporter owns its own translate (cache-specific) +
;; closes over telemetry handles (sink destination) + ships rows
;; through batch-log (substrate's surface).
;;
;; Counter set ships the substrate's 5: lookups / hits / misses /
;; puts / cache-size. Each becomes one LogEntry::Telemetry row.
;; Dimensions JSON tags cache identity per
;; docs/proposals/2026/04/059-the-trader-on-substrate/059-001-l1-l2-caches/DESIGN.md
;; § E: `{"cache":"<id>","layer":"<layer>"}`.

(:wat::load-file! "../io/log/telemetry.wat")

(:wat::core::define
  (:trading::cache::reporter/make
    (req-tx :wat::std::telemetry::Service::ReqTx<trading::log::LogEntry>)
    (ack-tx :wat::std::telemetry::Service::AckTx)
    (ack-rx :wat::std::telemetry::Service::AckRx)
    (cache-id :String)        ;; "next" | "terminal" | caller's choice
    (layer :String)           ;; "L1" | "L2" | caller's choice
    -> :wat::holon::lru::HologramCacheService::Reporter)
  (:wat::core::lambda
    ((report :wat::holon::lru::HologramCacheService::Report) -> :())
    (:wat::core::match report -> :()
      ((:wat::holon::lru::HologramCacheService::Report::Metrics stats)
        (:wat::core::let*
          (((dimensions :String)
            (:wat::core::string::concat
              "{\"cache\":\"" cache-id
              "\",\"layer\":\""  layer
              "\"}"))
           ((ts :i64) (:wat::time::epoch-millis (:wat::time::now)))
           ((entries :Vec<trading::log::LogEntry>)
            (:wat::core::vec :trading::log::LogEntry
              (:trading::log::emit-metric
                "cache" cache-id dimensions ts
                "lookups"
                (:wat::core::i64::to-f64
                  (:wat::holon::lru::HologramCacheService::Stats/lookups stats))
                "Count")
              (:trading::log::emit-metric
                "cache" cache-id dimensions ts
                "hits"
                (:wat::core::i64::to-f64
                  (:wat::holon::lru::HologramCacheService::Stats/hits stats))
                "Count")
              (:trading::log::emit-metric
                "cache" cache-id dimensions ts
                "misses"
                (:wat::core::i64::to-f64
                  (:wat::holon::lru::HologramCacheService::Stats/misses stats))
                "Count")
              (:trading::log::emit-metric
                "cache" cache-id dimensions ts
                "puts"
                (:wat::core::i64::to-f64
                  (:wat::holon::lru::HologramCacheService::Stats/puts stats))
                "Count")
              (:trading::log::emit-metric
                "cache" cache-id dimensions ts
                "cache-size"
                (:wat::core::i64::to-f64
                  (:wat::holon::lru::HologramCacheService::Stats/cache-size stats))
                "Count")))
           ((_ :())
            (:wat::std::telemetry::Service/batch-log
              req-tx ack-tx ack-rx entries)))
          ())))))
