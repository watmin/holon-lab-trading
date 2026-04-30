;; wat-tests/vocab/market/ichimoku.wat — Lab arc 015.
;;
;; Eight tests for :trading::vocab::market::ichimoku. Sixth cross-
;; sub-struct module; second K=3 (D + O + T). First module to
;; consume the substrate `:wat::core::f64::clamp` (wat-rs arc 046).
;; Second plain-Log caller (cloud-thickness; cites arc 013 atr-ratio
;; precedent).


(:wat::test::make-deftest :deftest
  ((:wat::load-file! "wat/vocab/market/ichimoku.wat")
   (:wat::core::define
     (:test::fresh-ohlcv (c :wat::core::f64) -> :trading::types::Ohlcv)
     (:wat::core::let*
       (((btc :trading::types::Asset)
         (:trading::types::Asset/new "BTC")))
       ;; 8-arg: source-asset, target-asset, ts, open, high, low,
       ;; close, volume. Only `close` matters here.
       (:trading::types::Ohlcv/new
         btc btc "" 0.0 0.0 0.0 c 0.0)))
   (:wat::core::define
     (:test::fresh-trend
       (tenkan :wat::core::f64) (kijun :wat::core::f64) (cloud-top :wat::core::f64) (cloud-bottom :wat::core::f64)
       -> :trading::types::Candle::Trend)
     ;; 7-arg: sma20, sma50, sma200, tenkan-sen, kijun-sen,
     ;; cloud-top, cloud-bottom.
     (:trading::types::Candle::Trend/new
       0.0 0.0 0.0 tenkan kijun cloud-top cloud-bottom))
   (:wat::core::define
     (:test::fresh-divergence
       (tk-cross-delta :wat::core::f64)
       -> :trading::types::Candle::Divergence)
     ;; 4-arg: rsi-divergence-bull, rsi-divergence-bear,
     ;; tk-cross-delta, stoch-cross-delta.
     (:trading::types::Candle::Divergence/new
       0.0 0.0 tk-cross-delta 0.0))
   (:wat::core::define
     (:test::empty-scales -> :trading::encoding::Scales)
     (:wat::core::HashMap :(String,trading::encoding::ScaleTracker)))))

;; ─── 1. count — 6 holons emitted ───────────────────────────────

(:deftest :trading::test::vocab::market::ichimoku::test-holons-count
  (:wat::core::let*
    (((d :trading::types::Candle::Divergence)
      (:test::fresh-divergence 0.5))
     ((o :trading::types::Ohlcv) (:test::fresh-ohlcv 100.0))
     ((t :trading::types::Candle::Trend)
      (:test::fresh-trend 99.0 98.0 101.0 97.0))
     ((e :trading::encoding::VocabEmission)
      (:trading::vocab::market::ichimoku::encode-ichimoku-holons
        d o t (:test::empty-scales)))
     ((holons :wat::holon::Holons) (:wat::core::first e)))
    (:wat::test::assert-eq
      (:wat::core::length holons)
      6)))

;; ─── 2. cloud-position above-saturated — clamp pushes to +1.0 ───

(:deftest :trading::test::vocab::market::ichimoku::test-cloud-position-saturated
  (:wat::core::let*
    (;; close=200, cloud_top=101, cloud_bottom=99 → cloud_mid=100,
     ;; cloud_width=2. (200-100)/max(2, 200*0.001=0.2) = 100/2 = 50
     ;; → clamp to 1.0 → round-to-2 = 1.0
     ((d :trading::types::Candle::Divergence)
      (:test::fresh-divergence 0.0))
     ((o :trading::types::Ohlcv) (:test::fresh-ohlcv 200.0))
     ((t :trading::types::Candle::Trend)
      (:test::fresh-trend 0.0 0.0 101.0 99.0))
     ((e :trading::encoding::VocabEmission)
      (:trading::vocab::market::ichimoku::encode-ichimoku-holons
        d o t (:test::empty-scales)))
     ((holons :wat::holon::Holons) (:wat::core::first e))
     ((actual :wat::holon::HolonAST)
      (:wat::core::match (:wat::core::get holons 0)
                         -> :wat::holon::HolonAST
        ((Some h) h)
        (:None (:wat::holon::Atom "unreachable"))))

     ((expected-tracker :trading::encoding::ScaleTracker)
      (:trading::encoding::ScaleTracker::update
        (:trading::encoding::ScaleTracker::fresh) 1.0))
     ((scale :wat::core::f64)
      (:trading::encoding::ScaleTracker::scale expected-tracker))
     ((neg-scale :wat::core::f64) (:wat::core::- 0.0 scale))
     ((expected :wat::holon::HolonAST)
      (:wat::holon::Bind
        (:wat::holon::Atom "cloud-position")
        (:wat::holon::Thermometer 1.0 neg-scale scale))))
    (:wat::test::assert-eq
      (:wat::holon::coincident? actual expected)
      true)))

