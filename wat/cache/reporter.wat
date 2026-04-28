;; :trading::cache::reporter — closure-over-rundb-handles factory
;; for HologramCacheService::Reporter.
;;
;; Arc 078 ships :wat::holon::lru::HologramCacheService::Reporter as
;; :fn(Report) -> :() — a pure function from the substrate's typed
;; emission to whatever sink the lab wants. This file is the lab's
;; sink: a Reporter that translates Report::Metrics stats into 5
;; LogEntry::Telemetry rows and flushes them through rundb's
;; batch-log.
;;
;; Why a factory and not a top-level fn: the substrate's Reporter
;; type takes one arg (Report). The flush needs three rundb handles
;; (req-tx, ack-tx, ack-rx). Wat lambdas close over their enclosing
;; environment (per runtime.rs:30 — "evaluation time captures the
;; enclosing Environment"), so make-reporter binds the handles in a
;; let* scope and returns a lambda that uses them on call. The
;; substrate calls reporter(report); the closure builds rows + flushes
;; synchronously to rundb.
;;
;; Why cache-side and not rundb-side: the inversion arc 078 closed.
;; If rundb provided make-reporter for cache, then for broker, then
;; for treasury, rundb would re-acquire knowledge of every consumer's
;; typed events — recoupling what the service-contract decoupling
;; just separated. Each service-with-reporter owns its own translate
;; (cache-specific) + closes over rundb handles (rundb-specific
;; destination) + ships rows through batch-log (rundb's surface).
;; Rundb stays the destination; it does not become a factory.
;;
;; Counter set ships the substrate's 5: lookups / hits / misses /
;; puts / cache-size. Each becomes one LogEntry::Telemetry row.
;; Dimensions JSON tags cache identity per
;; docs/proposals/2026/04/059-the-trader-on-substrate/059-001-l1-l2-caches/DESIGN.md
;; § E: `{"cache":"<id>","layer":"<layer>"}`.
;;
;; Backpressure: batch-log's recv on ack-rx blocks until rundb commits
;; the batch. That backpressure propagates into the cache's worker
;; thread — fine for slice 1; if profiling demands isolation between
;; cache responsiveness and rundb commit latency, future arc adds a
;; queue between cache and rundb.

(:wat::load-file! "../io/log/telemetry.wat")
(:wat::load-file! "../io/RunDbService.wat")

(:wat::core::define
  (:trading::cache::reporter/make
    (req-tx :trading::rundb::Service::ReqTx)
    (ack-tx :trading::rundb::Service::AckTx)
    (ack-rx :trading::rundb::Service::AckRx)
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
            (:trading::rundb::Service/batch-log
              req-tx ack-tx ack-rx entries)))
          ())))))
