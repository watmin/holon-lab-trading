;; wat-tests/vocab/market/momentum.wat — Lab arc 013.
;;
;; Seven tests for :trading::vocab::market::momentum. Fourth cross-
;; sub-struct module; **highest arity yet (K=4)**. First lab plain-
;; Log caller.


(:wat::test::make-deftest :deftest
  ((:wat::load-file! "wat/vocab/market/momentum.wat")
   (:wat::core::define
     (:test::fresh-ohlcv (c :f64) -> :trading::types::Ohlcv)
     (:wat::core::let*
       (((btc :trading::types::Asset)
         (:trading::types::Asset/new "BTC")))
       ;; 8-arg: source-asset, target-asset, ts, open, high, low,
       ;; close, volume. Only `close` matters for momentum tests.
       (:trading::types::Ohlcv/new
         btc btc "" 0.0 0.0 0.0 c 0.0)))
   (:wat::core::define
     (:test::fresh-trend (sma20 :f64) -> :trading::types::Candle::Trend)
     ;; 7-arg: sma20, sma50, sma200, tenkan-sen, kijun-sen,
     ;; cloud-top, cloud-bottom. Only sma20 matters here; the
     ;; sma50/200-driven tests construct directly.
     (:trading::types::Candle::Trend/new
       sma20 0.0 0.0 0.0 0.0 0.0 0.0))
   (:wat::core::define
     (:test::fresh-momentum
       (macd-hist :f64) (plus-di :f64) (minus-di :f64)
       -> :trading::types::Candle::Momentum)
     ;; 12-arg: rsi, macd-hist, plus-di, minus-di, adx, stoch-k,
     ;; stoch-d, williams-r, cci, mfi, obv-slope-12, volume-accel.
     (:trading::types::Candle::Momentum/new
       0.0 macd-hist plus-di minus-di 0.0 0.0 0.0 0.0 0.0 0.0 0.0 0.0))
   (:wat::core::define
     (:test::fresh-volatility
       (atr-ratio :f64)
       -> :trading::types::Candle::Volatility)
     ;; 7-arg: bb-width, bb-pos, kelt-upper, kelt-lower, kelt-pos,
     ;; squeeze, atr-ratio.
     (:trading::types::Candle::Volatility/new
       0.0 0.0 0.0 0.0 0.0 0.0 atr-ratio))
   (:wat::core::define
     (:test::empty-scales -> :trading::encoding::Scales)
     (:wat::core::HashMap :(String,trading::encoding::ScaleTracker)))))

;; ─── 1. count — 6 holons emitted ───────────────────────────────

(:deftest :trading::test::vocab::market::momentum::test-holons-count
  (:wat::core::let*
    (((m :trading::types::Candle::Momentum)
      (:test::fresh-momentum 1.0 25.0 20.0))
     ((o :trading::types::Ohlcv) (:test::fresh-ohlcv 100.0))
     ((t :trading::types::Candle::Trend) (:test::fresh-trend 95.0))
     ((v :trading::types::Candle::Volatility)
      (:test::fresh-volatility 0.02))
     ((e :trading::encoding::VocabEmission)
      (:trading::vocab::market::momentum::encode-momentum-holons
        m o t v (:test::empty-scales)))
     ((holons :wat::holon::Holons) (:wat::core::first e)))
    (:wat::test::assert-eq
      (:wat::core::length holons)
      6)))

;; ─── 2. close-sma20 shape — fact[0], cross-compute Ohlcv + Trend

(:deftest :trading::test::vocab::market::momentum::test-close-sma20-shape
  (:wat::core::let*
    (;; close=100, sma20=95 → (100-95)/100 = 0.05 → round-to-4 = 0.05
     ((m :trading::types::Candle::Momentum)
      (:test::fresh-momentum 0.0 0.0 0.0))
     ((o :trading::types::Ohlcv) (:test::fresh-ohlcv 100.0))
     ((t :trading::types::Candle::Trend) (:test::fresh-trend 95.0))
     ((v :trading::types::Candle::Volatility)
      (:test::fresh-volatility 0.02))
     ((e :trading::encoding::VocabEmission)
      (:trading::vocab::market::momentum::encode-momentum-holons
        m o t v (:test::empty-scales)))
     ((holons :wat::holon::Holons) (:wat::core::first e))
     ((actual :wat::holon::HolonAST)
      (:wat::core::match (:wat::core::get holons 0)
                         -> :wat::holon::HolonAST
        ((Some h) h)
        (:None (:wat::holon::Atom "unreachable"))))

     ;; Recompute symmetrically.
     ((expected-value :f64)
      (:trading::encoding::round-to-4
        (:wat::core::/
          (:wat::core::- 100.0 95.0) 100.0)))
     ((expected-tracker :trading::encoding::ScaleTracker)
      (:trading::encoding::ScaleTracker::update
        (:trading::encoding::ScaleTracker::fresh) expected-value))
     ((scale :f64)
      (:trading::encoding::ScaleTracker::scale expected-tracker))
     ((neg-scale :f64) (:wat::core::- 0.0 scale))
     ((expected :wat::holon::HolonAST)
      (:wat::holon::Bind
        (:wat::holon::Atom "close-sma20")
        (:wat::holon::Thermometer expected-value neg-scale scale))))
    (:wat::test::assert-eq
      (:wat::holon::coincident? actual expected)
      true)))

