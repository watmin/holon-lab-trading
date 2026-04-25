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
;; The stoch-cross-delta atom calls `:wat::core::f64::clamp` —
;; substrate primitive shipped via wat-rs arc 046 (lab arc 015
;; surfaced the gap during ichimoku port; the framing question
;; "userland or substrate?" landed on substrate, every wat user
;; needs it). Migrated from arc 009's original inline two-arm-if
;; in the same arc 015 sweep.

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

     ;; Clamp the cross-delta to [-1, 1] via substrate f64::clamp.
     ((raw-delta :f64)
      (:trading::types::Candle::Divergence/stoch-cross-delta d))
     ((stoch-cross-delta :f64)
      (:trading::encoding::round-to-2
        (:wat::core::f64::clamp raw-delta -1.0 1.0)))

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
