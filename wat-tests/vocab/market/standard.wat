;; wat-tests/vocab/market/standard.wat — Lab arc 018.
;;
;; Eight tests for :trading::vocab::market::standard. First
;; window-based vocab tests in the lab. Tests the empty-window
;; guard, the find-last-index integration, the window aggregates,
;; and the count-family Log encoding at the new (1, 100) bounds.


(:wat::test::make-deftest :deftest
  ((:wat::load-file! "wat/vocab/market/standard.wat")

   ;; Asset constructor for Ohlcv defaults.
   (:wat::core::define
     (:test::btc -> :trading::types::Asset)
     (:trading::types::Asset/new "BTC"))

   (:wat::core::define
     (:test::default-trend -> :trading::types::Candle::Trend)
     (:trading::types::Candle::Trend/new 0.0 0.0 0.0 0.0 0.0 0.0 0.0))
   (:wat::core::define
     (:test::default-volatility -> :trading::types::Candle::Volatility)
     (:trading::types::Candle::Volatility/new 0.0 0.0 0.0 0.0 0.0 0.0 0.0))
   (:wat::core::define
     (:test::default-momentum -> :trading::types::Candle::Momentum)
     (:trading::types::Candle::Momentum/new 0.0 0.0 0.0 0.0 0.0 0.0 0.0 0.0 0.0 0.0 0.0 0.0))
   (:wat::core::define
     (:test::default-divergence -> :trading::types::Candle::Divergence)
     (:trading::types::Candle::Divergence/new 0.0 0.0 0.0 0.0))
   (:wat::core::define
     (:test::default-roc -> :trading::types::Candle::RateOfChange)
     (:trading::types::Candle::RateOfChange/new 0.0 0.0 0.0 0.0 0.0 0.0 0.0))
   (:wat::core::define
     (:test::default-persistence -> :trading::types::Candle::Persistence)
     (:trading::types::Candle::Persistence/new 0.0 0.0 0.0))
   (:wat::core::define
     (:test::default-regime -> :trading::types::Candle::Regime)
     (:trading::types::Candle::Regime/new 0.0 0.0 0.0 0.0 0.0 0.0 0.0 0.0))
   (:wat::core::define
     (:test::default-price-action -> :trading::types::Candle::PriceAction)
     (:trading::types::Candle::PriceAction/new 0.0 0.0 0.0 0.0))
   (:wat::core::define
     (:test::default-timeframe -> :trading::types::Candle::Timeframe)
     (:trading::types::Candle::Timeframe/new 0.0 0.0 0.0 0.0 0.0))
   (:wat::core::define
     (:test::default-time -> :trading::types::Candle::Time)
     (:trading::types::Candle::Time/new 0.0 0.0 0.0 0.0 0.0))
   (:wat::core::define
     (:test::default-phase -> :trading::types::Candle::Phase)
     (:trading::types::Candle::Phase/new
       :trading::types::PhaseLabel::Transition
       :trading::types::PhaseDirection::None
       0
       (:wat::core::vec :trading::types::PhaseRecord)))

   (:wat::core::define
     (:test::fresh-candle
       (high :wat::core::f64) (low :wat::core::f64) (close :wat::core::f64)
       (sma200 :wat::core::f64) (rsi :wat::core::f64) (volume-accel :wat::core::f64) (roc-1 :wat::core::f64)
       -> :trading::types::Candle)
     (:wat::core::let*
       (((btc :trading::types::Asset) (:test::btc))
        ((ohlcv :trading::types::Ohlcv)
         (:trading::types::Ohlcv/new btc btc "" 0.0 high low close 0.0))
        ((trend :trading::types::Candle::Trend)
         (:trading::types::Candle::Trend/new sma200 0.0 sma200 0.0 0.0 0.0 0.0))
        ((momentum :trading::types::Candle::Momentum)
         (:trading::types::Candle::Momentum/new
           rsi 0.0 0.0 0.0 0.0 0.0 0.0 0.0 0.0 0.0 0.0 volume-accel))
        ((roc :trading::types::Candle::RateOfChange)
         (:trading::types::Candle::RateOfChange/new
           roc-1 0.0 0.0 0.0 0.0 0.0 0.0)))
       (:trading::types::Candle/new
         ohlcv trend (:test::default-volatility)
         momentum (:test::default-divergence) roc
         (:test::default-persistence) (:test::default-regime)
         (:test::default-price-action) (:test::default-timeframe)
         (:test::default-time) (:test::default-phase))))

   (:wat::core::define
     (:test::empty-scales -> :trading::encoding::Scales)
     (:wat::core::HashMap :(String,trading::encoding::ScaleTracker)))))

;; ─── 1. count for non-empty window — 8 holons ──────────────────

