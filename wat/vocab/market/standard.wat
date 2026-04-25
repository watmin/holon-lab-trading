;; wat/vocab/market/standard.wat — Phase 2.15 (lab arc 018).
;;
;; Port of archived/pre-wat-native/src/vocab/market/standard.rs
;; (166L). Eight atoms describing window-level market context:
;;
;;   since-rsi-extreme   — bars since last RSI > 80 or < 20
;;   since-vol-spike     — bars since last volume-accel > 2
;;   since-large-move    — bars since last |roc-1| > 0.02
;;   dist-from-high      — close vs window high
;;   dist-from-low       — close vs window low
;;   dist-from-midpoint  — close vs window midpoint
;;   dist-from-sma200    — close vs current sma200
;;   session-depth       — log of window length
;;
;; FIRST WINDOW-BASED VOCAB. Departs from arc 008's K-sub-struct
;; signature rule by necessity — window aggregates and
;; find-last-index iteration need full Candle access across
;; multiple candles. Single-candle vocabs continue to use sub-
;; struct slice signatures; window vocabs take Vec<Candle>.
;;
;; LAST MARKET SUB-TREE VOCAB. With arc 018 shipped, the market/
;; tree's 13 vocabs are complete (oscillators, divergence,
;; fibonacci, persistence, stochastic, regime, timeframe,
;; momentum, flow, ichimoku, keltner, price-action, standard).
;;
;; Consumes the FULL arc 047 primitive set (first lab consumer
;; of all four):
;;   :wat::core::last              — current = (last window)
;;   :wat::core::find-last-index   — three since-X computations
;;   :wat::core::f64::max-of       — window-high aggregate
;;   :wat::core::f64::min-of       — window-low aggregate
;; Plus arc 046's f64::max for the since-X floor pattern.
;;
;; Plain-Log atoms use the count-starting-at-1 family with bounds
;; (1.0, 100.0). Lab arc 017 introduced the family with bounds
;; (1.0, 20.0); arc 018 extends to 100 to cover typical observer
;; window sizes.

(:wat::load-file! "../../types/candle.wat")
(:wat::load-file! "../../types/ohlcv.wat")
(:wat::load-file! "../../encoding/round.wat")
(:wat::load-file! "../../encoding/scale-tracker.wat")
(:wat::load-file! "../../encoding/scaled-linear.wat")

