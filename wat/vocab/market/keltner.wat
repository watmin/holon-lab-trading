;; wat/vocab/market/keltner.wat — Phase 2.13 (lab arc 016).
;;
;; Port of archived/pre-wat-native/src/vocab/market/keltner.rs
;; (45L). Six atoms describing Bollinger / Keltner channel
;; positions and squeeze:
;;
;;   bb-pos          — Bollinger band position
;;   bb-width        — Bollinger width as fraction of price (Log)
;;   kelt-pos        — Keltner channel position
;;   squeeze         — TTM squeeze indicator
;;   kelt-upper-dist — close vs Keltner upper band
;;   kelt-lower-dist — close vs Keltner lower band
;;
;; SEVENTH CROSS-SUB-STRUCT VOCAB. K=2 (Ohlcv + Volatility).
;; Signature alphabetical-by-leaf per arc 011: O < V.
;;
;; Third plain `:wat::holon::Log` caller (after arc 013 atr-ratio,
;; arc 015 cloud-thickness). bb-width is asymmetric (always > 0,
;; fraction-of-price-style) — same domain shape as the prior two,
;; same bounds (0.001, 0.5), same round-to-4 substrate-discipline
;; correction over archive's round-to-2.
;;
;; First post-arc-046 pure substrate-direct vocab arc. bb-width
;; floor uses substrate `:wat::core::f64::max` directly; no
;; shared/helpers.wat load (no clamp/abs in this module).

(:wat::load-file! "../../types/candle.wat")
(:wat::load-file! "../../types/ohlcv.wat")
(:wat::load-file! "../../encoding/round.wat")
(:wat::load-file! "../../encoding/scale-tracker.wat")
(:wat::load-file! "../../encoding/scaled-linear.wat")

(:wat::core::define
  (:trading::vocab::market::keltner::encode-keltner-holons
    (o :trading::types::Ohlcv)
    (v :trading::types::Candle::Volatility)
    (scales :trading::encoding::Scales)
    -> :trading::encoding::VocabEmission)
  (:wat::core::let*
    ;; Pull raw values once.
    (((close :f64) (:trading::types::Ohlcv/close o))
     ((bb-pos-raw :f64) (:trading::types::Candle::Volatility/bb-pos v))
     ((bb-width-raw :f64) (:trading::types::Candle::Volatility/bb-width v))
     ((kelt-pos-raw :f64) (:trading::types::Candle::Volatility/kelt-pos v))
     ((kelt-upper :f64) (:trading::types::Candle::Volatility/kelt-upper v))
     ((kelt-lower :f64) (:trading::types::Candle::Volatility/kelt-lower v))
     ((squeeze-raw :f64) (:trading::types::Candle::Volatility/squeeze v))

     ;; Pure-Volatility atoms — round-to-2 → scaled-linear.
     ((bb-pos :f64) (:trading::encoding::round-to-2 bb-pos-raw))
     ((kelt-pos :f64) (:trading::encoding::round-to-2 kelt-pos-raw))
     ((squeeze :f64) (:trading::encoding::round-to-2 squeeze-raw))

     ;; bb-width — floor 0.001, round-to-4, plain Log.
     ((bb-width :f64)
      (:trading::encoding::round-to-4
        (:wat::core::f64::max bb-width-raw 0.001)))

     ;; Cross-sub-struct compute atoms — (close - kelt-band) / close.
     ((kelt-upper-dist :f64)
      (:trading::encoding::round-to-4
        (:wat::core::f64::/
          (:wat::core::f64::- close kelt-upper) close)))
     ((kelt-lower-dist :f64)
      (:trading::encoding::round-to-4
        (:wat::core::f64::/
          (:wat::core::f64::- close kelt-lower) close)))

     ;; Thread Scales through five scaled-linear calls. bb-width
     ;; (fact[1]) uses plain Log — no Scales.
     ((e1 :trading::encoding::ScaleEmission)
      (:trading::encoding::scaled-linear "bb-pos" bb-pos scales))
     ((h1 :wat::holon::HolonAST) (:wat::core::first e1))
     ((s1 :trading::encoding::Scales) (:wat::core::second e1))

     ;; bb-width via plain Log — Bind directly.
     ((h2 :wat::holon::HolonAST)
      (:wat::holon::Bind
        (:wat::holon::Atom "bb-width")
        (:wat::holon::Log bb-width 0.001 0.5)))

     ((e3 :trading::encoding::ScaleEmission)
      (:trading::encoding::scaled-linear "kelt-pos" kelt-pos s1))
     ((h3 :wat::holon::HolonAST) (:wat::core::first e3))
     ((s3 :trading::encoding::Scales) (:wat::core::second e3))

     ((e4 :trading::encoding::ScaleEmission)
      (:trading::encoding::scaled-linear "squeeze" squeeze s3))
     ((h4 :wat::holon::HolonAST) (:wat::core::first e4))
     ((s4 :trading::encoding::Scales) (:wat::core::second e4))

     ((e5 :trading::encoding::ScaleEmission)
      (:trading::encoding::scaled-linear "kelt-upper-dist" kelt-upper-dist s4))
     ((h5 :wat::holon::HolonAST) (:wat::core::first e5))
     ((s5 :trading::encoding::Scales) (:wat::core::second e5))

     ((e6 :trading::encoding::ScaleEmission)
      (:trading::encoding::scaled-linear "kelt-lower-dist" kelt-lower-dist s5))
     ((h6 :wat::holon::HolonAST) (:wat::core::first e6))
     ((s6 :trading::encoding::Scales) (:wat::core::second e6))

     ;; Assemble the Holons vec.
     ((holons :wat::holon::Holons)
      (:wat::core::vec :wat::holon::HolonAST h1 h2 h3 h4 h5 h6)))
    (:wat::core::tuple holons s6)))
