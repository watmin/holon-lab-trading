;; wat-tests/vocab/market/flow.wat — Lab arc 014.
;;
;; Eight tests for :trading::vocab::market::flow. Fifth cross-sub-
;; struct module; **first K=3 module**. Names the substrate-gap-
;; algebraic-equivalence move (no exp primitive — direct Thermometer
;; at log-bounds). Names the range-conditional pattern.


(:wat::test::make-deftest :deftest
  ((:wat::load-file! "wat/vocab/market/flow.wat")
   (:wat::core::define
     (:test::fresh-ohlcv
       (o :f64) (h :f64) (l :f64) (c :f64)
       -> :trading::types::Ohlcv)
     (:wat::core::let*
       (((btc :trading::types::Asset)
         (:trading::types::Asset/new "BTC")))
       ;; 8-arg: source-asset, target-asset, ts, open, high, low,
       ;; close, volume.
       (:trading::types::Ohlcv/new
         btc btc "" o h l c 0.0)))
   (:wat::core::define
     (:test::fresh-momentum
       (obv-slope-12 :f64) (volume-accel :f64)
       -> :trading::types::Candle::Momentum)
     ;; 12-arg: rsi, macd-hist, plus-di, minus-di, adx, stoch-k,
     ;; stoch-d, williams-r, cci, mfi, obv-slope-12, volume-accel.
     (:trading::types::Candle::Momentum/new
       0.0 0.0 0.0 0.0 0.0 0.0 0.0 0.0 0.0 0.0 obv-slope-12 volume-accel))
   (:wat::core::define
     (:test::fresh-persistence
       (vwap-distance :f64)
       -> :trading::types::Candle::Persistence)
     ;; 3-arg: hurst, autocorrelation, vwap-distance.
     (:trading::types::Candle::Persistence/new
       0.0 0.0 vwap-distance))
   (:wat::core::define
     (:test::empty-scales -> :trading::encoding::Scales)
     (:wat::core::HashMap :(String,trading::encoding::ScaleTracker)))))

;; ─── 1. count — 6 holons emitted ───────────────────────────────

(:deftest :trading::test::vocab::market::flow::test-holons-count
  (:wat::core::let*
    (((m :trading::types::Candle::Momentum)
      (:test::fresh-momentum 0.5 0.2))
     ((o :trading::types::Ohlcv) (:test::fresh-ohlcv 100.0 105.0 95.0 102.0))
     ((p :trading::types::Candle::Persistence)
      (:test::fresh-persistence 0.01))
     ((e :trading::encoding::VocabEmission)
      (:trading::vocab::market::flow::encode-flow-holons
        m o p (:test::empty-scales)))
     ((holons :wat::holon::Holons) (:wat::core::first e)))
    (:wat::test::assert-eq
      (:wat::core::length holons)
      6)))

;; ─── 2. obv-slope log-bound shape — fact[0], ReciprocalLog ∘ exp

(:deftest :trading::test::vocab::market::flow::test-obv-slope-log-bound-shape
  (:wat::core::let*
    (;; obv-slope-12 = 0.5 → ReciprocalLog 10 (exp 0.5)
     ((m :trading::types::Candle::Momentum)
      (:test::fresh-momentum 0.5 0.0))
     ((o :trading::types::Ohlcv) (:test::fresh-ohlcv 100.0 105.0 95.0 102.0))
     ((p :trading::types::Candle::Persistence)
      (:test::fresh-persistence 0.01))
     ((e :trading::encoding::VocabEmission)
      (:trading::vocab::market::flow::encode-flow-holons
        m o p (:test::empty-scales)))
     ((holons :wat::holon::Holons) (:wat::core::first e))
     ((actual :wat::holon::HolonAST)
      (:wat::core::match (:wat::core::get holons 0)
                         -> :wat::holon::HolonAST
        ((Some h) h)
        (:None (:wat::holon::Atom "unreachable"))))

     ((expected :wat::holon::HolonAST)
      (:wat::holon::Bind
        (:wat::holon::Atom "obv-slope")
        (:wat::holon::ReciprocalLog 10.0
          (:wat::std::math::exp 0.5)))))
    (:wat::test::assert-eq
      (:wat::holon::coincident? actual expected)
      true)))

;; ─── 3. vwap-distance shape — fact[1], scaled-linear at round-to-4

