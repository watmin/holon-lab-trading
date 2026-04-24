;; wat/vocab/market/fibonacci.wat — Phase 2.5 (lab arc 007).
;;
;; Port of archived/pre-wat-native/src/vocab/market/fibonacci.rs
;; (72L). Eight holons per candle derived from range-position
;; windows:
;;
;;   Three raw positions over 12/24/48-candle windows:
;;     range-pos-12, range-pos-24, range-pos-48
;;
;;   Five Fibonacci-retracement distances from range-pos-48:
;;     fib-dist-236 = range-pos-48 - 0.236
;;     fib-dist-382 = range-pos-48 - 0.382
;;     fib-dist-500 = range-pos-48 - 0.500
;;     fib-dist-618 = range-pos-48 - 0.618
;;     fib-dist-786 = range-pos-48 - 0.786
;;
;; Reads Candle::RateOfChange — the same sub-struct oscillators
;; uses for ROC atoms, but from disjoint fields (range-pos-* rather
;; than roc-*). Single-sub-struct leaf; no cross-sub-struct fog.
;;
;; All eight atoms via scaled-linear. Returns VocabEmission.

(:wat::load-file! "../../types/candle.wat")
(:wat::load-file! "../../encoding/scale-tracker.wat")
(:wat::load-file! "../../encoding/scaled-linear.wat")

(:wat::core::define
  (:trading::vocab::market::fibonacci::encode-fibonacci-holons
    (r :trading::types::Candle::RateOfChange)
    (scales :trading::encoding::Scales)
    -> :trading::encoding::VocabEmission)
  (:wat::core::let*
    ;; Pull the three window positions. Fib distances derive from
    ;; range-pos-48 only; the 12 and 24 windows emit raw.
    (((rp-12 :f64)
      (:trading::encoding::round-to-2
        (:trading::types::Candle::RateOfChange/range-pos-12 r)))
     ((rp-24 :f64)
      (:trading::encoding::round-to-2
        (:trading::types::Candle::RateOfChange/range-pos-24 r)))
     ((rp-48-raw :f64)
      (:trading::types::Candle::RateOfChange/range-pos-48 r))
     ((rp-48 :f64) (:trading::encoding::round-to-2 rp-48-raw))

     ;; Fibonacci retracement distances from the 48-window position.
     ((fd-236 :f64)
      (:trading::encoding::round-to-2
        (:wat::core::f64::- rp-48-raw 0.236)))
     ((fd-382 :f64)
      (:trading::encoding::round-to-2
        (:wat::core::f64::- rp-48-raw 0.382)))
     ((fd-500 :f64)
      (:trading::encoding::round-to-2
        (:wat::core::f64::- rp-48-raw 0.500)))
     ((fd-618 :f64)
      (:trading::encoding::round-to-2
        (:wat::core::f64::- rp-48-raw 0.618)))
     ((fd-786 :f64)
      (:trading::encoding::round-to-2
        (:wat::core::f64::- rp-48-raw 0.786)))

     ;; Thread Scales through eight scaled-linear calls.
     ((e1 :trading::encoding::ScaleEmission)
      (:trading::encoding::scaled-linear "range-pos-12" rp-12 scales))
     ((h1 :wat::holon::HolonAST) (:wat::core::first e1))
     ((s1 :trading::encoding::Scales) (:wat::core::second e1))

     ((e2 :trading::encoding::ScaleEmission)
      (:trading::encoding::scaled-linear "range-pos-24" rp-24 s1))
     ((h2 :wat::holon::HolonAST) (:wat::core::first e2))
     ((s2 :trading::encoding::Scales) (:wat::core::second e2))

     ((e3 :trading::encoding::ScaleEmission)
      (:trading::encoding::scaled-linear "range-pos-48" rp-48 s2))
     ((h3 :wat::holon::HolonAST) (:wat::core::first e3))
     ((s3 :trading::encoding::Scales) (:wat::core::second e3))

     ((e4 :trading::encoding::ScaleEmission)
      (:trading::encoding::scaled-linear "fib-dist-236" fd-236 s3))
     ((h4 :wat::holon::HolonAST) (:wat::core::first e4))
     ((s4 :trading::encoding::Scales) (:wat::core::second e4))

     ((e5 :trading::encoding::ScaleEmission)
      (:trading::encoding::scaled-linear "fib-dist-382" fd-382 s4))
     ((h5 :wat::holon::HolonAST) (:wat::core::first e5))
     ((s5 :trading::encoding::Scales) (:wat::core::second e5))

     ((e6 :trading::encoding::ScaleEmission)
      (:trading::encoding::scaled-linear "fib-dist-500" fd-500 s5))
     ((h6 :wat::holon::HolonAST) (:wat::core::first e6))
     ((s6 :trading::encoding::Scales) (:wat::core::second e6))

     ((e7 :trading::encoding::ScaleEmission)
      (:trading::encoding::scaled-linear "fib-dist-618" fd-618 s6))
     ((h7 :wat::holon::HolonAST) (:wat::core::first e7))
     ((s7 :trading::encoding::Scales) (:wat::core::second e7))

     ((e8 :trading::encoding::ScaleEmission)
      (:trading::encoding::scaled-linear "fib-dist-786" fd-786 s7))
     ((h8 :wat::holon::HolonAST) (:wat::core::first e8))
     ((s8 :trading::encoding::Scales) (:wat::core::second e8))

     ;; Assemble the Holons vec.
     ((holons :wat::holon::Holons)
      (:wat::core::vec :wat::holon::HolonAST
        h1 h2 h3 h4 h5 h6 h7 h8)))
    (:wat::core::tuple holons s8)))
