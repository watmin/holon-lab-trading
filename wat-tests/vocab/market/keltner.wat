;; wat-tests/vocab/market/keltner.wat — Lab arc 016.
;;
;; Seven tests for :trading::vocab::market::keltner. Seventh
;; cross-sub-struct module; K=2 (Ohlcv + Volatility). Third plain-
;; Log caller (cites arc 013 + 015 precedent). First post-arc-046
;; pure substrate-direct vocab arc.


(:wat::test::make-deftest :deftest
  ((:wat::load-file! "wat/vocab/market/keltner.wat")
   (:wat::core::define
     (:test::fresh-ohlcv (c :f64) -> :trading::types::Ohlcv)
     (:wat::core::let*
       (((btc :trading::types::Asset)
         (:trading::types::Asset/new "BTC")))
       ;; 8-arg: source-asset, target-asset, ts, open, high, low,
       ;; close, volume. Only `close` matters here.
       (:trading::types::Ohlcv/new
         btc btc "" 0.0 0.0 0.0 c 0.0)))
   (:wat::core::define
     (:test::fresh-volatility
       (bb-pos :f64) (bb-width :f64)
       (kelt-upper :f64) (kelt-lower :f64) (kelt-pos :f64)
       (squeeze :f64)
       -> :trading::types::Candle::Volatility)
     ;; 7-arg: bb-width, bb-pos, kelt-upper, kelt-lower, kelt-pos,
     ;; squeeze, atr-ratio.
     (:trading::types::Candle::Volatility/new
       bb-width bb-pos kelt-upper kelt-lower kelt-pos squeeze 0.0))
   (:wat::core::define
     (:test::empty-scales -> :trading::encoding::Scales)
     (:wat::core::HashMap :(String,trading::encoding::ScaleTracker)))))

;; ─── 1. count — 6 holons emitted ───────────────────────────────

(:deftest :trading::test::vocab::market::keltner::test-holons-count
  (:wat::core::let*
    (((o :trading::types::Ohlcv) (:test::fresh-ohlcv 100.0))
     ((v :trading::types::Candle::Volatility)
      (:test::fresh-volatility 0.5 0.04 105.0 95.0 0.6 0.95))
     ((e :trading::encoding::VocabEmission)
      (:trading::vocab::market::keltner::encode-keltner-holons
        o v (:test::empty-scales)))
     ((holons :wat::holon::Holons) (:wat::core::first e)))
    (:wat::test::assert-eq
      (:wat::core::length holons)
      6)))

;; ─── 2. bb-pos shape — fact[0], pure-Volatility scaled-linear ───

(:deftest :trading::test::vocab::market::keltner::test-bb-pos-shape
  (:wat::core::let*
    (;; bb-pos = 0.5 → round-to-2 = 0.5
     ((o :trading::types::Ohlcv) (:test::fresh-ohlcv 100.0))
     ((v :trading::types::Candle::Volatility)
      (:test::fresh-volatility 0.5 0.04 105.0 95.0 0.6 0.95))
     ((e :trading::encoding::VocabEmission)
      (:trading::vocab::market::keltner::encode-keltner-holons
        o v (:test::empty-scales)))
     ((holons :wat::holon::Holons) (:wat::core::first e))
     ((actual :wat::holon::HolonAST)
      (:wat::core::match (:wat::core::get holons 0)
                         -> :wat::holon::HolonAST
        ((Some h) h)
        (:None (:wat::holon::Atom "unreachable"))))

     ((rounded :f64) (:trading::encoding::round-to-2 0.5))
     ((expected-tracker :trading::encoding::ScaleTracker)
      (:trading::encoding::ScaleTracker::update
        (:trading::encoding::ScaleTracker::fresh) rounded))
     ((scale :f64)
      (:trading::encoding::ScaleTracker::scale expected-tracker))
     ((neg-scale :f64) (:wat::core::- 0.0 scale))
     ((expected :wat::holon::HolonAST)
      (:wat::holon::Bind
        (:wat::holon::Atom "bb-pos")
        (:wat::holon::Thermometer rounded neg-scale scale))))
    (:wat::test::assert-eq
      (:wat::holon::coincident? actual expected)
      true)))

;; ─── 3. bb-width plain-Log shape — fact[1] ─────────────────────

(:deftest :trading::test::vocab::market::keltner::test-bb-width-log-shape
  (:wat::core::let*
    (;; bb-width = 0.04 (above floor) → round-to-4 = 0.04
     ;; Encoded via Log 0.04 0.001 0.5
     ((o :trading::types::Ohlcv) (:test::fresh-ohlcv 100.0))
     ((v :trading::types::Candle::Volatility)
      (:test::fresh-volatility 0.5 0.04 105.0 95.0 0.6 0.95))
     ((e :trading::encoding::VocabEmission)
      (:trading::vocab::market::keltner::encode-keltner-holons
        o v (:test::empty-scales)))
     ((holons :wat::holon::Holons) (:wat::core::first e))
     ((actual :wat::holon::HolonAST)
      (:wat::core::match (:wat::core::get holons 1)
                         -> :wat::holon::HolonAST
        ((Some h) h)
        (:None (:wat::holon::Atom "unreachable"))))

     ((rounded :f64) (:trading::encoding::round-to-4 0.04))
     ((expected :wat::holon::HolonAST)
      (:wat::holon::Bind
        (:wat::holon::Atom "bb-width")
        (:wat::holon::Log rounded 0.001 0.5))))
    (:wat::test::assert-eq
      (:wat::holon::coincident? actual expected)
      true)))

