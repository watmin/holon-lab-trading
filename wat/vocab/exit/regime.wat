;; wat/vocab/exit/regime.wat — Phase 2.18 (lab arc 021).
;;
;; Port of archived/pre-wat-native/src/vocab/exit/regime.rs (84L).
;; Functionally identical to market/regime (arc 010): same 8 atoms
;; (kama-er, choppiness, dfa-alpha, variance-ratio with ReciprocalLog
;; 10.0, entropy-rate, aroon-up, aroon-down, fractal-dim), same
;; encoding, same one-sided floor, same Scales threading. Only the
;; namespace differs.
;;
;; Honest wat translation: thin delegation, not a copy. The archive
;; duplicates the function body so the Rust dispatcher can route by
;; name; wat preserves the same distinction via the namespaced path
;; (`:trading::vocab::exit::regime::*` vs `:trading::vocab::market::regime::*`)
;; without needing two implementations of identical logic.
;;
;; Future divergence (different floor, different bounds, exit-only
;; atoms) replaces the body at that point. Until then, two names for
;; the same function suffice — namespace-as-name is the wat shape.

(:wat::load-file! "../../types/candle.wat")
(:wat::load-file! "../../encoding/scale-tracker.wat")
(:wat::load-file! "../market/regime.wat")

(:wat::core::define
  (:trading::vocab::exit::regime::encode-regime-holons
    (r :trading::types::Candle::Regime)
    (scales :trading::encoding::Scales)
    -> :trading::encoding::VocabEmission)
  (:trading::vocab::market::regime::encode-regime-holons r scales))
