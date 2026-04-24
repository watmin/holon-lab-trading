;; wat-tests/vocab/market/timeframe.wat — Lab arc 011.
;;
;; Six tests for :trading::vocab::market::timeframe. Third cross-
;; sub-struct module. First Ohlcv read in a vocab. First round-to-4
;; caller. First cross-sub-struct compute (tf-5m-1h-align uses
;; fields from both sub-structs).

(:wat::config::set-capacity-mode! :error)
(:wat::config::set-dims! 1024)

(:wat::test::make-deftest :deftest
  ((:wat::load-file! "wat/vocab/market/timeframe.wat")
   (:wat::core::define
     (:test::fresh-ohlcv
       (o :f64) (c :f64)
       -> :trading::types::Ohlcv)
     (:wat::core::let*
       (((btc :trading::types::Asset)
         (:trading::types::Asset/new "BTC")))
       ;; 8-arg: source-asset, target-asset, ts, open, high, low,
       ;; close, volume.
       (:trading::types::Ohlcv/new
         btc btc "" o 0.0 0.0 c 0.0)))
   (:wat::core::define
     (:test::fresh-timeframe
       (body-1h :f64) (ret-1h :f64)
       -> :trading::types::Candle::Timeframe)
     ;; 5-arg: tf-1h-ret, tf-1h-body, tf-4h-ret, tf-4h-body, tf-agreement.
     (:trading::types::Candle::Timeframe/new
       ret-1h body-1h 0.0 0.0 0.0))
   (:wat::core::define
     (:test::empty-scales -> :trading::encoding::Scales)
     (:wat::core::HashMap :(String,trading::encoding::ScaleTracker)))))

;; ─── 1. count — 6 holons emitted ───────────────────────────────

(:deftest :trading::test::vocab::market::timeframe::test-holons-count
  (:wat::core::let*
    (((o :trading::types::Ohlcv) (:test::fresh-ohlcv 100.0 105.0))
     ((t :trading::types::Candle::Timeframe)
      (:test::fresh-timeframe 0.5 0.02))
     ((e :trading::encoding::VocabEmission)
      (:trading::vocab::market::timeframe::encode-timeframe-holons
        o t (:test::empty-scales)))
     ((holons :wat::holon::Holons) (:wat::core::first e)))
    (:wat::test::assert-eq
      (:wat::core::length holons)
      6)))

;; ─── 2. tf-1h-trend shape — fact[0], round-to-2, Timeframe only ─

(:deftest :trading::test::vocab::market::timeframe::test-tf-1h-trend-shape
  (:wat::core::let*
    (((o :trading::types::Ohlcv) (:test::fresh-ohlcv 100.0 105.0))
     ((t :trading::types::Candle::Timeframe)
      (:test::fresh-timeframe 0.5 0.02))
     ((e :trading::encoding::VocabEmission)
      (:trading::vocab::market::timeframe::encode-timeframe-holons
        o t (:test::empty-scales)))
     ((holons :wat::holon::Holons) (:wat::core::first e))
     ((actual :wat::holon::HolonAST)
      (:wat::core::match (:wat::core::get holons 0)
                         -> :wat::holon::HolonAST
        ((Some h) h)
        (:None (:wat::holon::Atom "unreachable"))))

     ;; body-1h = 0.5 → round-to-2 = 0.5
     ((rounded :f64) (:trading::encoding::round-to-2 0.5))
     ((expected-tracker :trading::encoding::ScaleTracker)
      (:trading::encoding::ScaleTracker::update
        (:trading::encoding::ScaleTracker::fresh) rounded))
     ((scale :f64)
      (:trading::encoding::ScaleTracker::scale expected-tracker))
     ((neg-scale :f64) (:wat::core::f64::- 0.0 scale))
     ((expected :wat::holon::HolonAST)
      (:wat::holon::Bind
        (:wat::holon::Atom "tf-1h-trend")
        (:wat::holon::Thermometer rounded neg-scale scale))))
    (:wat::test::assert-eq
      (:wat::holon::coincident? actual expected)
      true)))

;; ─── 3. tf-1h-ret shape — fact[1], round-to-4 path ────────────

