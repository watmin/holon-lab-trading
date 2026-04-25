;; wat/vocab/market/ichimoku.wat — Phase 2.12 (lab arc 015).
;;
;; Port of archived/pre-wat-native/src/vocab/market/ichimoku.rs
;; (61L). Six atoms describing Ichimoku cloud structure + TK
;; relationships:
;;
;;   cloud-position    — close vs cloud-mid, normalized + clamped
;;   cloud-thickness   — cloud-width / close, log-encoded
;;   tk-cross-delta    — TK crossover signal, clamped
;;   tk-spread         — tenkan vs kijun, normalized + clamped
;;   tenkan-dist       — close vs tenkan, normalized + clamped
;;   kijun-dist        — close vs kijun, normalized + clamped
;;
;; SIXTH CROSS-SUB-STRUCT VOCAB. K=3 (Divergence + Ohlcv + Trend) —
;; second K=3 module after arc 014 flow. Signature alphabetical-by-
;; leaf per arc 011: D < O < T.
;;
;; **Triggered substrate uplift of `:wat::core::f64::clamp`** —
;; five clamp callers in this module + arc 009 stochastic's prior
;; inline made the case for substrate, not lab-userland. wat-rs
;; arc 046 ships `f64::max/min/abs/clamp` + `math::exp`; lab arc
;; 015 consumes them directly. Arc 009's inline was migrated to
;; `:wat::core::f64::clamp` in the same sweep.
;;
;; **Second plain-Log caller** (cloud-thickness). Arc 013 atr-ratio
;; established the asymmetric-domain Log pattern; cloud-thickness
;; cites it without re-deriving — bounds (0.0001, 0.5) match the
;; archive's floor and a generous upper. round-to-4 (not archive's
;; round-to-2) preserves the floor exactly.
;;
;; cloud-position is the most-computed atom: nested branch on
;; cloud-width > 0 (with an inner floor on the positive branch's
;; denominator) plus clamp ±1. Inline let* inside the if-branches
;; keeps the structure local to the call site.

(:wat::load-file! "../../types/candle.wat")
(:wat::load-file! "../../types/ohlcv.wat")
(:wat::load-file! "../../encoding/round.wat")
(:wat::load-file! "../../encoding/scale-tracker.wat")
(:wat::load-file! "../../encoding/scaled-linear.wat")

