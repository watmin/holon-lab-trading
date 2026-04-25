;; wat/vocab/market/price-action.wat — Phase 2.14 (lab arc 017).
;;
;; Port of archived/pre-wat-native/src/vocab/market/price_action.rs
;; (52L). Seven atoms describing candlestick anatomy, range, gaps:
;;
;;   range-ratio       — high-low range as fraction of price (Log)
;;   gap               — overnight gap size, clamped ±1
;;   consecutive-up    — count of consecutive bullish bars (Log)
;;   consecutive-down  — count of consecutive bearish bars (Log)
;;   body-ratio-pa     — body width / total range
;;   upper-wick        — upper-wick / total range
;;   lower-wick        — lower-wick / total range
;;
;; EIGHTH CROSS-SUB-STRUCT VOCAB. K=2 (Ohlcv + PriceAction).
;; Signature alphabetical-by-leaf per arc 011: O < P.
;;
;; **Biggest plain-Log surface yet — three Log atoms across two
;; domain shapes.**
;;
;;   range-ratio: fraction-of-price family — bounds (0.001, 0.5),
;;   round-to-4. Fourth caller after arc 013 atr-ratio + arc 015
;;   cloud-thickness + arc 016 bb-width.
;;
;;   consecutive-up / consecutive-down: NEW count-starting-at-1
;;   family — bounds (1.0, 20.0), round-to-2. Asymmetric, lower-
;;   bounded at 1.0 (no streak), upper saturating at 20 consecutive
;;   periods (~1.5h on 5m candles, rare and meaningful as a saturated
;;   endpoint).
;;
;; **First lab `:wat::core::f64::min` consumer.** lower-wick uses
;; `min(open, close) - low`. Substrate primitive shipped in wat-rs
;; arc 046; first call site here.
;;
;; Range-conditional pattern recurs from flow.wat (six callers
;; total now across two modules; defaults differ — flow uses
;; 0.5/0.5/0.0, this module uses 0.0/0.0/0.0). Stay inline; helper
;; extraction needs a third module with uniform defaults.

(:wat::load-file! "../../types/candle.wat")
(:wat::load-file! "../../types/ohlcv.wat")
(:wat::load-file! "../../encoding/round.wat")
(:wat::load-file! "../../encoding/scale-tracker.wat")
(:wat::load-file! "../../encoding/scaled-linear.wat")