(:deftest :trading::test::vocab::market::timeframe::test-tf-1h-ret-shape
  (:wat::core::let*
    (((o :trading::types::Ohlcv) (:test::fresh-ohlcv 100.0 105.0))
     ;; ret-1h = 0.0237 — requires round-to-4 precision
     ((t :trading::types::Candle::Timeframe)
      (:test::fresh-timeframe 0.5 0.0237))
     ((e :trading::encoding::VocabEmission)
      (:trading::vocab::market::timeframe::encode-timeframe-holons
        o t (:test::empty-scales)))
     ((holons :wat::holon::Holons) (:wat::core::first e))
     ((actual :wat::holon::HolonAST)
      (:wat::core::match (:wat::core::get holons 1)
                         -> :wat::holon::HolonAST
        ((Some h) h)
        (:None (:wat::holon::Atom "unreachable"))))

     ((rounded :f64) (:trading::encoding::round-to-4 0.0237))
     ((expected-tracker :trading::encoding::ScaleTracker)
      (:trading::encoding::ScaleTracker::update
        (:trading::encoding::ScaleTracker::fresh) rounded))
     ((scale :f64)
      (:trading::encoding::ScaleTracker::scale expected-tracker))
     ((neg-scale :f64) (:wat::core::f64::- 0.0 scale))
     ((expected :wat::holon::HolonAST)
      (:wat::holon::Bind
        (:wat::holon::Atom "tf-1h-ret")
        (:wat::holon::Thermometer rounded neg-scale scale))))
    (:wat::test::assert-eq
      (:wat::holon::coincident? actual expected)
      true)))

;; ─── 4. tf-5m-1h-align computed — fact[5] exercises cross-compute

(:deftest :trading::test::vocab::market::timeframe::test-tf-5m-1h-align-computed
  (:wat::core::let*
    (;; open=100, close=105 → 5m-ret = (105-100)/105 = 0.047619...
     ;; body-1h = 0.5 (positive) → signum = 1.0
     ;; align = 1.0 * 0.047619... = 0.047619... → round-to-4 = 0.0476
     ((o :trading::types::Ohlcv) (:test::fresh-ohlcv 100.0 105.0))
     ((t :trading::types::Candle::Timeframe)
      (:test::fresh-timeframe 0.5 0.02))
     ((e :trading::encoding::VocabEmission)
      (:trading::vocab::market::timeframe::encode-timeframe-holons
        o t (:test::empty-scales)))
     ((holons :wat::holon::Holons) (:wat::core::first e))
     ((actual :wat::holon::HolonAST)
      (:wat::core::match (:wat::core::get holons 5)
                         -> :wat::holon::HolonAST
        ((Some h) h)
        (:None (:wat::holon::Atom "unreachable"))))

     ;; Recompute the expected value symmetrically.
     ((five-m-ret :f64)
      (:wat::core::f64::/
        (:wat::core::f64::- 105.0 100.0) 105.0))
     ((align :f64)
      (:trading::encoding::round-to-4
        (:wat::core::f64::* 1.0 five-m-ret)))
     ((expected-tracker :trading::encoding::ScaleTracker)
      (:trading::encoding::ScaleTracker::update
        (:trading::encoding::ScaleTracker::fresh) align))
     ((scale :f64)
      (:trading::encoding::ScaleTracker::scale expected-tracker))
     ((neg-scale :f64) (:wat::core::f64::- 0.0 scale))
     ((expected :wat::holon::HolonAST)
      (:wat::holon::Bind
        (:wat::holon::Atom "tf-5m-1h-align")
        (:wat::holon::Thermometer align neg-scale scale))))
    (:wat::test::assert-eq
      (:wat::holon::coincident? actual expected)
      true)))

;; ─── 5. scales accumulate 6 entries ───────────────────────────

(:deftest :trading::test::vocab::market::timeframe::test-scales-accumulate-6-entries
  (:wat::core::let*
    (((o :trading::types::Ohlcv) (:test::fresh-ohlcv 100.0 105.0))
     ((t :trading::types::Candle::Timeframe)
      (:test::fresh-timeframe 0.5 0.02))
     ((e :trading::encoding::VocabEmission)
      (:trading::vocab::market::timeframe::encode-timeframe-holons
        o t (:test::empty-scales)))
     ((updated :trading::encoding::Scales) (:wat::core::second e)))
    (:wat::test::assert-eq
      (:wat::core::length updated)
      6)))

;; ─── 6. different candles differ — scale-boundary tf-1h-trend ──

(:deftest :trading::test::vocab::market::timeframe::test-different-candles-differ
  (:wat::core::let*
    ;; body-1h 0.1 → scale 0.001 (floor); 0.9 → scale 0.02. Arc 008
    ;; scale-collision footnote.
    (((o-a :trading::types::Ohlcv) (:test::fresh-ohlcv 100.0 101.0))
     ((t-a :trading::types::Candle::Timeframe)
      (:test::fresh-timeframe 0.1 0.01))
     ((o-b :trading::types::Ohlcv) (:test::fresh-ohlcv 100.0 109.0))
     ((t-b :trading::types::Candle::Timeframe)
      (:test::fresh-timeframe 0.9 0.09))
     ((e-a :trading::encoding::VocabEmission)
      (:trading::vocab::market::timeframe::encode-timeframe-holons
        o-a t-a (:test::empty-scales)))
     ((e-b :trading::encoding::VocabEmission)
      (:trading::vocab::market::timeframe::encode-timeframe-holons
        o-b t-b (:test::empty-scales)))
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
