;; :trading::telemetry::dispatch — per-variant LogEntry router.
;;
;; Lab proposal 059-002. The dispatcher half of the substrate
;; service contract: substrate's :wat::std::telemetry::Service<E,G>
;; calls dispatch(entry) once per entry inside its worker thread.
;; This wat fn is the lab-side dispatcher that knows about both
;; LogEntry variants (Telemetry + PaperResolved) AND the existing
;; rundb log primitives.
;;
;; Per CIRCUIT.md: Db is thread-owned; the lab worker opens the Db
;; at startup and calls this dispatcher with both the Db handle and
;; the entry. The substrate's queue-fronted shell never sees the Db.

(:wat::load-file! "../log/LogEntry.wat")
(:wat::load-file! "../RunDb.wat")


(:wat::core::define
  (:trading::telemetry::dispatch
    (db :trading::rundb::RunDb)
    (entry :trading::log::LogEntry)
    -> :())
  (:wat::core::match entry -> :()
    ((:trading::log::LogEntry::PaperResolved
        run-name thinker predictor paper-id direction
        opened-at resolved-at state residue loss)
      (:trading::rundb::log-paper-resolved
        db run-name thinker predictor paper-id direction
        opened-at resolved-at state residue loss))
    ((:trading::log::LogEntry::Telemetry
        namespace id dimensions timestamp-ns
        metric-name metric-value metric-unit)
      (:trading::rundb::log-telemetry
        db namespace id dimensions timestamp-ns
        metric-name metric-value metric-unit))))
