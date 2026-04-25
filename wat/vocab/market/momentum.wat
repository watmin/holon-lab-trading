;; wat/vocab/market/momentum.wat — Phase 2.10 (lab arc 013).
;;
;; Port of archived/pre-wat-native/src/vocab/market/momentum.rs
;; (44L). Six atoms describing trend-relative position, MACD, DI,
;; and volatility:
;;
;;   close-sma20    — close vs 20-bar SMA, normalized
;;   close-sma50    — close vs 50-bar SMA, normalized
;;   close-sma200   — close vs 200-bar SMA, normalized
;;   macd-hist      — MACD histogram normalized by close
;;   di-spread      — DMI plus/minus divergence
;;   atr-ratio      — ATR as fraction of price
;;
;; FOURTH CROSS-SUB-STRUCT VOCAB. **Highest arity yet (K=4 sub-
;; structs.)** Signature alphabetical by leaf name (arc 011
;; clarification): M < O < T < V → Momentum, Ohlcv, Trend, Volatility.
;; Scales last.
;;
;; **First lab plain :wat::holon::Log caller.** atr-ratio is
;; asymmetric (always < 1 in practice; volatility-as-fraction-of-
;; price). ReciprocalLog (arcs 005, 010) forces symmetric (1/N, N)
;; bounds; plain Log lets the encoding match the asymmetric domain
;; — full Thermometer range used, not half. Bounds (0.001, 0.5):
;; lower matches archive's `.max(0.001)` floor; upper is generous
;; for crypto 5m candles. See DESIGN for the trade-off table.
;;
;; round-to-4 for atr-ratio (not archive's round-to-2): substrate-
;; discipline correction. wat-rs's plain Log requires positive
;; inputs; round-to-2 would collapse 0.001 → 0.00 → ln(0) = -inf.
;; round-to-4 preserves the floor exactly.
;;
;; Cross-sub-struct compute pattern recurrence (named in arc 011):
;; close-sma20/50/200 + macd-hist all compute "field-divided-by-
;; close" across two sub-structs. Helper extraction deferred per
;; stdlib-as-blueprint — six let-bindings of the same shape are
;; locally honest as repetition.

(:wat::load-file! "../../types/candle.wat")
(:wat::load-file! "../../types/ohlcv.wat")
(:wat::load-file! "../../encoding/round.wat")
(:wat::load-file! "../../encoding/scale-tracker.wat")
(:wat::load-file! "../../encoding/scaled-linear.wat")

(:wat::core::define
  (:trading::vocab::market::momentum::encode-momentum-holons
    (m :trading::types::Candle::Momentum)
    (o :trading::types::Ohlcv)
    (t :trading::types::Candle::Trend)
    (v :trading::types::Candle::Volatility)
    (scales :trading::encoding::Scales)
    -> :trading::encoding::VocabEmission)
  (:wat::core::let*
    ;; Pull raw values once.
    (((close :f64) (:trading::types::Ohlcv/close o))
     ((sma20 :f64) (:trading::types::Candle::Trend/sma20 t))
     ((sma50 :f64) (:trading::types::Candle::Trend/sma50 t))
     ((sma200 :f64) (:trading::types::Candle::Trend/sma200 t))
     ((macd-hist-raw :f64)
      (:trading::types::Candle::Momentum/macd-hist m))
     ((plus-di :f64) (:trading::types::Candle::Momentum/plus-di m))
     ((minus-di :f64) (:trading::types::Candle::Momentum/minus-di m))
     ((atr-ratio-raw :f64)
      (:trading::types::Candle::Volatility/atr-ratio v))

     ;; Cross-sub-struct compute atoms — (close - sma) / close.
     ((close-sma20 :f64)
      (:trading::encoding::round-to-4
        (:wat::core::/
          (:wat::core::- close sma20) close)))
     ((close-sma50 :f64)
      (:trading::encoding::round-to-4
        (:wat::core::/
          (:wat::core::- close sma50) close)))
     ((close-sma200 :f64)
      (:trading::encoding::round-to-4
        (:wat::core::/
          (:wat::core::- close sma200) close)))

     ;; Cross-sub-struct compute — macd-hist / close.
     ((macd-hist :f64)
      (:trading::encoding::round-to-4
        (:wat::core::/ macd-hist-raw close)))

     ;; Single-sub-struct compute — DMI spread normalized to (-1, 1).
     ((di-spread :f64)
      (:trading::encoding::round-to-2
        (:wat::core::/
          (:wat::core::- plus-di minus-di) 100.0)))

     ;; atr-ratio: floor at 0.001 via substrate f64::max (wat-rs
     ;; arc 046), then round-to-4 (preserves the floor; round-to-2
     ;; would collapse to 0.00). Encoded via plain Log with
     ;; asymmetric bounds (0.001, 0.5).
     ((atr-ratio :f64)
      (:trading::encoding::round-to-4
        (:wat::core::f64::max atr-ratio-raw 0.001)))

     ;; Thread Scales through five scaled-linear calls. atr-ratio
     ;; (fact[5]) uses plain Log — no Scales involvement.
     ((e1 :trading::encoding::ScaleEmission)
      (:trading::encoding::scaled-linear "close-sma20" close-sma20 scales))
     ((h1 :wat::holon::HolonAST) (:wat::core::first e1))
     ((s1 :trading::encoding::Scales) (:wat::core::second e1))

     ((e2 :trading::encoding::ScaleEmission)
      (:trading::encoding::scaled-linear "close-sma50" close-sma50 s1))
     ((h2 :wat::holon::HolonAST) (:wat::core::first e2))
     ((s2 :trading::encoding::Scales) (:wat::core::second e2))

     ((e3 :trading::encoding::ScaleEmission)
      (:trading::encoding::scaled-linear "close-sma200" close-sma200 s2))
     ((h3 :wat::holon::HolonAST) (:wat::core::first e3))
     ((s3 :trading::encoding::Scales) (:wat::core::second e3))

     ((e4 :trading::encoding::ScaleEmission)
      (:trading::encoding::scaled-linear "macd-hist" macd-hist s3))
     ((h4 :wat::holon::HolonAST) (:wat::core::first e4))
     ((s4 :trading::encoding::Scales) (:wat::core::second e4))

     ((e5 :trading::encoding::ScaleEmission)
      (:trading::encoding::scaled-linear "di-spread" di-spread s4))
     ((h5 :wat::holon::HolonAST) (:wat::core::first e5))
     ((s5 :trading::encoding::Scales) (:wat::core::second e5))

     ;; atr-ratio via plain Log — Bind directly, no scales. First
     ;; lab plain-Log caller; bounds (0.001, 0.5) — lower matches
     ;; archive's floor; upper generous for crypto 5m.
     ((h6 :wat::holon::HolonAST)
      (:wat::holon::Bind
        (:wat::holon::Atom "atr-ratio")
        (:wat::holon::Log atr-ratio 0.001 0.5)))

     ;; Assemble the Holons vec.
     ((holons :wat::holon::Holons)
      (:wat::core::vec :wat::holon::HolonAST h1 h2 h3 h4 h5 h6)))
    (:wat::core::tuple holons s5)))
