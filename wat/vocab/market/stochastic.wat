;; wat/vocab/market/stochastic.wat — Phase 2.7 (lab arc 009).
;;
;; Port of archived/pre-wat-native/src/vocab/market/stochastic.rs
;; (36L). Four scaled-linear atoms describing %K/%D spread and
;; crosses:
;;
;;   stoch-k            — %K in [0, 1] (normalized /100)
;;   stoch-d            — %D in [0, 1] (normalized /100)
;;   stoch-kd-spread    — (%K - %D) in [-1, 1]
;;   stoch-cross-delta  — signed crossover strength, clamped [-1, 1]
;;
;; SECOND CROSS-SUB-STRUCT VOCAB — ships under arc 008's signature
;; rule. Signature order alphabetical by sub-struct type name
;; (D < M for Divergence < Momentum). Emission order matches
;; archive semantic grouping (k, d, spread, cross-delta).
;;
;; The stoch-cross-delta atom inline-clamps its raw value to
;; [-1, 1] via nested if — archive uses .max(-1).min(1). Single
;; use in this module; stdlib-as-blueprint keeps it inline until
;; a second clamp caller surfaces (then extract to
;; shared/helpers.wat per arc 006's conditional-emission pattern).

(:wat::load-file! "../../types/candle.wat")
(:wat::load-file! "../../encoding/scale-tracker.wat")
(:wat::load-file! "../../encoding/scaled-linear.wat")

(:wat::core::define
  (:trading::vocab::market::stochastic::encode-stochastic-holons
    (d :trading::types::Candle::Divergence)
    (m :trading::types::Candle::Momentum)
    (scales :trading::encoding::Scales)
    -> :trading::encoding::VocabEmission)
  (:wat::core::let*
    ;; Normalize stochastic %K/%D to [0, 1].
    (((k-norm :f64)
      (:wat::core::f64::/
        (:trading::types::Candle::Momentum/stoch-k m) 100.0))
     ((d-norm :f64)
      (:wat::core::f64::/
        (:trading::types::Candle::Momentum/stoch-d m) 100.0))

     ;; Four atom values, rounded.
     ((stoch-k :f64) (:trading::encoding::round-to-2 k-norm))
     ((stoch-d :f64) (:trading::encoding::round-to-2 d-norm))
     ((stoch-kd-spread :f64)
      (:trading::encoding::round-to-2
        (:wat::core::f64::- k-norm d-norm)))

     ;; Inline clamp to [-1, 1] for the cross-delta.
     ((raw-delta :f64)
      (:trading::types::Candle::Divergence/stoch-cross-delta d))
     ((clamped-delta :f64)
      (:wat::core::if (:wat::core::>= raw-delta 1.0) -> :f64
        1.0
        (:wat::core::if (:wat::core::<= raw-delta -1.0) -> :f64
          (:wat::core::f64::- 0.0 1.0)
          raw-delta)))
     ((stoch-cross-delta :f64)
      (:trading::encoding::round-to-2 clamped-delta))

     ;; Thread Scales through four scaled-linear calls.
     ((e1 :trading::encoding::ScaleEmission)
      (:trading::encoding::scaled-linear "stoch-k" stoch-k scales))
     ((h1 :wat::holon::HolonAST) (:wat::core::first e1))
     ((s1 :trading::encoding::Scales) (:wat::core::second e1))

     ((e2 :trading::encoding::ScaleEmission)
      (:trading::encoding::scaled-linear "stoch-d" stoch-d s1))
     ((h2 :wat::holon::HolonAST) (:wat::core::first e2))
     ((s2 :trading::encoding::Scales) (:wat::core::second e2))

     ((e3 :trading::encoding::ScaleEmission)
      (:trading::encoding::scaled-linear "stoch-kd-spread" stoch-kd-spread s2))
     ((h3 :wat::holon::HolonAST) (:wat::core::first e3))
     ((s3 :trading::encoding::Scales) (:wat::core::second e3))

     ((e4 :trading::encoding::ScaleEmission)
      (:trading::encoding::scaled-linear "stoch-cross-delta" stoch-cross-delta s3))
     ((h4 :wat::holon::HolonAST) (:wat::core::first e4))
     ((s4 :trading::encoding::Scales) (:wat::core::second e4))

     ;; Assemble the Holons vec.
     ((holons :wat::holon::Holons)
      (:wat::core::vec :wat::holon::HolonAST h1 h2 h3 h4)))
    (:wat::core::tuple holons s4)))