;; ─── 3. cloud-position collapsed-cloud branch — cloud-width = 0 ─

(:deftest :trading::test::vocab::market::ichimoku::test-cloud-position-collapsed
  (:wat::core::let*
    (;; cloud_top = cloud_bottom = 100 → cloud_width = 0,
     ;; cloud_mid = 100. close = 102 → (102-100) / (102*0.01=1.02)
     ;; ≈ 1.96 → clamp to 1.0 → round-to-2 = 1.0
     ((d :trading::types::Candle::Divergence)
      (:test::fresh-divergence 0.0))
     ((o :trading::types::Ohlcv) (:test::fresh-ohlcv 102.0))
     ((t :trading::types::Candle::Trend)
      (:test::fresh-trend 0.0 0.0 100.0 100.0))
     ((e :trading::encoding::VocabEmission)
      (:trading::vocab::market::ichimoku::encode-ichimoku-holons
        d o t (:test::empty-scales)))
     ((holons :wat::holon::Holons) (:wat::core::first e))
     ((actual :wat::holon::HolonAST)
      (:wat::core::match (:wat::core::get holons 0)
                         -> :wat::holon::HolonAST
        ((Some h) h)
        (:None (:wat::holon::Atom "unreachable"))))

     ((expected-tracker :trading::encoding::ScaleTracker)
      (:trading::encoding::ScaleTracker::update
        (:trading::encoding::ScaleTracker::fresh) 1.0))
     ((scale :wat::core::f64)
      (:trading::encoding::ScaleTracker::scale expected-tracker))
     ((neg-scale :wat::core::f64) (:wat::core::- 0.0 scale))
     ((expected :wat::holon::HolonAST)
      (:wat::holon::Bind
        (:wat::holon::Atom "cloud-position")
        (:wat::holon::Thermometer 1.0 neg-scale scale))))
    (:wat::test::assert-eq
      (:wat::holon::coincident? actual expected)
      true)))

;; ─── 4. cloud-thickness plain-Log shape — fact[1] ────────────

(:deftest :trading::test::vocab::market::ichimoku::test-cloud-thickness-log-shape
  (:wat::core::let*
    (;; close=100, cloud_top=104, cloud_bottom=96 → cloud_width=8
     ;; → 8/100 = 0.08 → round-to-4 = 0.08 → Log 0.08 0.0001 0.5
     ((d :trading::types::Candle::Divergence)
      (:test::fresh-divergence 0.0))
     ((o :trading::types::Ohlcv) (:test::fresh-ohlcv 100.0))
     ((t :trading::types::Candle::Trend)
      (:test::fresh-trend 0.0 0.0 104.0 96.0))
     ((e :trading::encoding::VocabEmission)
      (:trading::vocab::market::ichimoku::encode-ichimoku-holons
        d o t (:test::empty-scales)))
     ((holons :wat::holon::Holons) (:wat::core::first e))
     ((actual :wat::holon::HolonAST)
      (:wat::core::match (:wat::core::get holons 1)
                         -> :wat::holon::HolonAST
        ((Some h) h)
        (:None (:wat::holon::Atom "unreachable"))))

     ((rounded :wat::core::f64) (:trading::encoding::round-to-4 0.08))
     ((expected :wat::holon::HolonAST)
      (:wat::holon::Bind
        (:wat::holon::Atom "cloud-thickness")
        (:wat::holon::Log rounded 0.0001 0.5))))
    (:wat::test::assert-eq
      (:wat::holon::coincident? actual expected)
      true)))

;; ─── 5. cloud-thickness floor — input 0 lifts to 0.0001 ────────

(:deftest :trading::test::vocab::market::ichimoku::test-cloud-thickness-floor
  (:wat::core::let*
    (;; cloud_top = cloud_bottom = 100 → cloud_width = 0 → 0/100 = 0
     ;; → floor to 0.0001 → round-to-4 = 0.0001 → Log 0.0001 0.0001 0.5
     ((d :trading::types::Candle::Divergence)
      (:test::fresh-divergence 0.0))
     ((o :trading::types::Ohlcv) (:test::fresh-ohlcv 100.0))
     ((t :trading::types::Candle::Trend)
      (:test::fresh-trend 0.0 0.0 100.0 100.0))
     ((e :trading::encoding::VocabEmission)
      (:trading::vocab::market::ichimoku::encode-ichimoku-holons
        d o t (:test::empty-scales)))
     ((holons :wat::holon::Holons) (:wat::core::first e))
     ((actual :wat::holon::HolonAST)
      (:wat::core::match (:wat::core::get holons 1)
                         -> :wat::holon::HolonAST
        ((Some h) h)
        (:None (:wat::holon::Atom "unreachable"))))

     ((expected :wat::holon::HolonAST)
      (:wat::holon::Bind
        (:wat::holon::Atom "cloud-thickness")
        (:wat::holon::Log 0.0001 0.0001 0.5))))
    (:wat::test::assert-eq
      (:wat::holon::coincident? actual expected)
      true)))