(:deftest :trading::test::vocab::market::flow::test-vwap-distance-shape
  (:wat::core::let*
    (;; vwap-distance = 0.0237 — round-to-4 preserves
     ((m :trading::types::Candle::Momentum)
      (:test::fresh-momentum 0.0 0.0))
     ((o :trading::types::Ohlcv) (:test::fresh-ohlcv 100.0 105.0 95.0 102.0))
     ((p :trading::types::Candle::Persistence)
      (:test::fresh-persistence 0.0237))
     ((e :trading::encoding::VocabEmission)
      (:trading::vocab::market::flow::encode-flow-holons
        m o p (:test::empty-scales)))
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
        (:wat::holon::Atom "vwap-distance")
        (:wat::holon::Thermometer rounded neg-scale scale))))
    (:wat::test::assert-eq
      (:wat::holon::coincident? actual expected)
      true)))

;; ─── 4. buying-pressure shape (range > 0) — fact[2], cross-Ohlcv

(:deftest :trading::test::vocab::market::flow::test-buying-pressure-shape
  (:wat::core::let*
    (;; high=105, low=95, close=102 → range=10, (102-95)/10 = 0.7 → round-to-2 = 0.7
     ((m :trading::types::Candle::Momentum)
      (:test::fresh-momentum 0.0 0.0))
     ((o :trading::types::Ohlcv) (:test::fresh-ohlcv 100.0 105.0 95.0 102.0))
     ((p :trading::types::Candle::Persistence)
      (:test::fresh-persistence 0.0))
     ((e :trading::encoding::VocabEmission)
      (:trading::vocab::market::flow::encode-flow-holons
        m o p (:test::empty-scales)))
     ((holons :wat::holon::Holons) (:wat::core::first e))
     ((actual :wat::holon::HolonAST)
      (:wat::core::match (:wat::core::get holons 2)
                         -> :wat::holon::HolonAST
        ((Some h) h)
        (:None (:wat::holon::Atom "unreachable"))))

     ((expected-value :f64)
      (:trading::encoding::round-to-2
        (:wat::core::f64::/
          (:wat::core::f64::- 102.0 95.0)
          (:wat::core::f64::- 105.0 95.0))))
     ((expected-tracker :trading::encoding::ScaleTracker)
      (:trading::encoding::ScaleTracker::update
        (:trading::encoding::ScaleTracker::fresh) expected-value))
     ((scale :f64)
      (:trading::encoding::ScaleTracker::scale expected-tracker))
     ((neg-scale :f64) (:wat::core::f64::- 0.0 scale))
     ((expected :wat::holon::HolonAST)
      (:wat::holon::Bind
        (:wat::holon::Atom "buying-pressure")
        (:wat::holon::Thermometer expected-value neg-scale scale))))
    (:wat::test::assert-eq
      (:wat::holon::coincident? actual expected)
      true)))

;; ─── 5. buying-pressure default (range == 0) — fact[2], 0.5 default

(:deftest :trading::test::vocab::market::flow::test-buying-pressure-default
  (:wat::core::let*
    (;; high=100=low → range=0 → default 0.5
     ((m :trading::types::Candle::Momentum)
      (:test::fresh-momentum 0.0 0.0))
     ((o :trading::types::Ohlcv) (:test::fresh-ohlcv 100.0 100.0 100.0 100.0))
     ((p :trading::types::Candle::Persistence)
      (:test::fresh-persistence 0.0))
     ((e :trading::encoding::VocabEmission)
      (:trading::vocab::market::flow::encode-flow-holons
        m o p (:test::empty-scales)))
     ((holons :wat::holon::Holons) (:wat::core::first e))
     ((actual :wat::holon::HolonAST)
      (:wat::core::match (:wat::core::get holons 2)
                         -> :wat::holon::HolonAST
        ((Some h) h)
        (:None (:wat::holon::Atom "unreachable"))))

     ((expected-tracker :trading::encoding::ScaleTracker)
      (:trading::encoding::ScaleTracker::update
        (:trading::encoding::ScaleTracker::fresh) 0.5))
     ((scale :f64)
      (:trading::encoding::ScaleTracker::scale expected-tracker))
     ((neg-scale :f64) (:wat::core::f64::- 0.0 scale))
     ((expected :wat::holon::HolonAST)
      (:wat::holon::Bind
        (:wat::holon::Atom "buying-pressure")
        (:wat::holon::Thermometer 0.5 neg-scale scale))))
    (:wat::test::assert-eq
      (:wat::holon::coincident? actual expected)
      true)))

