;; wat/vocab/market/oscillators.wat — Phase 2.3 (lab arc 005).
;;
;; Port of archived/pre-wat-native/src/vocab/market/oscillators.rs
;; (84L). Eight oscillator holons per candle, split two ways:
;;
;;   Four bounded scalars → scaled-linear (threads Scales values-up):
;;     rsi, cci, mfi, williams-r
;;
;;   Four ratio-valued → ReciprocalLog 2.0 (no scales, fixed bounds):
;;     roc-1, roc-3, roc-6, roc-12
;;
;; Takes two sub-structs (Momentum + RateOfChange) per arc 001's
;; "vocab reads its specific sub-struct" pattern. Caller with a
;; full Candle extracts via :Candle/momentum and :Candle/rate-of-change.
;;
;; Returns (Holons, Scales) tuple — values-up signaling.
;; scaled-linear-threaded Scales is the stateful one; Log-emitted
;; holons need no scale tracking.
;;
;; Rationale for ReciprocalLog 2.0 on ROC atoms (arc 034):
;;   value = 1.0 + roc IS a price ratio (close/prev).
;;   N = 2 saturates at the smallest reciprocal pair (0.5, 2.0) —
;;   ±doubling per single candle. ±1% resolves distinctly; ±100%
;;   saturates gracefully. See docs/arc/2026/04/005-.../explore-log.wat
;;   for the empirical table.

(:wat::load-file! "../../types/candle.wat")
(:wat::load-file! "../../encoding/scale-tracker.wat")
(:wat::load-file! "../../encoding/scaled-linear.wat")

(:wat::core::define
  (:trading::vocab::market::oscillators::encode-oscillators-holons
    (m :trading::types::Candle::Momentum)
    (r :trading::types::Candle::RateOfChange)
    (scales :trading::encoding::Scales)
    -> :(wat::holon::Holons,trading::encoding::Scales))
  (:wat::core::let*
    ;; Extract + normalize the four bounded scalars.
    (((rsi :f64)
      (:trading::encoding::round-to-2
        (:trading::types::Candle::Momentum/rsi m)))
     ((cci :f64)
      (:trading::encoding::round-to-2
        (:wat::core::f64::/
          (:trading::types::Candle::Momentum/cci m) 300.0)))
     ((mfi :f64)
      (:trading::encoding::round-to-2
        (:wat::core::f64::/
          (:trading::types::Candle::Momentum/mfi m) 100.0)))
     ((williams-r :f64)
      (:trading::encoding::round-to-2
        (:wat::core::f64::/
          (:wat::core::f64::+
            (:trading::types::Candle::Momentum/williams-r m) 100.0)
          100.0)))

     ;; Extract + normalize the four ratio-valued scalars.
     ((roc-1 :f64)
      (:trading::encoding::round-to-2
        (:wat::core::f64::+ 1.0
          (:trading::types::Candle::RateOfChange/roc-1 r))))
     ((roc-3 :f64)
      (:trading::encoding::round-to-2
        (:wat::core::f64::+ 1.0
          (:trading::types::Candle::RateOfChange/roc-3 r))))
     ((roc-6 :f64)
      (:trading::encoding::round-to-2
        (:wat::core::f64::+ 1.0
          (:trading::types::Candle::RateOfChange/roc-6 r))))
     ((roc-12 :f64)
      (:trading::encoding::round-to-2
        (:wat::core::f64::+ 1.0
          (:trading::types::Candle::RateOfChange/roc-12 r))))

     ;; Thread Scales through the four scaled-linear calls.
     ((e1 :trading::encoding::ScaleEmission)
      (:trading::encoding::scaled-linear "rsi" rsi scales))
     ((h1 :wat::holon::HolonAST) (:wat::core::first e1))
     ((s1 :trading::encoding::Scales) (:wat::core::second e1))

     ((e2 :trading::encoding::ScaleEmission)
      (:trading::encoding::scaled-linear "cci" cci s1))
     ((h2 :wat::holon::HolonAST) (:wat::core::first e2))
     ((s2 :trading::encoding::Scales) (:wat::core::second e2))

     ((e3 :trading::encoding::ScaleEmission)
      (:trading::encoding::scaled-linear "mfi" mfi s2))
     ((h3 :wat::holon::HolonAST) (:wat::core::first e3))
     ((s3 :trading::encoding::Scales) (:wat::core::second e3))

     ((e4 :trading::encoding::ScaleEmission)
      (:trading::encoding::scaled-linear "williams-r" williams-r s3))
     ((h4 :wat::holon::HolonAST) (:wat::core::first e4))
     ((s4 :trading::encoding::Scales) (:wat::core::second e4))

     ;; Build the four Log-encoded ROC holons directly.
     ;; ReciprocalLog 2.0 expands to (Log value 0.5 2.0).
     ((h5 :wat::holon::HolonAST)
      (:wat::holon::Bind
        (:wat::holon::Atom "roc-1")
        (:wat::holon::ReciprocalLog 2.0 roc-1)))
     ((h6 :wat::holon::HolonAST)
      (:wat::holon::Bind
        (:wat::holon::Atom "roc-3")
        (:wat::holon::ReciprocalLog 2.0 roc-3)))
     ((h7 :wat::holon::HolonAST)
      (:wat::holon::Bind
        (:wat::holon::Atom "roc-6")
        (:wat::holon::ReciprocalLog 2.0 roc-6)))
     ((h8 :wat::holon::HolonAST)
      (:wat::holon::Bind
        (:wat::holon::Atom "roc-12")
        (:wat::holon::ReciprocalLog 2.0 roc-12)))

     ;; Assemble the Holons vec.
     ((holons :wat::holon::Holons)
      (:wat::core::vec :wat::holon::HolonAST
        h1 h2 h3 h4 h5 h6 h7 h8)))
    (:wat::core::tuple holons s4)))