(:deftest :trading::test::vocab::market::standard::test-non-empty-count
  (:wat::core::let*
    (((c :trading::types::Candle)
      (:test::fresh-candle 105.0 95.0 100.0 99.0 50.0 0.0 0.01))
     ((window :trading::types::Candles)
      (:wat::core::vec :trading::types::Candle c c c))
     ((e :trading::encoding::VocabEmission)
      (:trading::vocab::market::standard::encode-standard-holons
        window (:test::empty-scales)))
     ((holons :wat::holon::Holons) (:wat::core::first e)))
    (:wat::test::assert-eq
      (:wat::core::length holons)
      8)))

;; ─── 2. empty window emits zero holons ─────────────────────────

(:deftest :trading::test::vocab::market::standard::test-empty-window-zero-holons
  (:wat::core::let*
    (((window :trading::types::Candles)
      (:wat::core::vec :trading::types::Candle))
     ((e :trading::encoding::VocabEmission)
      (:trading::vocab::market::standard::encode-standard-holons
        window (:test::empty-scales)))
     ((holons :wat::holon::Holons) (:wat::core::first e)))
    (:wat::test::assert-eq
      (:wat::core::length holons)
      0)))

;; ─── 3. since-rsi-extreme finds extreme — fact[0] Log shape ─────

(:deftest :trading::test::vocab::market::standard::test-since-rsi-extreme-found
  (:wat::core::let*
    ;; window = [c0 (rsi=85, extreme), c1 (rsi=50)]
    ;; last-rsi-idx = 0 (c0 matched), n = 2, since = 2 - 0 = 2
    ;; floor at 1 → 2.0; round-to-2 → 2.0; Log 2.0 1.0 100.0
    (((c-extreme :trading::types::Candle)
      (:test::fresh-candle 100.0 90.0 95.0 0.0 85.0 0.0 0.0))
     ((c-normal :trading::types::Candle)
      (:test::fresh-candle 100.0 90.0 95.0 0.0 50.0 0.0 0.0))
     ((window :trading::types::Candles)
      (:wat::core::vec :trading::types::Candle c-extreme c-normal))
     ((e :trading::encoding::VocabEmission)
      (:trading::vocab::market::standard::encode-standard-holons
        window (:test::empty-scales)))
     ((holons :wat::holon::Holons) (:wat::core::first e))
     ((actual :wat::holon::HolonAST)
      (:wat::core::match (:wat::core::get holons 0)
                         -> :wat::holon::HolonAST
        ((Some h) h)
        (:None (:wat::holon::Atom "unreachable"))))

     ((expected :wat::holon::HolonAST)
      (:wat::holon::Bind
        (:wat::holon::Atom "since-rsi-extreme")
        (:wat::holon::Log 2.0 1.0 100.0))))
    (:wat::test::assert-eq
      (:wat::holon::coincident? actual expected)
      true)))

;; ─── 4. since-rsi-extreme defaults to n when no extreme ────────

(:deftest :trading::test::vocab::market::standard::test-since-rsi-extreme-no-match
  (:wat::core::let*
    ;; window = [c-normal × 3]; no extreme; since defaults to n = 3
    (((c :trading::types::Candle)
      (:test::fresh-candle 100.0 90.0 95.0 0.0 50.0 0.0 0.0))
     ((window :trading::types::Candles)
      (:wat::core::vec :trading::types::Candle c c c))
     ((e :trading::encoding::VocabEmission)
      (:trading::vocab::market::standard::encode-standard-holons
        window (:test::empty-scales)))
     ((holons :wat::holon::Holons) (:wat::core::first e))
     ((actual :wat::holon::HolonAST)
      (:wat::core::match (:wat::core::get holons 0)
                         -> :wat::holon::HolonAST
        ((Some h) h)
        (:None (:wat::holon::Atom "unreachable"))))

     ((expected :wat::holon::HolonAST)
      (:wat::holon::Bind
        (:wat::holon::Atom "since-rsi-extreme")
        (:wat::holon::Log 3.0 1.0 100.0))))
    (:wat::test::assert-eq
      (:wat::holon::coincident? actual expected)
      true)))

;; ─── 5. dist-from-high shape — fact[3], cross-Ohlcv compute ─────