(:wat::core::define
  (:trading::vocab::market::standard::encode-standard-holons
    (window :Vec<trading::types::Candle>)
    (scales :trading::encoding::Scales)
    -> :trading::encoding::VocabEmission)
  (:wat::core::if (:wat::core::empty? window) -> :trading::encoding::VocabEmission
    ;; Empty window — emit zero holons, scales unchanged.
    (:wat::core::tuple
      (:wat::core::vec :wat::holon::HolonAST)
      scales)
    ;; Non-empty branch.
    (:wat::core::let*
      (((n :i64) (:wat::core::length window))
       ((n-f64 :f64) (:wat::core::i64::to-f64 n))

       ;; Current candle (last in window) — for price/sma200 reads.
       ;; (last window) returns Some(c) since we just checked
       ;; non-empty; the :None arm is unreachable but type-required.
       ;; Sentinel: re-call (first window) which also returns Some
       ;; (window is non-empty by guard). Doubly-unreachable :None
       ;; arm builds a default Candle so the type checker is happy.
       ((current :trading::types::Candle)
        (:wat::core::match (:wat::core::last window)
                           -> :trading::types::Candle
          ((Some c) c)
          (:None
            (:wat::core::match (:wat::core::first window)
                               -> :trading::types::Candle
              ((Some c) c)
              (:None
                ;; Doubly unreachable. Build a default Candle from
                ;; defaults so the type system has a value.
                (:wat::core::let*
                  (((btc :trading::types::Asset)
                    (:trading::types::Asset/new "")))
                  (:trading::types::Candle/new
                    (:trading::types::Ohlcv/new btc btc "" 0.0 0.0 0.0 0.0 0.0)
                    (:trading::types::Candle::Trend/new 0.0 0.0 0.0 0.0 0.0 0.0 0.0)
                    (:trading::types::Candle::Volatility/new 0.0 0.0 0.0 0.0 0.0 0.0 0.0)
                    (:trading::types::Candle::Momentum/new 0.0 0.0 0.0 0.0 0.0 0.0 0.0 0.0 0.0 0.0 0.0 0.0)
                    (:trading::types::Candle::Divergence/new 0.0 0.0 0.0 0.0)
                    (:trading::types::Candle::RateOfChange/new 0.0 0.0 0.0 0.0 0.0 0.0 0.0)
                    (:trading::types::Candle::Persistence/new 0.0 0.0 0.0)
                    (:trading::types::Candle::Regime/new 0.0 0.0 0.0 0.0 0.0 0.0 0.0 0.0)
                    (:trading::types::Candle::PriceAction/new 0.0 0.0 0.0 0.0)
                    (:trading::types::Candle::Timeframe/new 0.0 0.0 0.0 0.0 0.0)
                    (:trading::types::Candle::Time/new 0.0 0.0 0.0 0.0 0.0)
                    (:trading::types::Candle::Phase/new
                      :trading::types::PhaseLabel::Transition
                      :trading::types::PhaseDirection::None
                      0
                      (:wat::core::vec :trading::types::PhaseRecord)))))))))
       ((price :f64) (:trading::types::Ohlcv/close (:trading::types::Candle/ohlcv current)))
       ((sma200 :f64)
        (:trading::types::Candle::Trend/sma200 (:trading::types::Candle/trend current)))

       ;; Window aggregates — max(high), min(low) over the window.
       ;; (max-of / min-of) return Option<f64>; non-empty so Some
       ;; is the live arm.
       ((highs :Vec<f64>)
        (:wat::core::map window
          (:wat::core::lambda ((c :trading::types::Candle) -> :f64)
            (:trading::types::Ohlcv/high (:trading::types::Candle/ohlcv c)))))
       ((lows :Vec<f64>)
        (:wat::core::map window
          (:wat::core::lambda ((c :trading::types::Candle) -> :f64)
            (:trading::types::Ohlcv/low (:trading::types::Candle/ohlcv c)))))
       ((window-high :f64)
        (:wat::core::match (:wat::core::f64::max-of highs) -> :f64
          ((Some v) v)
          (:None 0.0)))
       ((window-low :f64)
        (:wat::core::match (:wat::core::f64::min-of lows) -> :f64
          ((Some v) v)
          (:None 0.0)))
       ((window-mid :f64)
        (:wat::core::f64::/
          (:wat::core::f64::+ window-high window-low) 2.0))

       ;; Find-last-index for three event-counter atoms. None means
       ;; the window had no matching event; archive returns n
       ;; (entire window since last event).
       ((last-rsi-idx :Option<i64>)
        (:wat::core::find-last-index window
          (:wat::core::lambda ((c :trading::types::Candle) -> :bool)
            (:wat::core::let*
              (((rsi :f64)
                (:trading::types::Candle::Momentum/rsi
                  (:trading::types::Candle/momentum c))))
              (:wat::core::or
                (:wat::core::> rsi 80.0)
                (:wat::core::< rsi 20.0))))))
       ((since-rsi :i64)
        (:wat::core::match last-rsi-idx -> :i64
          ((Some i) (:wat::core::i64::- n i))
          (:None n)))
       ((since-rsi-extreme :f64)
        (:trading::encoding::round-to-2
          (:wat::core::f64::max
            (:wat::core::i64::to-f64 since-rsi) 1.0)))

       ((last-vol-idx :Option<i64>)
        (:wat::core::find-last-index window
          (:wat::core::lambda ((c :trading::types::Candle) -> :bool)
            (:wat::core::let*
              (((vol :f64)
                (:trading::types::Candle::Momentum/volume-accel
                  (:trading::types::Candle/momentum c))))
              (:wat::core::> vol 2.0)))))
       ((since-vol :i64)
        (:wat::core::match last-vol-idx -> :i64
          ((Some i) (:wat::core::i64::- n i))
          (:None n)))
       ((since-vol-spike :f64)
        (:trading::encoding::round-to-2
          (:wat::core::f64::max
            (:wat::core::i64::to-f64 since-vol) 1.0)))

       ((last-large-idx :Option<i64>)
        (:wat::core::find-last-index window
          (:wat::core::lambda ((c :trading::types::Candle) -> :bool)
            (:wat::core::let*
              (((roc-1 :f64)
                (:trading::types::Candle::RateOfChange/roc-1
                  (:trading::types::Candle/roc c))))
              (:wat::core::> (:wat::core::f64::abs roc-1) 0.02)))))
       ((since-large :i64)
        (:wat::core::match last-large-idx -> :i64
          ((Some i) (:wat::core::i64::- n i))
          (:None n)))
       ((since-large-move :f64)
        (:trading::encoding::round-to-2
          (:wat::core::f64::max
            (:wat::core::i64::to-f64 since-large) 1.0)))

       ;; Distance atoms — (price - X) / price, round-to-4.
       ((dist-from-high :f64)
        (:trading::encoding::round-to-4
          (:wat::core::f64::/
            (:wat::core::f64::- price window-high) price)))
       ((dist-from-low :f64)
        (:trading::encoding::round-to-4
          (:wat::core::f64::/
            (:wat::core::f64::- price window-low) price)))
       ((dist-from-midpoint :f64)
        (:trading::encoding::round-to-4
          (:wat::core::f64::/
            (:wat::core::f64::- price window-mid) price)))
       ((dist-from-sma200 :f64)
        (:trading::encoding::round-to-4
          (:wat::core::f64::/
            (:wat::core::f64::- price sma200) price)))

       ;; session-depth — (1 + n).max(1.0), round-to-2, count family Log.
       ((session-depth :f64)
        (:trading::encoding::round-to-2
          (:wat::core::f64::max
            (:wat::core::f64::+ 1.0 n-f64) 1.0)))

       ;; ─── Encode 8 atoms in archive order. ────────────────────

       ;; Three since-X via plain Log (count family bounds).
       ((h1 :wat::holon::HolonAST)
        (:wat::holon::Bind
          (:wat::holon::Atom "since-rsi-extreme")
          (:wat::holon::Log since-rsi-extreme 1.0 100.0)))
       ((h2 :wat::holon::HolonAST)
        (:wat::holon::Bind
          (:wat::holon::Atom "since-vol-spike")
          (:wat::holon::Log since-vol-spike 1.0 100.0)))
       ((h3 :wat::holon::HolonAST)
        (:wat::holon::Bind
          (:wat::holon::Atom "since-large-move")
          (:wat::holon::Log since-large-move 1.0 100.0)))

       ;; Four distance atoms via scaled-linear, threading scales.
       ((e4 :trading::encoding::ScaleEmission)
        (:trading::encoding::scaled-linear "dist-from-high" dist-from-high scales))
       ((h4 :wat::holon::HolonAST) (:wat::core::first e4))
       ((s4 :trading::encoding::Scales) (:wat::core::second e4))

       ((e5 :trading::encoding::ScaleEmission)
        (:trading::encoding::scaled-linear "dist-from-low" dist-from-low s4))
       ((h5 :wat::holon::HolonAST) (:wat::core::first e5))
       ((s5 :trading::encoding::Scales) (:wat::core::second e5))

       ((e6 :trading::encoding::ScaleEmission)
        (:trading::encoding::scaled-linear "dist-from-midpoint" dist-from-midpoint s5))
       ((h6 :wat::holon::HolonAST) (:wat::core::first e6))
       ((s6 :trading::encoding::Scales) (:wat::core::second e6))

       ((e7 :trading::encoding::ScaleEmission)
        (:trading::encoding::scaled-linear "dist-from-sma200" dist-from-sma200 s6))
       ((h7 :wat::holon::HolonAST) (:wat::core::first e7))
       ((s7 :trading::encoding::Scales) (:wat::core::second e7))

       ;; session-depth via plain Log (count family).
       ((h8 :wat::holon::HolonAST)
        (:wat::holon::Bind
          (:wat::holon::Atom "session-depth")
          (:wat::holon::Log session-depth 1.0 100.0)))

       ;; Assemble the Holons vec.
       ((holons :wat::holon::Holons)
        (:wat::core::vec :wat::holon::HolonAST h1 h2 h3 h4 h5 h6 h7 h8)))
      (:wat::core::tuple holons s7))))
