;; wat/vocab/market/persistence.wat — Phase 2.6 (lab arc 008).
;;
;; Port of archived/pre-wat-native/src/vocab/market/persistence.rs
;; (36L). Three scaled-linear atoms describing memory in the series:
;;
;;   hurst           — long-memory exponent
;;   autocorrelation — lag-1 autocorrelation
;;   adx             — directional-movement strength (normalized /100)
;;
;; FIRST CROSS-SUB-STRUCT VOCAB. The signature rule task #49
;; resolved to the alphabetical-by-type form here: parameters declare
;; every sub-struct the vocab reads, one parameter each, ordered
;; alphabetically by the sub-struct's type name. Scales last.
;;
;; Signature order: `m :Candle::Momentum` before `p :Candle::Persistence`
;; (M < P). Emission order independent: the archive emits hurst then
;; autocorrelation then adx, a semantic grouping (memory-in-series
;; first, directional-strength second). Type-check discipline cares
;; about the signature; reader discipline chooses the emission order
;; per module.
;;
;; See docs/arc/2026/04/008-market-persistence-vocab/DESIGN.md for
;; the rule's full derivation and why alternatives lose.

(:wat::load-file! "../../types/candle.wat")
(:wat::load-file! "../../encoding/scale-tracker.wat")
(:wat::load-file! "../../encoding/scaled-linear.wat")

(:wat::core::define
  (:trading::vocab::market::persistence::encode-persistence-holons
    (m :trading::types::Candle::Momentum)
    (p :trading::types::Candle::Persistence)
    (scales :trading::encoding::Scales)
    -> :trading::encoding::VocabEmission)
  (:wat::core::let*
    ;; Normalize + round the three values.
    (((hurst :f64)
      (:trading::encoding::round-to-2
        (:trading::types::Candle::Persistence/hurst p)))
     ((autocorr :f64)
      (:trading::encoding::round-to-2
        (:trading::types::Candle::Persistence/autocorrelation p)))
     ((adx :f64)
      (:trading::encoding::round-to-2
        (:wat::core::/
          (:trading::types::Candle::Momentum/adx m) 100.0)))

     ;; Thread Scales through three scaled-linear calls — emission
     ;; order: hurst, autocorrelation, adx (archive ordering).
     ((e1 :trading::encoding::ScaleEmission)
      (:trading::encoding::scaled-linear "hurst" hurst scales))
     ((h1 :wat::holon::HolonAST) (:wat::core::first e1))
     ((s1 :trading::encoding::Scales) (:wat::core::second e1))

     ((e2 :trading::encoding::ScaleEmission)
      (:trading::encoding::scaled-linear "autocorrelation" autocorr s1))
     ((h2 :wat::holon::HolonAST) (:wat::core::first e2))
     ((s2 :trading::encoding::Scales) (:wat::core::second e2))

     ((e3 :trading::encoding::ScaleEmission)
      (:trading::encoding::scaled-linear "adx" adx s2))
     ((h3 :wat::holon::HolonAST) (:wat::core::first e3))
     ((s3 :trading::encoding::Scales) (:wat::core::second e3))

     ;; Assemble the Holons vec.
     ((holons :wat::holon::Holons)
      (:wat::core::vec :wat::holon::HolonAST h1 h2 h3)))
    (:wat::core::tuple holons s3)))