(:deftest :trading::test::vocab::market::standard::test-dist-from-high-shape
  (:wat::core::let*
    ;; window = [c1 (high=110), c2 (high=105 close=100)]
    ;; window-high = max(110, 105) = 110; price = 100 (last candle)
    ;; (100 - 110) / 100 = -0.1 → round-to-4 = -0.1
    (((c1 :trading::types::Candle)
      (:test::fresh-candle 110.0 90.0 100.0 0.0 50.0 0.0 0.0))
     ((c2 :trading::types::Candle)
      (:test::fresh-candle 105.0 95.0 100.0 0.0 50.0 0.0 0.0))
     ((window :trading::types::Candles)
      (:wat::core::vec :trading::types::Candle c1 c2))
     ((e :trading::encoding::VocabEmission)
      (:trading::vocab::market::standard::encode-standard-holons
        window (:test::empty-scales)))
     ((holons :wat::holon::Holons) (:wat::core::first e))
     ((actual :wat::holon::HolonAST)
      (:wat::core::match (:wat::core::get holons 3)
                         -> :wat::holon::HolonAST
        ((Some h) h)
        (:None (:wat::holon::Atom "unreachable"))))

     ((expected-value :wat::core::f64)
      (:trading::encoding::round-to-4
        (:wat::core::/
          (:wat::core::- 100.0 110.0) 100.0)))
     ((expected-tracker :trading::encoding::ScaleTracker)
      (:trading::encoding::ScaleTracker::update
        (:trading::encoding::ScaleTracker::fresh) expected-value))
     ((scale :wat::core::f64)
      (:trading::encoding::ScaleTracker::scale expected-tracker))
     ((neg-scale :wat::core::f64) (:wat::core::- 0.0 scale))
     ((expected :wat::holon::HolonAST)
      (:wat::holon::Bind
        (:wat::holon::Atom "dist-from-high")
        (:wat::holon::Thermometer expected-value neg-scale scale))))
    (:wat::test::assert-eq
      (:wat::holon::coincident? actual expected)
      true)))

;; ─── 6. session-depth Log shape — fact[7], count family ─────────

(:deftest :trading::test::vocab::market::standard::test-session-depth-shape
  (:wat::core::let*
    ;; window of 3 candles: 1 + 3 = 4, max with 1 = 4; round-to-2 = 4.0
    (((c :trading::types::Candle)
      (:test::fresh-candle 100.0 90.0 95.0 0.0 50.0 0.0 0.0))
     ((window :trading::types::Candles)
      (:wat::core::vec :trading::types::Candle c c c))
     ((e :trading::encoding::VocabEmission)
      (:trading::vocab::market::standard::encode-standard-holons
        window (:test::empty-scales)))
     ((holons :wat::holon::Holons) (:wat::core::first e))
     ((actual :wat::holon::HolonAST)
      (:wat::core::match (:wat::core::get holons 7)
                         -> :wat::holon::HolonAST
        ((Some h) h)
        (:None (:wat::holon::Atom "unreachable"))))

     ((expected :wat::holon::HolonAST)
      (:wat::holon::Bind
        (:wat::holon::Atom "session-depth")
        (:wat::holon::Log 4.0 1.0 100.0))))
    (:wat::test::assert-eq
      (:wat::holon::coincident? actual expected)
      true)))

;; ─── 7. scales accumulate 4 entries — Log atoms don't touch ─────

(:deftest :trading::test::vocab::market::standard::test-scales-accumulate-4-entries
  (:wat::core::let*
    (((c :trading::types::Candle)
      (:test::fresh-candle 100.0 90.0 95.0 99.0 50.0 0.0 0.01))
     ((window :trading::types::Candles)
      (:wat::core::vec :trading::types::Candle c c))
     ((e :trading::encoding::VocabEmission)
      (:trading::vocab::market::standard::encode-standard-holons
        window (:test::empty-scales)))
     ((updated :trading::encoding::Scales) (:wat::core::second e)))
    (:wat::test::assert-eq
      (:wat::core::length updated)
      4)))

;; ─── 8. since-vol-spike finds vol > 2.0 — fact[1] ───────────────

(:deftest :trading::test::vocab::market::standard::test-since-vol-spike-found
  (:wat::core::let*
    ;; window = [c1 (vol=2.5, spike), c2 (vol=0.5), c3 (vol=0.3)]
    ;; last-vol-idx = 0; n = 3; since = 3 - 0 = 3 → Log 3.0
    (((c-spike :trading::types::Candle)
      (:test::fresh-candle 100.0 90.0 95.0 0.0 50.0 2.5 0.0))
     ((c-normal :trading::types::Candle)
      (:test::fresh-candle 100.0 90.0 95.0 0.0 50.0 0.5 0.0))
     ((window :trading::types::Candles)
      (:wat::core::vec :trading::types::Candle c-spike c-normal c-normal))
     ((e :trading::encoding::VocabEmission)
      (:trading::vocab::market::standard::encode-standard-holons
        window (:test::empty-scales)))
     ((holons :wat::holon::Holons) (:wat::core::first e))
     ((actual :wat::holon::HolonAST)
      (:wat::core::match (:wat::core::get holons 1)
                         -> :wat::holon::HolonAST
        ((Some h) h)
        (:None (:wat::holon::Atom "unreachable"))))

     ((expected :wat::holon::HolonAST)
      (:wat::holon::Bind
        (:wat::holon::Atom "since-vol-spike")
        (:wat::holon::Log 3.0 1.0 100.0))))
    (:wat::test::assert-eq
      (:wat::holon::coincident? actual expected)
      true)))
