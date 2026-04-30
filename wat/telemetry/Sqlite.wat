;; :trading::telemetry — lab-side wrapper over substrate's
;; :wat::telemetry::Sqlite/auto-spawn (arc 085) parameterized over the
;; substrate's `:wat::telemetry::Event` enum (arc 091 slice 4).
;;
;; Slice 6 retired the lab's `:trading::log::LogEntry` enum entirely.
;; Counters and durations come from `WorkUnit/incr!` / `WorkUnit/timed`
;; (substrate emits Event::Metric rows at scope-close); state-snapshot
;; observations come from `WorkUnitLog/info|warn|error|debug` (substrate
;; emits Event::Log rows). The substrate's auto-dispatch derives a
;; two-table schema directly from the Event enum:
;;
;;   metric: (start_time_ns, end_time_ns, namespace, uuid, tags,
;;            metric_name, metric_value, metric_unit)
;;   log:    (time_ns, namespace, caller, level, uuid, tags, data)
;;
;; Both tables join via `uuid` for cross-shape queries.
;;
;; The lab keeps just the spawn wrapper + pragma policy. Call sites
;; reference the substrate's `Service::*<wat::telemetry::Event>` types
;; directly — the substrate's 1-level alias-with-generic-arg
;; expansion handles them; nullary lab indirection layered on top
;; doesn't transitively expand and so was retired.

;; ─── Pragma policy — lab's choice, not the substrate's ──────────
;;
;; WAL gives concurrent reads while a writer holds the connection;
;; synchronous=NORMAL trades a tiny crash-window for ~10x flush
;; throughput. Both are the lab's call. Other consumers (or future
;; trading subdomains) pick their own pre-install closure.
(:wat::core::define
  (:trading::telemetry::Sqlite::pre-install
    (db :wat::sqlite::Db)
    -> :())
  (:wat::core::let*
    (((_w :()) (:wat::sqlite::pragma db "journal_mode" "WAL"))
     ((_s :()) (:wat::sqlite::pragma db "synchronous" "NORMAL")))
    ()))


;; ─── Spawn — Service<Event,_> over the lab's pragma policy ──────
;;
;; Caller picks a cadence (use `Service/null-metrics-cadence` for
;; pull-only scopes; pass a real cadence to fire stats translators).
(:wat::core::define
  (:trading::telemetry::Sqlite/spawn<G>
    (path :wat::core::String)
    (count :wat::core::i64)
    (cadence :wat::telemetry::Service::MetricsCadence<G>)
    -> :wat::telemetry::Service::Spawn<wat::telemetry::Event>)
  (:wat::telemetry::Sqlite/auto-spawn
    :wat::telemetry::Event path count cadence
    :trading::telemetry::Sqlite::pre-install))
