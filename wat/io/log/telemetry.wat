;; :trading::log::emit-metric — convenience constructor for
;; Telemetry LogEntries.
;;
;; Mirrors the archive's
;; `archived/pre-wat-native/src/programs/telemetry.rs::emit_metric`
;; — pure function from `(namespace, id, dimensions, ts, name,
;;  value, unit)` to a `:trading::log::LogEntry::Telemetry`
;; value. No I/O, no rate gate.
;;
;; Usage shape:
;;   (let* (((entries :Vec<trading::log::LogEntry>)
;;           (vec :trading::log::LogEntry
;;             (:trading::log::emit-metric
;;               "treasury" "tick" "{\"window\":\"w0\"}"
;;               ts "deposits" 1234.0 "Count")
;;             (:trading::log::emit-metric
;;               "treasury" "tick" "{\"window\":\"w0\"}"
;;               ts "in-trade" 567.0 "Count"))))
;;     (:trading::rundb::Service/batch-log
;;       req-tx ack-tx ack-rx entries))
;;
;; Per arc 030 DESIGN Q7: NO `make-rate-gate` ships in this slice.
;; Event-driven callers (Treasury per Tick, future broker per
;; candle) batch their own metrics and flush per event — the
;; program rhythm IS the rate gate when one exists. The cache
;; (slice 2) is the only consumer without a natural rhythm; the
;; rate-gate question lands there when the substrate path is
;; clearer.

(:wat::load-file! "LogEntry.wat")


(:wat::core::define
  (:trading::log::emit-metric
    (namespace :String)
    (id :String)
    (dimensions :String)
    (timestamp-ns :i64)
    (metric-name :String)
    (metric-value :f64)
    (metric-unit :String)
    -> :trading::log::LogEntry)
  (:trading::log::LogEntry::Telemetry
    namespace id dimensions timestamp-ns
    metric-name metric-value metric-unit))