;; ─── 6. tk-spread shape — fact[3], cross-Ohlcv compute clamp ±1 ──

(:deftest :trading::test::vocab::market::ichimoku::test-tk-spread-shape
  (:wat::core::let*
    (;; close=100, tenkan=99.5, kijun=99 → (99.5-99)/(100*0.01=1.0)
     ;; = 0.5 → no clamp → round-to-2 = 0.5
     ((d :trading::types::Candle::Divergence)
      (:test::fresh-divergence 0.0))
     ((o :trading::types::Ohlcv) (:test::fresh-ohlcv 100.0))
     ((t :trading::types::Candle::Trend)
      (:test::fresh-trend 99.5 99.0 101.0 99.0))
     ((e :trading::encoding::VocabEmission)
      (:trading::vocab::market::ichimoku::encode-ichimoku-holons
        d o t (:test::empty-scales)))
     ((holons :wat::holon::Holons) (:wat::core::first e))
     ((actual :wat::holon::HolonAST)
      (:wat::core::match (:wat::core::get holons 3)
                         -> :wat::holon::HolonAST
        ((Some h) h)
        (:None (:wat::holon::Atom "unreachable"))))

     ((expected-value :wat::core::f64)
      (:trading::encoding::round-to-2
        (:wat::core::f64::clamp
          (:wat::core::/
            (:wat::core::- 99.5 99.0)
            (:wat::core::* 100.0 0.01))
          -1.0 1.0)))
     ((expected-tracker :trading::encoding::ScaleTracker)
      (:trading::encoding::ScaleTracker::update
        (:trading::encoding::ScaleTracker::fresh) expected-value))
     ((scale :wat::core::f64)
      (:trading::encoding::ScaleTracker::scale expected-tracker))
     ((neg-scale :wat::core::f64) (:wat::core::- 0.0 scale))
     ((expected :wat::holon::HolonAST)
      (:wat::holon::Bind
        (:wat::holon::Atom "tk-spread")
        (:wat::holon::Thermometer expected-value neg-scale scale))))
    (:wat::test::assert-eq
      (:wat::holon::coincident? actual expected)
      true)))

;; ─── 7. scales accumulate 5 entries (Log doesn't touch) ─────────

(:deftest :trading::test::vocab::market::ichimoku::test-scales-accumulate-5-entries
  (:wat::core::let*
    (((d :trading::types::Candle::Divergence)
      (:test::fresh-divergence 0.5))
     ((o :trading::types::Ohlcv) (:test::fresh-ohlcv 100.0))
     ((t :trading::types::Candle::Trend)
      (:test::fresh-trend 99.0 98.0 101.0 97.0))
     ((e :trading::encoding::VocabEmission)
      (:trading::vocab::market::ichimoku::encode-ichimoku-holons
        d o t (:test::empty-scales)))
     ((updated :trading::encoding::Scales) (:wat::core::second e)))
    (:wat::test::assert-eq
      (:wat::core::length updated)
      5)))

;; ─── 8. different candles differ — cloud-position across boundary

(:deftest :trading::test::vocab::market::ichimoku::test-different-candles-differ
  (:wat::core::let*
    ;; cloud-position: candle-a small magnitude (~0.01), candle-b
    ;; saturated (1.0). Across the ScaleTracker round-to-2 boundary.
    (((d :trading::types::Candle::Divergence)
      (:test::fresh-divergence 0.0))
     ((o-a :trading::types::Ohlcv) (:test::fresh-ohlcv 100.0))
     ((t-a :trading::types::Candle::Trend)
      (:test::fresh-trend 0.0 0.0 101.0 99.0))  ;; cloud_mid=100, close=100, position 0
     ((o-b :trading::types::Ohlcv) (:test::fresh-ohlcv 200.0))
     ((t-b :trading::types::Candle::Trend)
      (:test::fresh-trend 0.0 0.0 101.0 99.0))  ;; close above, saturates to 1.0
     ((e-a :trading::encoding::VocabEmission)
      (:trading::vocab::market::ichimoku::encode-ichimoku-holons
        d o-a t-a (:test::empty-scales)))
     ((e-b :trading::encoding::VocabEmission)
      (:trading::vocab::market::ichimoku::encode-ichimoku-holons
        d o-b t-b (:test::empty-scales)))
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
