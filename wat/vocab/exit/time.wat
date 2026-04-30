;; wat/vocab/exit/time.wat — Phase 2 (lab arc 002).
;;
;; Temporal context for exit observers. Strict subset of shared/time:
;; hour + day-of-week only. Exit brokers read these two components
;; to detect regime shifts — the rest of the calendar scalars don't
;; carry exit-relevant signal.
;;
;; Takes :trading::types::Candle::Time (not the full Candle), same
;; pattern as shared/time. Callers with a full Candle extract via
;; (:trading::types::Candle/time c).
;;
;; Rounding per proposals 057 + 033 — see shared/helpers.wat's circ.

(:wat::load-file! "../../types/candle.wat")
(:wat::load-file! "../shared/helpers.wat")

;; ─── encode-exit-time-holons — 2 leaves ─────────────────────────────

(:wat::core::define
  (:trading::vocab::exit::time::encode-exit-time-holons
    (t :trading::types::Candle::Time)
    -> :wat::holon::Holons)
  (:wat::core::let*
    (((hour        :wat::core::f64) (:trading::types::Candle::Time/hour        t))
     ((day-of-week :wat::core::f64) (:trading::types::Candle::Time/day-of-week t)))
    (:wat::core::vec :wat::holon::HolonAST
      (:trading::vocab::shared::named-bind "hour"
        (:trading::vocab::shared::circ hour        24.0))
      (:trading::vocab::shared::named-bind "day-of-week"
        (:trading::vocab::shared::circ day-of-week  7.0)))))
