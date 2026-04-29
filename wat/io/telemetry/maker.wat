;; :trading::telemetry::EntryMaker — closure over a clock that
;; constructs timestamped LogEntry values.
;;
;; Lab proposal 059-002 sub-slice A. The user's pattern from the
;; 2026-04-29 architecture debate: every Reporter (and every
;; producer) builds entries via the maker. Tests inject a frozen
;; now-fn for deterministic timestamps; production wires
;; `(:wat::time::now)`.
;;
;; Substrate ships ZERO entry variants (per arc 080 / user
;; correction). The lab's `:trading::log::LogEntry` is the
;; trader-defined entry enum with PaperResolved + Telemetry
;; variants (defined in wat/io/log/LogEntry.wat). The maker's
;; constructor helpers wrap LogEntry's auto-derived variant
;; constructors with the timestamp injected from the captured clock.

(:wat::load-file! "../log/LogEntry.wat")


;; ─── The maker — struct holding the clock fn ─────────────────────

(:wat::core::struct :trading::telemetry::EntryMaker
  (now-fn :fn(())->wat::time::Instant))


;; ─── Factory ─────────────────────────────────────────────────────

;; Make an EntryMaker that timestamps entries via `now-fn`. Tests
;; pass `(lambda () frozen-instant)`; production passes
;; `(lambda () (:wat::time::now))`.
(:wat::core::define
  (:trading::telemetry::maker/make
    (now-fn :fn(())->wat::time::Instant)
    -> :trading::telemetry::EntryMaker)
  (:trading::telemetry::EntryMaker/new now-fn))


;; ─── Helper — invoke the maker's clock, return epoch-millis ──────

(:wat::core::define
  (:trading::telemetry::EntryMaker/now-millis
    (maker :trading::telemetry::EntryMaker)
    -> :i64)
  (:wat::core::let*
    (((now-fn :fn(())->wat::time::Instant)
      (:trading::telemetry::EntryMaker/now-fn maker)))
    (:wat::time::epoch-millis (now-fn ()))))


;; ─── Constructor helpers — one per LogEntry variant ──────────────

;; Build a Telemetry entry with timestamp injected from the maker's
;; clock. Field order follows :trading::log::LogEntry::Telemetry's
;; constructor + :trading::rundb::log-telemetry's column order.
(:wat::core::define
  (:trading::telemetry::EntryMaker/metric
    (maker :trading::telemetry::EntryMaker)
    (namespace :String) (id :String) (dimensions :String)
    (metric-name :String) (metric-value :f64) (metric-unit :String)
    -> :trading::log::LogEntry)
  (:wat::core::let*
    (((ts :i64) (:trading::telemetry::EntryMaker/now-millis maker)))
    (:trading::log::LogEntry::Telemetry
      namespace id dimensions ts
      metric-name metric-value metric-unit)))

;; Build a PaperResolved entry. PaperResolved doesn't take a
;; timestamp from the maker — the resolution carries opened-at and
;; resolved-at as candle indices already. Maker just provides the
;; ergonomic wrapper.
(:wat::core::define
  (:trading::telemetry::EntryMaker/paper-resolved
    (_maker :trading::telemetry::EntryMaker)
    (run-name :String) (thinker :String) (predictor :String)
    (paper-id :i64) (direction :String)
    (opened-at :i64) (resolved-at :i64)
    (state :String) (residue :f64) (loss :f64)
    -> :trading::log::LogEntry)
  (:trading::log::LogEntry::PaperResolved
    run-name thinker predictor paper-id direction
    opened-at resolved-at state residue loss))