;; ─── 3. macd-hist shape — fact[3], cross-compute Momentum + Ohlcv

(:deftest :trading::test::vocab::market::momentum::test-macd-hist-shape
  (:wat::core::let*
    (;; macd-hist=0.5, close=100 → 0.5/100 = 0.005 → round-to-4 = 0.005
     ((m :trading::types::Candle::Momentum)
      (:test::fresh-momentum 0.5 25.0 20.0))
     ((o :trading::types::Ohlcv) (:test::fresh-ohlcv 100.0))
     ((t :trading::types::Candle::Trend) (:test::fresh-trend 95.0))
     ((v :trading::types::Candle::Volatility)
      (:test::fresh-volatility 0.02))
     ((e :trading::encoding::VocabEmission)
      (:trading::vocab::market::momentum::encode-momentum-holons
        m o t v (:test::empty-scales)))
     ((holons :wat::holon::Holons) (:wat::core::first e))
     ((actual :wat::holon::HolonAST)
      (:wat::core::match (:wat::core::get holons 3)
                         -> :wat::holon::HolonAST
        ((Some h) h)
        (:None (:wat::holon::Atom "unreachable"))))

     ((expected-value :f64)
      (:trading::encoding::round-to-4
        (:wat::core::/ 0.5 100.0)))
     ((expected-tracker :trading::encoding::ScaleTracker)
      (:trading::encoding::ScaleTracker::update
        (:trading::encoding::ScaleTracker::fresh) expected-value))
     ((scale :f64)
      (:trading::encoding::ScaleTracker::scale expected-tracker))
     ((neg-scale :f64) (:wat::core::- 0.0 scale))
     ((expected :wat::holon::HolonAST)
      (:wat::holon::Bind
        (:wat::holon::Atom "macd-hist")
        (:wat::holon::Thermometer expected-value neg-scale scale))))
    (:wat::test::assert-eq
      (:wat::holon::coincident? actual expected)
      true)))

;; ─── 4. di-spread shape — fact[4], single-sub-struct Momentum-only

(:deftest :trading::test::vocab::market::momentum::test-di-spread-shape
  (:wat::core::let*
    (;; plus-di=25, minus-di=20 → (25-20)/100 = 0.05 → round-to-2 = 0.05
     ((m :trading::types::Candle::Momentum)
      (:test::fresh-momentum 0.0 25.0 20.0))
     ((o :trading::types::Ohlcv) (:test::fresh-ohlcv 100.0))
     ((t :trading::types::Candle::Trend) (:test::fresh-trend 95.0))
     ((v :trading::types::Candle::Volatility)
      (:test::fresh-volatility 0.02))
     ((e :trading::encoding::VocabEmission)
      (:trading::vocab::market::momentum::encode-momentum-holons
        m o t v (:test::empty-scales)))
     ((holons :wat::holon::Holons) (:wat::core::first e))
     ((actual :wat::holon::HolonAST)
      (:wat::core::match (:wat::core::get holons 4)
                         -> :wat::holon::HolonAST
        ((Some h) h)
        (:None (:wat::holon::Atom "unreachable"))))

     ((expected-value :f64)
      (:trading::encoding::round-to-2
        (:wat::core::/
          (:wat::core::- 25.0 20.0) 100.0)))
     ((expected-tracker :trading::encoding::ScaleTracker)
      (:trading::encoding::ScaleTracker::update
        (:trading::encoding::ScaleTracker::fresh) expected-value))
     ((scale :f64)
      (:trading::encoding::ScaleTracker::scale expected-tracker))
     ((neg-scale :f64) (:wat::core::- 0.0 scale))
     ((expected :wat::holon::HolonAST)
      (:wat::holon::Bind
        (:wat::holon::Atom "di-spread")
        (:wat::holon::Thermometer expected-value neg-scale scale))))
    (:wat::test::assert-eq
      (:wat::holon::coincident? actual expected)
      true)))

;; ─── 5. atr-ratio plain-Log shape — fact[5], first lab Log caller

(:deftest :trading::test::vocab::market::momentum::test-atr-ratio-log-shape
  (:wat::core::let*
    (;; atr-ratio=0.02 (above floor 0.001) → round-to-4 = 0.02
     ;; Encoded via Log 0.02 0.001 0.5
     ((m :trading::types::Candle::Momentum)
      (:test::fresh-momentum 0.0 0.0 0.0))
     ((o :trading::types::Ohlcv) (:test::fresh-ohlcv 100.0))
     ((t :trading::types::Candle::Trend) (:test::fresh-trend 95.0))
     ((v :trading::types::Candle::Volatility)
      (:test::fresh-volatility 0.02))
     ((e :trading::encoding::VocabEmission)
      (:trading::vocab::market::momentum::encode-momentum-holons
        m o t v (:test::empty-scales)))
     ((holons :wat::holon::Holons) (:wat::core::first e))
     ((actual :wat::holon::HolonAST)
      (:wat::core::match (:wat::core::get holons 5)
                         -> :wat::holon::HolonAST
        ((Some h) h)
        (:None (:wat::holon::Atom "unreachable"))))

     ((rounded :f64) (:trading::encoding::round-to-4 0.02))
     ((expected :wat::holon::HolonAST)
      (:wat::holon::Bind
        (:wat::holon::Atom "atr-ratio")
        (:wat::holon::Log rounded 0.001 0.5))))
    (:wat::test::assert-eq
      (:wat::holon::coincident? actual expected)
      true)))