;; ─── 4. bb-width floor — input 0 lifts to 0.001 ────────────────

(:deftest :trading::test::vocab::market::keltner::test-bb-width-floor
  (:wat::core::let*
    (;; bb-width = 0.0 → floor 0.001 → round-to-4 = 0.001
     ((o :trading::types::Ohlcv) (:test::fresh-ohlcv 100.0))
     ((v :trading::types::Candle::Volatility)
      (:test::fresh-volatility 0.5 0.0 105.0 95.0 0.6 0.95))
     ((e :trading::encoding::VocabEmission)
      (:trading::vocab::market::keltner::encode-keltner-holons
        o v (:test::empty-scales)))
     ((holons :wat::holon::Holons) (:wat::core::first e))
     ((actual :wat::holon::HolonAST)
      (:wat::core::match (:wat::core::get holons 1)
                         -> :wat::holon::HolonAST
        ((Some h) h)
        (:None (:wat::holon::Atom "unreachable"))))

     ((expected :wat::holon::HolonAST)
      (:wat::holon::Bind
        (:wat::holon::Atom "bb-width")
        (:wat::holon::Log 0.001 0.001 0.5))))
    (:wat::test::assert-eq
      (:wat::holon::coincident? actual expected)
      true)))

;; ─── 5. kelt-upper-dist shape — fact[4], cross-Ohlcv-Volatility ─

(:deftest :trading::test::vocab::market::keltner::test-kelt-upper-dist-shape
  (:wat::core::let*
    (;; close=100, kelt-upper=105 → (100-105)/100 = -0.05 → round-to-4 = -0.05
     ((o :trading::types::Ohlcv) (:test::fresh-ohlcv 100.0))
     ((v :trading::types::Candle::Volatility)
      (:test::fresh-volatility 0.5 0.04 105.0 95.0 0.6 0.95))
     ((e :trading::encoding::VocabEmission)
      (:trading::vocab::market::keltner::encode-keltner-holons
        o v (:test::empty-scales)))
     ((holons :wat::holon::Holons) (:wat::core::first e))
     ((actual :wat::holon::HolonAST)
      (:wat::core::match (:wat::core::get holons 4)
                         -> :wat::holon::HolonAST
        ((Some h) h)
        (:None (:wat::holon::Atom "unreachable"))))

     ((expected-value :f64)
      (:trading::encoding::round-to-4
        (:wat::core::/
          (:wat::core::- 100.0 105.0) 100.0)))
     ((expected-tracker :trading::encoding::ScaleTracker)
      (:trading::encoding::ScaleTracker::update
        (:trading::encoding::ScaleTracker::fresh) expected-value))
     ((scale :f64)
      (:trading::encoding::ScaleTracker::scale expected-tracker))
     ((neg-scale :f64) (:wat::core::- 0.0 scale))
     ((expected :wat::holon::HolonAST)
      (:wat::holon::Bind
        (:wat::holon::Atom "kelt-upper-dist")
        (:wat::holon::Thermometer expected-value neg-scale scale))))
    (:wat::test::assert-eq
      (:wat::holon::coincident? actual expected)
      true)))

;; ─── 6. scales accumulate 5 entries (Log doesn't touch) ─────────

(:deftest :trading::test::vocab::market::keltner::test-scales-accumulate-5-entries
  (:wat::core::let*
    (((o :trading::types::Ohlcv) (:test::fresh-ohlcv 100.0))
     ((v :trading::types::Candle::Volatility)
      (:test::fresh-volatility 0.5 0.04 105.0 95.0 0.6 0.95))
     ((e :trading::encoding::VocabEmission)
      (:trading::vocab::market::keltner::encode-keltner-holons
        o v (:test::empty-scales)))
     ((updated :trading::encoding::Scales) (:wat::core::second e)))
    (:wat::test::assert-eq
      (:wat::core::length updated)
      5)))

;; ─── 7. different candles differ — bb-pos across boundary ───────

(:deftest :trading::test::vocab::market::keltner::test-different-candles-differ
  (:wat::core::let*
    ;; bb-pos: candle-a small (0.01) → scale 0.00; candle-b large
    ;; (0.5) → scale ~0.01. Across the ScaleTracker round-to-2
    ;; boundary.
    (((o :trading::types::Ohlcv) (:test::fresh-ohlcv 100.0))
     ((v-a :trading::types::Candle::Volatility)
      (:test::fresh-volatility 0.01 0.04 105.0 95.0 0.6 0.95))
     ((v-b :trading::types::Candle::Volatility)
      (:test::fresh-volatility 0.5 0.04 105.0 95.0 0.6 0.95))
     ((e-a :trading::encoding::VocabEmission)
      (:trading::vocab::market::keltner::encode-keltner-holons
        o v-a (:test::empty-scales)))
     ((e-b :trading::encoding::VocabEmission)
      (:trading::vocab::market::keltner::encode-keltner-holons
        o v-b (:test::empty-scales)))
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
