;; wat/vocab/shared/time.wat — Phase 2.1 (lab arc 001).
;;
;; Temporal context. All circular scalars — the value wraps at the
;; component's period (minute:60, hour:24, day-of-week:7, day-of-
;; month:31, month-of-year:12).
;;
;; Takes :trading::types::Candle::Time (not the full Candle). Matches
;; the candle.wat header comment — each vocab family reads from its
;; specific sub-struct. Callers with a full Candle extract the sub-
;; struct via (:trading::types::Candle/time c).
;;
;; Rounding: every circular value goes through (f64::round val 0)
;; before encoding — whole-integer cache-key quantization. The unit
;; IS integer (hour 14, minute 30) so this is the honest granularity.
;; Per proposal 057's RESOLUTION: round_to at emission is cache-key
;; quantization, not signal precision. Per 033: quantization tightens
;; the cache without narrowing the algebra's view.
;;
;; Self-load dependency (arc 027 slice 4): this vocab reads
;; :trading::types::Candle::Time. `../../types/candle.wat` resolves
;; against this file's directory. Dedup is a no-op on repeat loads.

(:wat::load-file! "../../types/candle.wat")
;;
;; Exports two defines:
;;
;;   encode-time-facts : 5 leaf binds (one per circular component)
;;   time-facts        : 5 leaves + 3 pairwise compositions
;;                       (minute × hour, hour × dow, dow × month)
;;
;; Both are vocabulary. The thinker bundles whatever set it wants;
;; the discriminant picks the winners. Ship both (archive comment
;; pinned this intent).

;; ─── Local helpers (file-private defines) ──────────────────────────

;; Build a Circular fact from a raw f64 at integer quantization.
(:wat::core::define
  (:trading::vocab::shared::time::circ
    (value :f64)
    (period :f64)
    -> :wat::holon::HolonAST)
  (:wat::holon::Circular
    (:wat::core::f64::round value 0)
    period))

;; Build a Bind(Atom(name), child) pair. Local readability helper —
;; five emission sites beats five inline Bind/Atom pairs for the
;; reader. Extracts to a shared vocab helpers module when a second
;; vocab module surfaces the same pattern.
(:wat::core::define
  (:trading::vocab::shared::time::named-bind
    (name :String)
    (child :wat::holon::HolonAST)
    -> :wat::holon::HolonAST)
  (:wat::holon::Bind
    (:wat::holon::Atom name)
    child))

;; ─── encode-time-facts — 5 leaves ──────────────────────────────────

(:wat::core::define
  (:trading::vocab::shared::time::encode-time-facts
    (t :trading::types::Candle::Time)
    -> :Vec<wat::holon::HolonAST>)
  (:wat::core::let*
    (((minute        :f64) (:trading::types::Candle::Time/minute        t))
     ((hour          :f64) (:trading::types::Candle::Time/hour          t))
     ((day-of-week   :f64) (:trading::types::Candle::Time/day-of-week   t))
     ((day-of-month  :f64) (:trading::types::Candle::Time/day-of-month  t))
     ((month-of-year :f64) (:trading::types::Candle::Time/month-of-year t)))
    (:wat::core::vec :wat::holon::HolonAST
      (:trading::vocab::shared::time::named-bind "minute"
        (:trading::vocab::shared::time::circ minute        60.0))
      (:trading::vocab::shared::time::named-bind "hour"
        (:trading::vocab::shared::time::circ hour          24.0))
      (:trading::vocab::shared::time::named-bind "day-of-week"
        (:trading::vocab::shared::time::circ day-of-week    7.0))
      (:trading::vocab::shared::time::named-bind "day-of-month"
        (:trading::vocab::shared::time::circ day-of-month  31.0))
      (:trading::vocab::shared::time::named-bind "month-of-year"
        (:trading::vocab::shared::time::circ month-of-year 12.0)))))

;; ─── time-facts — 5 leaves + 3 pairwise compositions ───────────────
;;
;; The three compositions express "this pair matters together" — the
;; discriminant learns whether the composite carries signal the
;; individual leaves don't.

(:wat::core::define
  (:trading::vocab::shared::time::time-facts
    (t :trading::types::Candle::Time)
    -> :Vec<wat::holon::HolonAST>)
  (:wat::core::let*
    (((minute        :f64) (:trading::types::Candle::Time/minute        t))
     ((hour          :f64) (:trading::types::Candle::Time/hour          t))
     ((day-of-week   :f64) (:trading::types::Candle::Time/day-of-week   t))
     ((day-of-month  :f64) (:trading::types::Candle::Time/day-of-month  t))
     ((month-of-year :f64) (:trading::types::Candle::Time/month-of-year t))

     ((minute-bind :wat::holon::HolonAST)
      (:trading::vocab::shared::time::named-bind "minute"
        (:trading::vocab::shared::time::circ minute        60.0)))
     ((hour-bind :wat::holon::HolonAST)
      (:trading::vocab::shared::time::named-bind "hour"
        (:trading::vocab::shared::time::circ hour          24.0)))
     ((dow-bind :wat::holon::HolonAST)
      (:trading::vocab::shared::time::named-bind "day-of-week"
        (:trading::vocab::shared::time::circ day-of-week    7.0)))
     ((dom-bind :wat::holon::HolonAST)
      (:trading::vocab::shared::time::named-bind "day-of-month"
        (:trading::vocab::shared::time::circ day-of-month  31.0)))
     ((month-bind :wat::holon::HolonAST)
      (:trading::vocab::shared::time::named-bind "month-of-year"
        (:trading::vocab::shared::time::circ month-of-year 12.0)))

     ((minute-x-hour  :wat::holon::HolonAST)
      (:wat::holon::Bind minute-bind hour-bind))
     ((hour-x-dow     :wat::holon::HolonAST)
      (:wat::holon::Bind hour-bind   dow-bind))
     ((dow-x-month    :wat::holon::HolonAST)
      (:wat::holon::Bind dow-bind    month-bind)))
    (:wat::core::vec :wat::holon::HolonAST
      minute-bind hour-bind dow-bind dom-bind month-bind
      minute-x-hour hour-x-dow dow-x-month)))