;; ─── 6. atr-ratio floor — input below 0.001 lifts to 0.001 ──────

(:deftest :trading::test::vocab::market::momentum::test-atr-ratio-floor
  (:wat::core::let*
    (;; atr-ratio=0.0 → floored to 0.001 → round-to-4 = 0.001
     ((m :trading::types::Candle::Momentum)
      (:test::fresh-momentum 0.0 0.0 0.0))
     ((o :trading::types::Ohlcv) (:test::fresh-ohlcv 100.0))
     ((t :trading::types::Candle::Trend) (:test::fresh-trend 95.0))
     ((v :trading::types::Candle::Volatility)
      (:test::fresh-volatility 0.0))
     ((e :trading::encoding::VocabEmission)
      (:trading::vocab::market::momentum::encode-momentum-holons
        m o t v (:test::empty-scales)))
     ((holons :wat::holon::Holons) (:wat::core::first e))
     ((actual :wat::holon::HolonAST)
      (:wat::core::match (:wat::core::get holons 5)
                         -> :wat::holon::HolonAST
        ((Some h) h)
        (:None (:wat::holon::Atom "unreachable"))))

     ((expected :wat::holon::HolonAST)
      (:wat::holon::Bind
        (:wat::holon::Atom "atr-ratio")
        (:wat::holon::Log 0.001 0.001 0.5))))
    (:wat::test::assert-eq
      (:wat::holon::coincident? actual expected)
      true)))

;; ─── 7. scales accumulate 5 entries (atr-ratio is plain Log, no scales)

(:deftest :trading::test::vocab::market::momentum::test-scales-accumulate-5-entries
  (:wat::core::let*
    (((m :trading::types::Candle::Momentum)
      (:test::fresh-momentum 0.5 25.0 20.0))
     ((o :trading::types::Ohlcv) (:test::fresh-ohlcv 100.0))
     ((t :trading::types::Candle::Trend) (:test::fresh-trend 95.0))
     ((v :trading::types::Candle::Volatility)
      (:test::fresh-volatility 0.02))
     ((e :trading::encoding::VocabEmission)
      (:trading::vocab::market::momentum::encode-momentum-holons
        m o t v (:test::empty-scales)))
     ((updated :trading::encoding::Scales) (:wat::core::second e)))
    (:wat::test::assert-eq
      (:wat::core::length updated)
      5)))

;; ─── 8. different candles differ — close-sma20 across scale boundary

(:deftest :trading::test::vocab::market::momentum::test-different-candles-differ
  (:wat::core::let*
    ;; close-sma20: candle-a small (close=100, sma20=99 → 0.01), candle-b
    ;; large (close=100, sma20=50 → 0.50). Arc 008's scale-collision
    ;; footnote — values across the ScaleTracker round-to-2 boundary.
    ;; First-call scale: 0.01 → 0.00 (degenerate); 0.50 → 0.01 — distinct
    ;; Thermometer geometries.
    (((m :trading::types::Candle::Momentum)
      (:test::fresh-momentum 0.0 0.0 0.0))
     ((o-a :trading::types::Ohlcv) (:test::fresh-ohlcv 100.0))
     ((t-a :trading::types::Candle::Trend) (:test::fresh-trend 99.0))
     ((v :trading::types::Candle::Volatility)
      (:test::fresh-volatility 0.02))
     ((o-b :trading::types::Ohlcv) (:test::fresh-ohlcv 100.0))
     ((t-b :trading::types::Candle::Trend) (:test::fresh-trend 50.0))
     ((e-a :trading::encoding::VocabEmission)
      (:trading::vocab::market::momentum::encode-momentum-holons
        m o-a t-a v (:test::empty-scales)))
     ((e-b :trading::encoding::VocabEmission)
      (:trading::vocab::market::momentum::encode-momentum-holons
        m o-b t-b v (:test::empty-scales)))
     ((holons-a :wat::holon::Holons) (:wat::core::first e-a))
     ((holons-b :wat::holon::Holons) (:wat::core::first e-b))
     ((fact-a :wat::holon::HolonAST)
      (:wat::core::match (:wat::core::get holons-a 0)
                         -> :wat::holon::HolonAST
        ((Some h) h)
        (:None (:wat::holon::Atom "unreachable"))))
     ((fact-b :wat::holon::HolonAST)
      (:wat::core::match (:wat::core::get holons-b 0)
                         -> :wat::holon::HolonAST
        ((Some h) h)
        (:None (:wat::holon::Atom "unreachable")))))
    (:wat::test::assert-eq
      (:wat::holon::coincident? fact-a fact-b)
      false)))