(:wat::core::define
  (:trading::vocab::market::price-action::encode-price-action-holons
    (o :trading::types::Ohlcv)
    (p :trading::types::Candle::PriceAction)
    (scales :trading::encoding::Scales)
    -> :trading::encoding::VocabEmission)
  (:wat::core::let*
    ;; Pull raw values once.
    (((open :f64) (:trading::types::Ohlcv/open o))
     ((high :f64) (:trading::types::Ohlcv/high o))
     ((low :f64) (:trading::types::Ohlcv/low o))
     ((close :f64) (:trading::types::Ohlcv/close o))
     ((range-ratio-raw :f64)
      (:trading::types::Candle::PriceAction/range-ratio p))
     ((gap-raw :f64) (:trading::types::Candle::PriceAction/gap p))
     ((consecutive-up-raw :f64)
      (:trading::types::Candle::PriceAction/consecutive-up p))
     ((consecutive-down-raw :f64)
      (:trading::types::Candle::PriceAction/consecutive-down p))

     ;; range-ratio — fraction-of-price family. Floor 0.001, round-to-4.
     ((range-ratio :f64)
      (:trading::encoding::round-to-4
        (:wat::core::f64::max range-ratio-raw 0.001)))

     ;; gap — clamp (gap / 0.05) to ±1, round-to-4.
     ((gap :f64)
      (:trading::encoding::round-to-4
        (:wat::core::f64::clamp
          (:wat::core::f64::/ gap-raw 0.05)
          -1.0 1.0)))

     ;; consecutive-up / consecutive-down — count family. Floor at 1.0
     ;; (matches archive's `(1.0 + count).max(1.0)` pattern), round-to-2.
     ((consecutive-up :f64)
      (:trading::encoding::round-to-2
        (:wat::core::f64::max
          (:wat::core::f64::+ 1.0 consecutive-up-raw) 1.0)))
     ((consecutive-down :f64)
      (:trading::encoding::round-to-2
        (:wat::core::f64::max
          (:wat::core::f64::+ 1.0 consecutive-down-raw) 1.0)))

     ;; Range-conditional setup (matches flow.wat's pattern, default 0.0).
     ((range :f64) (:wat::core::f64::- high low))
     ((range-positive :bool) (:wat::core::> range 0.0))

     ;; body-ratio-pa: abs(close - open) / range else 0.0.
     ((abs-body :f64)
      (:wat::core::f64::abs (:wat::core::f64::- close open)))
     ((body-ratio-pa :f64)
      (:wat::core::if range-positive -> :f64
        (:trading::encoding::round-to-2
          (:wat::core::f64::/ abs-body range))
        0.0))

     ;; upper-wick: (high - max(open, close)) / range else 0.0.
     ;; First non-floor f64::max use (max of two free values).
     ((body-top :f64) (:wat::core::f64::max open close))
     ((upper-wick :f64)
      (:wat::core::if range-positive -> :f64
        (:trading::encoding::round-to-2
          (:wat::core::f64::/
            (:wat::core::f64::- high body-top) range))
        0.0))

     ;; lower-wick: (min(open, close) - low) / range else 0.0.
     ;; **First lab f64::min consumer.**
     ((body-bottom :f64) (:wat::core::f64::min open close))
     ((lower-wick :f64)
      (:wat::core::if range-positive -> :f64
        (:trading::encoding::round-to-2
          (:wat::core::f64::/
            (:wat::core::f64::- body-bottom low) range))
        0.0))

     ;; range-ratio via plain Log (fraction-of-price family).
     ((h1 :wat::holon::HolonAST)
      (:wat::holon::Bind
        (:wat::holon::Atom "range-ratio")
        (:wat::holon::Log range-ratio 0.001 0.5)))

     ;; Thread Scales through gap (only scaled-linear in archive's
     ;; first three positions).
     ((e2 :trading::encoding::ScaleEmission)
      (:trading::encoding::scaled-linear "gap" gap scales))
     ((h2 :wat::holon::HolonAST) (:wat::core::first e2))
     ((s2 :trading::encoding::Scales) (:wat::core::second e2))

     ;; consecutive-up via plain Log (count-starting-at-1 family).
     ((h3 :wat::holon::HolonAST)
      (:wat::holon::Bind
        (:wat::holon::Atom "consecutive-up")
        (:wat::holon::Log consecutive-up 1.0 20.0)))

     ;; consecutive-down — same shape.
     ((h4 :wat::holon::HolonAST)
      (:wat::holon::Bind
        (:wat::holon::Atom "consecutive-down")
        (:wat::holon::Log consecutive-down 1.0 20.0)))

     ;; body-ratio-pa, upper-wick, lower-wick — scaled-linear.
     ((e5 :trading::encoding::ScaleEmission)
      (:trading::encoding::scaled-linear "body-ratio-pa" body-ratio-pa s2))
     ((h5 :wat::holon::HolonAST) (:wat::core::first e5))
     ((s5 :trading::encoding::Scales) (:wat::core::second e5))

     ((e6 :trading::encoding::ScaleEmission)
      (:trading::encoding::scaled-linear "upper-wick" upper-wick s5))
     ((h6 :wat::holon::HolonAST) (:wat::core::first e6))
     ((s6 :trading::encoding::Scales) (:wat::core::second e6))

     ((e7 :trading::encoding::ScaleEmission)
      (:trading::encoding::scaled-linear "lower-wick" lower-wick s6))
     ((h7 :wat::holon::HolonAST) (:wat::core::first e7))
     ((s7 :trading::encoding::Scales) (:wat::core::second e7))

     ;; Assemble the Holons vec.
     ((holons :wat::holon::Holons)
      (:wat::core::vec :wat::holon::HolonAST h1 h2 h3 h4 h5 h6 h7)))
    (:wat::core::tuple holons s7)))
