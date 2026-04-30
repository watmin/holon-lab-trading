;; :trading::cache::reporter — closure-over-telemetry-handles factory
;; for HologramCacheService::Reporter.
;;
;; Arc 078 ships `:wat::holon::lru::HologramCacheService::Reporter` as
;; `:fn(Report) -> :()` — a pure function from the substrate's typed
;; emission to whatever sink the lab wants. This file is the lab's
;; sink.
;;
;; Slice 6 (arc 091): the substrate's Event::Log carries the cache
;; stats as a single structured observation per Report::Metrics fire.
;; The 5 stats fields (lookups, hits, misses, puts, cache-size) are
;; SNAPSHOTS — observations of cache state at a moment. Per the
;; metric/log discipline arc 091 surfaced: snapshot-shaped values
;; are Log data, not Metric rows. (Counter-shaped values bumped per
;; occurrence belong on a wu via incr!; duration-shaped values from
;; blocking calls belong on a wu via timed. Cache stats are neither —
;; they're cumulative aggregates the cache service already maintains.)
;;
;; Each Report::Metrics fires ONE Event::Log row. Tags carry cache
;; identity (cache-id + layer) so SQL queries can filter per-cache.
;; Data is the Stats struct lifted to HolonAST + wrapped Tagged so
;; round-trip parsing reads back the typed fields.

(:wat::core::define
  (:trading::cache::reporter/make
    (req-tx :wat::telemetry::Service::ReqTx<wat::telemetry::Event>)
    (ack-rx :wat::telemetry::Service::AckRx)
    (cache-id :wat::core::keyword)        ;; :next | :terminal | caller's choice
    (layer    :wat::core::keyword)        ;; :L1 | :L2 | caller's choice
    -> :wat::holon::lru::HologramCacheService::Reporter)
  (:wat::core::lambda
    ((report :wat::holon::lru::HologramCacheService::Report) -> :())
    (:wat::core::match report -> :()
      ((:wat::holon::lru::HologramCacheService::Report::Metrics stats)
        (:wat::core::let*
          (((time-ns :i64)
            (:wat::time::epoch-nanos (:wat::time::now)))
           ((uuid :String) (:wat::telemetry::uuid::v4))
           ((ns-ast    :wat::holon::HolonAST) (:wat::holon::Atom :trading.cache))
           ((cal-ast   :wat::holon::HolonAST) (:wat::holon::Atom :cache.reporter))
           ((level-ast :wat::holon::HolonAST) (:wat::holon::Atom :info))
           ((tags :wat::telemetry::Tags)
            (:wat::core::assoc
              (:wat::core::assoc
                (:wat::core::HashMap :wat::telemetry::Tag)
                (:wat::holon::Atom :cache-id) (:wat::holon::Atom cache-id))
              (:wat::holon::Atom :layer) (:wat::holon::Atom layer)))
           ;; Stats is a struct — lift via struct->form + from-watast
           ;; (arc 091 slice 8 / arc 093 slice 3 round-trip pattern).
           ;; :wat::holon::Atom does NOT accept struct values directly.
           ((stats-form :wat::WatAST) (:wat::core::struct->form stats))
           ((data-ast :wat::holon::HolonAST) (:wat::holon::from-watast stats-form))
           ((event :wat::telemetry::Event)
            (:wat::telemetry::Event::Log
              time-ns
              (:wat::edn::NoTag/new ns-ast)
              (:wat::edn::NoTag/new cal-ast)
              (:wat::edn::NoTag/new level-ast)
              uuid
              tags
              (:wat::edn::Tagged/new data-ast)))
           ((entries :Vec<wat::telemetry::Event>)
            (:wat::core::vec :wat::telemetry::Event event)))
          (:wat::telemetry::Service/batch-log req-tx ack-rx entries))))))
