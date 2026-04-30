;; wat/vocab/market/divergence.wat — Phase 2.4 (lab arc 006).
;;
;; Port of archived/pre-wat-native/src/vocab/market/divergence.rs
;; (60L). Three atoms, conditional emission:
;;
;;   rsi-divergence-bull — emit when Candle::Divergence.rsi-divergence-bull > 0
;;   rsi-divergence-bear — emit when Candle::Divergence.rsi-divergence-bear > 0
;;   divergence-spread   — emit when either bull or bear > 0
;;
;; All three use scaled-linear. Non-emitting atoms leave Scales
;; untouched. Returned Holons vec has length 0, 1, 2, or 3.
;;
;; First conditional-emission vocab module; the file-private
;; `maybe-scaled-linear` helper below is the honest wat
;; translation of the archive's `facts.push(...)` guard. When a
;; second conditional-emission module ports (trade_atoms likely
;; next), the helper extracts to shared/helpers.wat.

(:wat::load-file! "../../types/candle.wat")
(:wat::load-file! "../../encoding/scaled-linear.wat")
(:wat::load-file! "../../encoding/round.wat")

;; ─── maybe-scaled-linear — file-private helper ───────────────────
;;
;; One conditional emission step. If should-emit? is true, run
;; scaled-linear and append the emitted holon; otherwise leave the
;; state unchanged.

(:wat::core::define
  (:trading::vocab::market::divergence::maybe-scaled-linear
    (should-emit? :wat::core::bool)
    (name :wat::core::String)
    (value :wat::core::f64)
    (holons :wat::holon::Holons)
    (scales :trading::encoding::Scales)
    -> :trading::encoding::VocabEmission)
  (:wat::core::if should-emit?
                   -> :trading::encoding::VocabEmission
    (:wat::core::let*
      (((emission :trading::encoding::ScaleEmission)
        (:trading::encoding::scaled-linear name value scales))
       ((fact :wat::holon::HolonAST)
        (:wat::core::first emission))
       ((next-scales :trading::encoding::Scales)
        (:wat::core::second emission))
       ((next-holons :wat::holon::Holons)
        (:wat::core::conj holons fact)))
      (:wat::core::tuple next-holons next-scales))
    (:wat::core::tuple holons scales)))

;; ─── encode-divergence-holons — the public entry ─────────────────

(:wat::core::define
  (:trading::vocab::market::divergence::encode-divergence-holons
    (d :trading::types::Candle::Divergence)
    (scales :trading::encoding::Scales)
    -> :trading::encoding::VocabEmission)
  (:wat::core::let*
    (((bull :wat::core::f64)
      (:trading::types::Candle::Divergence/rsi-divergence-bull d))
     ((bear :wat::core::f64)
      (:trading::types::Candle::Divergence/rsi-divergence-bear d))
     ((bull-ok?   :wat::core::bool) (:wat::core::> bull 0.0))
     ((bear-ok?   :wat::core::bool) (:wat::core::> bear 0.0))
     ;; spread-ok is OR — any non-zero divergence emits the spread atom
     ((spread-ok? :wat::core::bool) (:wat::core::or bull-ok? bear-ok?))

     ((bull-v :wat::core::f64)   (:trading::encoding::round-to-2 bull))
     ((bear-v :wat::core::f64)   (:trading::encoding::round-to-2 bear))
     ((spread-v :wat::core::f64) (:trading::encoding::round-to-2
                        (:wat::core::- bull bear)))

     ;; Thread (holons, scales) through three maybe-emit steps.
     ((start :trading::encoding::VocabEmission)
      (:wat::core::tuple
        (:wat::core::vec :wat::holon::HolonAST)
        scales))
     ((step-1 :trading::encoding::VocabEmission)
      (:trading::vocab::market::divergence::maybe-scaled-linear
        bull-ok? "rsi-divergence-bull" bull-v
        (:wat::core::first start) (:wat::core::second start)))
     ((step-2 :trading::encoding::VocabEmission)
      (:trading::vocab::market::divergence::maybe-scaled-linear
        bear-ok? "rsi-divergence-bear" bear-v
        (:wat::core::first step-1) (:wat::core::second step-1)))
     ((step-3 :trading::encoding::VocabEmission)
      (:trading::vocab::market::divergence::maybe-scaled-linear
        spread-ok? "divergence-spread" spread-v
        (:wat::core::first step-2) (:wat::core::second step-2))))
    step-3))