;; ─── 6. volume-ratio log-bound shape — fact[4]

(:deftest :trading::test::vocab::market::flow::test-volume-ratio-log-bound-shape
  (:wat::core::let*
    (;; volume-accel = -0.3 → ReciprocalLog 10 (exp -0.3)
     ((m :trading::types::Candle::Momentum)
      (:test::fresh-momentum 0.0 -0.3))
     ((o :trading::types::Ohlcv) (:test::fresh-ohlcv 100.0 105.0 95.0 102.0))
     ((p :trading::types::Candle::Persistence)
      (:test::fresh-persistence 0.0))
     ((e :trading::encoding::VocabEmission)
      (:trading::vocab::market::flow::encode-flow-holons
        m o p (:test::empty-scales)))
     ((holons :wat::holon::Holons) (:wat::core::first e))
     ((actual :wat::holon::HolonAST)
      (:wat::core::match (:wat::core::get holons 4)
                         -> :wat::holon::HolonAST
        ((Some h) h)
        (:None (:wat::holon::Atom "unreachable"))))

     ((expected :wat::holon::HolonAST)
      (:wat::holon::Bind
        (:wat::holon::Atom "volume-ratio")
        (:wat::holon::ReciprocalLog 10.0
          (:wat::std::math::exp -0.3)))))
    (:wat::test::assert-eq
      (:wat::holon::coincident? actual expected)
      true)))

;; ─── 7. scales accumulate 4 entries — Log atoms don't touch scales

(:deftest :trading::test::vocab::market::flow::test-scales-accumulate-4-entries
  (:wat::core::let*
    (((m :trading::types::Candle::Momentum)
      (:test::fresh-momentum 0.5 0.2))
     ((o :trading::types::Ohlcv) (:test::fresh-ohlcv 100.0 105.0 95.0 102.0))
     ((p :trading::types::Candle::Persistence)
      (:test::fresh-persistence 0.01))
     ((e :trading::encoding::VocabEmission)
      (:trading::vocab::market::flow::encode-flow-holons
        m o p (:test::empty-scales)))
     ((updated :trading::encoding::Scales) (:wat::core::second e)))
    (:wat::test::assert-eq
      (:wat::core::length updated)
      4)))

;; ─── 8. different candles differ — vwap-distance across scale boundary

(:deftest :trading::test::vocab::market::flow::test-different-candles-differ
  (:wat::core::let*
    ;; vwap-distance: candle-a small (0.01), candle-b large (0.5).
    ;; Arc 008's scale-collision footnote — values across the
    ;; ScaleTracker round-to-2 boundary.
    (((m :trading::types::Candle::Momentum)
      (:test::fresh-momentum 0.0 0.0))
     ((o :trading::types::Ohlcv) (:test::fresh-ohlcv 100.0 105.0 95.0 102.0))
     ((p-a :trading::types::Candle::Persistence)
      (:test::fresh-persistence 0.01))
     ((p-b :trading::types::Candle::Persistence)
      (:test::fresh-persistence 0.5))
     ((e-a :trading::encoding::VocabEmission)
      (:trading::vocab::market::flow::encode-flow-holons
        m o p-a (:test::empty-scales)))
     ((e-b :trading::encoding::VocabEmission)
      (:trading::vocab::market::flow::encode-flow-holons
        m o p-b (:test::empty-scales)))
     ((holons-a :wat::holon::Holons) (:wat::core::first e-a))
     ((holons-b :wat::holon::Holons) (:wat::core::first e-b))
     ((fact-a :wat::holon::HolonAST)
      (:wat::core::match (:wat::core::get holons-a 1)
                         -> :wat::holon::HolonAST
        ((Some h) h)
        (:None (:wat::holon::Atom "unreachable"))))
     ((fact-b :wat::holon::HolonAST)
      (:wat::core::match (:wat::core::get holons-b 1)
                         -> :wat::holon::HolonAST
        ((Some h) h)
        (:None (:wat::holon::Atom "unreachable")))))
    (:wat::test::assert-eq
      (:wat::holon::coincident? fact-a fact-b)
      false)))