(:wat::core::define
  (:trading::vocab::market::ichimoku::encode-ichimoku-holons
    (d :trading::types::Candle::Divergence)
    (o :trading::types::Ohlcv)
    (t :trading::types::Candle::Trend)
    (scales :trading::encoding::Scales)
    -> :trading::encoding::VocabEmission)
  (:wat::core::let*
    ;; Pull raw values once.
    (((close :f64) (:trading::types::Ohlcv/close o))
     ((tenkan :f64) (:trading::types::Candle::Trend/tenkan-sen t))
     ((kijun :f64) (:trading::types::Candle::Trend/kijun-sen t))
     ((cloud-top :f64) (:trading::types::Candle::Trend/cloud-top t))
     ((cloud-bottom :f64) (:trading::types::Candle::Trend/cloud-bottom t))
     ((tk-cross-delta-raw :f64)
      (:trading::types::Candle::Divergence/tk-cross-delta d))

     ;; Cloud geometry — derived once, used by cloud-position +
     ;; cloud-thickness.
     ((cloud-mid :f64)
      (:wat::core::f64::/
        (:wat::core::f64::+ cloud-top cloud-bottom) 2.0))
     ((cloud-width :f64)
      (:wat::core::f64::- cloud-top cloud-bottom))

     ;; cloud-position — nested branch on cloud-width > 0.
     ;; Positive branch: scale by max(cloud-width, close * 0.001).
     ;; Collapsed branch: scale by close * 0.01.
     ;; Both branches clamped to ±1, then round-to-2.
     ((cloud-position-raw :f64)
      (:wat::core::if (:wat::core::> cloud-width 0.0) -> :f64
        (:wat::core::f64::/
          (:wat::core::f64::- close cloud-mid)
          (:wat::core::f64::max cloud-width
                                (:wat::core::f64::* close 0.001)))
        (:wat::core::f64::/
          (:wat::core::f64::- close cloud-mid)
          (:wat::core::f64::* close 0.01))))
     ((cloud-position :f64)
      (:trading::encoding::round-to-2
        (:wat::core::f64::clamp cloud-position-raw -1.0 1.0)))

     ;; cloud-thickness — floor at 0.0001 via substrate f64::max,
     ;; round-to-4, plain Log bounds (0.0001, 0.5).
     ((thickness-raw :f64)
      (:wat::core::f64::/ cloud-width close))
     ((cloud-thickness :f64)
      (:trading::encoding::round-to-4
        (:wat::core::f64::max thickness-raw 0.0001)))

     ;; tk-cross-delta — clamp ±1, round-to-2.
     ((tk-cross-delta :f64)
      (:trading::encoding::round-to-2
        (:wat::core::f64::clamp tk-cross-delta-raw -1.0 1.0)))

     ;; tk-spread, tenkan-dist, kijun-dist — same shape: numerator
     ;; / (close × 0.01), clamp ±1, round-to-2. denom shared.
     ((pct-denom :f64) (:wat::core::f64::* close 0.01))

     ((tk-spread :f64)
      (:trading::encoding::round-to-2
        (:wat::core::f64::clamp
          (:wat::core::f64::/
            (:wat::core::f64::- tenkan kijun) pct-denom)
          -1.0 1.0)))

     ((tenkan-dist :f64)
      (:trading::encoding::round-to-2
        (:wat::core::f64::clamp
          (:wat::core::f64::/
            (:wat::core::f64::- close tenkan) pct-denom)
          -1.0 1.0)))

     ((kijun-dist :f64)
      (:trading::encoding::round-to-2
        (:wat::core::f64::clamp
          (:wat::core::f64::/
            (:wat::core::f64::- close kijun) pct-denom)
          -1.0 1.0)))

     ;; Thread Scales through five scaled-linear calls.
     ;; cloud-thickness (fact[1]) uses plain Log — no Scales.
     ((e1 :trading::encoding::ScaleEmission)
      (:trading::encoding::scaled-linear "cloud-position" cloud-position scales))
     ((h1 :wat::holon::HolonAST) (:wat::core::first e1))
     ((s1 :trading::encoding::Scales) (:wat::core::second e1))

     ;; cloud-thickness via plain Log — Bind directly.
     ((h2 :wat::holon::HolonAST)
      (:wat::holon::Bind
        (:wat::holon::Atom "cloud-thickness")
        (:wat::holon::Log cloud-thickness 0.0001 0.5)))

     ((e3 :trading::encoding::ScaleEmission)
      (:trading::encoding::scaled-linear "tk-cross-delta" tk-cross-delta s1))
     ((h3 :wat::holon::HolonAST) (:wat::core::first e3))
     ((s3 :trading::encoding::Scales) (:wat::core::second e3))

     ((e4 :trading::encoding::ScaleEmission)
      (:trading::encoding::scaled-linear "tk-spread" tk-spread s3))
     ((h4 :wat::holon::HolonAST) (:wat::core::first e4))
     ((s4 :trading::encoding::Scales) (:wat::core::second e4))

     ((e5 :trading::encoding::ScaleEmission)
      (:trading::encoding::scaled-linear "tenkan-dist" tenkan-dist s4))
     ((h5 :wat::holon::HolonAST) (:wat::core::first e5))
     ((s5 :trading::encoding::Scales) (:wat::core::second e5))

     ((e6 :trading::encoding::ScaleEmission)
      (:trading::encoding::scaled-linear "kijun-dist" kijun-dist s5))
     ((h6 :wat::holon::HolonAST) (:wat::core::first e6))
     ((s6 :trading::encoding::Scales) (:wat::core::second e6))

     ;; Assemble the Holons vec.
     ((holons :wat::holon::Holons)
      (:wat::core::vec :wat::holon::HolonAST h1 h2 h3 h4 h5 h6)))
    (:wat::core::tuple holons s6)))
