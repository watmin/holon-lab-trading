;; wat/vocab/market/regime.wat — Phase 2.8 (lab arc 010).
;;
;; Port of archived/pre-wat-native/src/vocab/market/regime.rs (83L).
;; Eight atoms describing "what kind of market is this" — the regime
;; lens. Seven scaled-linear + one ReciprocalLog:
;;
;;   kama-er, choppiness, dfa-alpha, entropy-rate, aroon-up,
;;   aroon-down, fractal-dim        — scaled-linear
;;   variance-ratio                  — ReciprocalLog 10.0
;;
;; Single sub-struct (Candle::Regime); signature trivially satisfies
;; arc 008's cross-sub-struct rule (K=1 is the degenerate case).
;;
;; ReciprocalLog bound N=10 (0.1, 10) chosen via empirical observation
;; — `docs/arc/2026/04/010-market-regime-vocab/explore-log.wat` tabulates
;; cosine at N=2/3/10 for values 0.1-20. N=10 preserves the full
;; variance-ratio financial range (mean-reverting ≤ 0.5 through
;; trending ≥ 2.0) without saturating mid-range. Per-10% resolution
;; near 1.0 matches regime's "what kind of market" coarse-grain goal
;; (fine-grained noise should collapse; regime changes should stand
;; out). Contrast: arc 005's ROC atoms use N=2 for per-1% resolution
;; — same family, different domain.
;;
;; variance-ratio one-sided floor at 0.001 preserves archive's
;; defensive guard against raw zeros. Under 058-017's Thermometer-Log
;; the floor is operationally moot (any value ≤ 0.001 saturates the
;; same as 0.001, well below N=10's 0.1 lower bound) — kept anyway
;; as an input-hygiene marker.

(:wat::load-file! "../../types/candle.wat")
(:wat::load-file! "../../encoding/scale-tracker.wat")
(:wat::load-file! "../../encoding/scaled-linear.wat")

(:wat::core::define
  (:trading::vocab::market::regime::encode-regime-holons
    (r :trading::types::Candle::Regime)
    (scales :trading::encoding::Scales)
    -> :trading::encoding::VocabEmission)
  (:wat::core::let*
    ;; Normalize + round the eight atom values.
    (((kama-er :f64)
      (:trading::encoding::round-to-2
        (:trading::types::Candle::Regime/kama-er r)))
     ((choppiness :f64)
      (:trading::encoding::round-to-2
        (:wat::core::f64::/
          (:trading::types::Candle::Regime/choppiness r) 100.0)))
     ((dfa-alpha :f64)
      (:trading::encoding::round-to-2
        (:wat::core::f64::/
          (:trading::types::Candle::Regime/dfa-alpha r) 2.0)))

     ;; variance-ratio — one-sided floor at 0.001 via substrate
     ;; f64::max (wat-rs arc 046), then round.
     ((vr-raw :f64)
      (:trading::types::Candle::Regime/variance-ratio r))
     ((variance-ratio :f64)
      (:trading::encoding::round-to-2
        (:wat::core::f64::max vr-raw 0.001)))

     ((entropy-rate :f64)
      (:trading::encoding::round-to-2
        (:trading::types::Candle::Regime/entropy-rate r)))
     ((aroon-up :f64)
      (:trading::encoding::round-to-2
        (:wat::core::f64::/
          (:trading::types::Candle::Regime/aroon-up r) 100.0)))
     ((aroon-down :f64)
      (:trading::encoding::round-to-2
        (:wat::core::f64::/
          (:trading::types::Candle::Regime/aroon-down r) 100.0)))
     ((fractal-dim :f64)
      (:trading::encoding::round-to-2
        (:wat::core::f64::-
          (:trading::types::Candle::Regime/fractal-dim r) 1.0)))

     ;; Thread Scales through seven scaled-linear calls. variance-
     ;; ratio (fact[3]) uses ReciprocalLog — no Scales involvement.
     ((e1 :trading::encoding::ScaleEmission)
      (:trading::encoding::scaled-linear "kama-er" kama-er scales))
     ((h1 :wat::holon::HolonAST) (:wat::core::first e1))
     ((s1 :trading::encoding::Scales) (:wat::core::second e1))

     ((e2 :trading::encoding::ScaleEmission)
      (:trading::encoding::scaled-linear "choppiness" choppiness s1))
     ((h2 :wat::holon::HolonAST) (:wat::core::first e2))
     ((s2 :trading::encoding::Scales) (:wat::core::second e2))

     ((e3 :trading::encoding::ScaleEmission)
      (:trading::encoding::scaled-linear "dfa-alpha" dfa-alpha s2))
     ((h3 :wat::holon::HolonAST) (:wat::core::first e3))
     ((s3 :trading::encoding::Scales) (:wat::core::second e3))

     ;; variance-ratio via ReciprocalLog 10.0 — Bind directly, no
     ;; scales.
     ((h4 :wat::holon::HolonAST)
      (:wat::holon::Bind
        (:wat::holon::Atom "variance-ratio")
        (:wat::holon::ReciprocalLog 10.0 variance-ratio)))

     ((e5 :trading::encoding::ScaleEmission)
      (:trading::encoding::scaled-linear "entropy-rate" entropy-rate s3))
     ((h5 :wat::holon::HolonAST) (:wat::core::first e5))
     ((s5 :trading::encoding::Scales) (:wat::core::second e5))

     ((e6 :trading::encoding::ScaleEmission)
      (:trading::encoding::scaled-linear "aroon-up" aroon-up s5))
     ((h6 :wat::holon::HolonAST) (:wat::core::first e6))
     ((s6 :trading::encoding::Scales) (:wat::core::second e6))

     ((e7 :trading::encoding::ScaleEmission)
      (:trading::encoding::scaled-linear "aroon-down" aroon-down s6))
     ((h7 :wat::holon::HolonAST) (:wat::core::first e7))
     ((s7 :trading::encoding::Scales) (:wat::core::second e7))

     ((e8 :trading::encoding::ScaleEmission)
      (:trading::encoding::scaled-linear "fractal-dim" fractal-dim s7))
     ((h8 :wat::holon::HolonAST) (:wat::core::first e8))
     ((s8 :trading::encoding::Scales) (:wat::core::second e8))

     ;; Assemble the Holons vec.
     ((holons :wat::holon::Holons)
      (:wat::core::vec :wat::holon::HolonAST
        h1 h2 h3 h4 h5 h6 h7 h8)))
    (:wat::core::tuple holons s8)))
