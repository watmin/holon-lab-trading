;; wat-tests/vocab/market/price-action.wat — Lab arc 017.
;;
;; Eight tests for :trading::vocab::market::price-action. Eighth
;; cross-sub-struct module; K=2 (Ohlcv + PriceAction). Biggest
;; plain-Log surface yet (3 atoms across 2 domain shapes). First
;; lab `:wat::core::f64::min` consumer.


(:wat::test::make-deftest :deftest
  ((:wat::load-file! "wat/vocab/market/price-action.wat")
   (:wat::core::define
     (:test::fresh-ohlcv
       (o :f64) (h :f64) (l :f64) (c :f64)
       -> :trading::types::Ohlcv)
     (:wat::core::let*
       (((btc :trading::types::Asset)
         (:trading::types::Asset/new "BTC")))
       ;; 8-arg.
       (:trading::types::Ohlcv/new
         btc btc "" o h l c 0.0)))
   (:wat::core::define
     (:test::fresh-price-action
       (range-ratio :f64) (gap :f64)
       (consecutive-up :f64) (consecutive-down :f64)
       -> :trading::types::Candle::PriceAction)
     ;; 4-arg: range-ratio, gap, consecutive-up, consecutive-down.
     (:trading::types::Candle::PriceAction/new
       range-ratio gap consecutive-up consecutive-down))
   (:wat::core::define
     (:test::empty-scales -> :trading::encoding::Scales)
     (:wat::core::HashMap :(String,trading::encoding::ScaleTracker)))))

;; ─── 1. count — 7 holons emitted ───────────────────────────────

(:deftest :trading::test::vocab::market::price-action::test-holons-count
  (:wat::core::let*
    (((o :trading::types::Ohlcv) (:test::fresh-ohlcv 100.0 105.0 95.0 102.0))
     ((p :trading::types::Candle::PriceAction)
      (:test::fresh-price-action 0.05 0.01 2.0 0.0))
     ((e :trading::encoding::VocabEmission)
      (:trading::vocab::market::price-action::encode-price-action-holons
        o p (:test::empty-scales)))
     ((holons :wat::holon::Holons) (:wat::core::first e)))
    (:wat::test::assert-eq
      (:wat::core::length holons)
      7)))

;; ─── 2. range-ratio plain-Log shape — fact[0], fraction-of-price ─

(:deftest :trading::test::vocab::market::price-action::test-range-ratio-log-shape
  (:wat::core::let*
    (;; range-ratio = 0.05 → above floor → round-to-4 = 0.05
     ((o :trading::types::Ohlcv) (:test::fresh-ohlcv 100.0 105.0 95.0 102.0))
     ((p :trading::types::Candle::PriceAction)
      (:test::fresh-price-action 0.05 0.01 2.0 0.0))
     ((e :trading::encoding::VocabEmission)
      (:trading::vocab::market::price-action::encode-price-action-holons
        o p (:test::empty-scales)))
     ((holons :wat::holon::Holons) (:wat::core::first e))
     ((actual :wat::holon::HolonAST)
      (:wat::core::match (:wat::core::get holons 0)
                         -> :wat::holon::HolonAST
        ((Some h) h)
        (:None (:wat::holon::Atom "unreachable"))))

     ((rounded :f64) (:trading::encoding::round-to-4 0.05))
     ((expected :wat::holon::HolonAST)
      (:wat::holon::Bind
        (:wat::holon::Atom "range-ratio")
        (:wat::holon::Log rounded 0.001 0.5))))
    (:wat::test::assert-eq
      (:wat::holon::coincident? actual expected)
      true)))

;; ─── 3. gap shape with clamp — fact[1], (gap/0.05) clamp ±1 ─────

(:deftest :trading::test::vocab::market::price-action::test-gap-shape-with-clamp
  (:wat::core::let*
    (;; gap = 0.10 → 0.10/0.05 = 2.0 → clamp to 1.0 → round-to-4 = 1.0
     ((o :trading::types::Ohlcv) (:test::fresh-ohlcv 100.0 105.0 95.0 102.0))
     ((p :trading::types::Candle::PriceAction)
      (:test::fresh-price-action 0.05 0.10 2.0 0.0))
     ((e :trading::encoding::VocabEmission)
      (:trading::vocab::market::price-action::encode-price-action-holons
        o p (:test::empty-scales)))
     ((holons :wat::holon::Holons) (:wat::core::first e))
     ((actual :wat::holon::HolonAST)
      (:wat::core::match (:wat::core::get holons 1)
                         -> :wat::holon::HolonAST
        ((Some h) h)
        (:None (:wat::holon::Atom "unreachable"))))

     ((expected-tracker :trading::encoding::ScaleTracker)
      (:trading::encoding::ScaleTracker::update
        (:trading::encoding::ScaleTracker::fresh) 1.0))
     ((scale :f64)
      (:trading::encoding::ScaleTracker::scale expected-tracker))
     ((neg-scale :f64) (:wat::core::f64::- 0.0 scale))
     ((expected :wat::holon::HolonAST)
      (:wat::holon::Bind
        (:wat::holon::Atom "gap")
        (:wat::holon::Thermometer 1.0 neg-scale scale))))
    (:wat::test::assert-eq
      (:wat::holon::coincident? actual expected)
      true)))

;; ─── 4. consecutive-up plain-Log shape — fact[2], count family ──

(:deftest :trading::test::vocab::market::price-action::test-consecutive-up-log-shape
  (:wat::core::let*
    (;; consecutive-up = 5 → 1 + 5 = 6 → above floor → round-to-2 = 6
     ((o :trading::types::Ohlcv) (:test::fresh-ohlcv 100.0 105.0 95.0 102.0))
     ((p :trading::types::Candle::PriceAction)
      (:test::fresh-price-action 0.05 0.01 5.0 0.0))
     ((e :trading::encoding::VocabEmission)
      (:trading::vocab::market::price-action::encode-price-action-holons
        o p (:test::empty-scales)))
     ((holons :wat::holon::Holons) (:wat::core::first e))
     ((actual :wat::holon::HolonAST)
      (:wat::core::match (:wat::core::get holons 2)
                         -> :wat::holon::HolonAST
        ((Some h) h)
        (:None (:wat::holon::Atom "unreachable"))))

     ((expected :wat::holon::HolonAST)
      (:wat::holon::Bind
        (:wat::holon::Atom "consecutive-up")
        (:wat::holon::Log 6.0 1.0 20.0))))
    (:wat::test::assert-eq
      (:wat::holon::coincident? actual expected)
      true)))

;; ─── 5. consecutive-up floor — input -2 → 1 + -2 = -1 → max 1 → 1

(:deftest :trading::test::vocab::market::price-action::test-consecutive-up-floor
  (:wat::core::let*
    (;; consecutive-up = -2 → 1 + -2 = -1 → max with 1.0 → 1.0
     ((o :trading::types::Ohlcv) (:test::fresh-ohlcv 100.0 105.0 95.0 102.0))
     ((p :trading::types::Candle::PriceAction)
      (:test::fresh-price-action 0.05 0.01 -2.0 0.0))
     ((e :trading::encoding::VocabEmission)
      (:trading::vocab::market::price-action::encode-price-action-holons
        o p (:test::empty-scales)))
     ((holons :wat::holon::Holons) (:wat::core::first e))
     ((actual :wat::holon::HolonAST)
      (:wat::core::match (:wat::core::get holons 2)
                         -> :wat::holon::HolonAST
        ((Some h) h)
        (:None (:wat::holon::Atom "unreachable"))))

     ((expected :wat::holon::HolonAST)
      (:wat::holon::Bind
        (:wat::holon::Atom "consecutive-up")
        (:wat::holon::Log 1.0 1.0 20.0))))
    (:wat::test::assert-eq
      (:wat::holon::coincident? actual expected)
      true)))

;; ─── 6. body-ratio-pa shape — fact[4], abs(close-open)/range ────

(:deftest :trading::test::vocab::market::price-action::test-body-ratio-pa-shape
  (:wat::core::let*
    (;; open=100, close=102 → body=2; high=105, low=95 → range=10
     ;; body/range = 0.2 → round-to-2 = 0.2
     ((o :trading::types::Ohlcv) (:test::fresh-ohlcv 100.0 105.0 95.0 102.0))
     ((p :trading::types::Candle::PriceAction)
      (:test::fresh-price-action 0.05 0.01 2.0 0.0))
     ((e :trading::encoding::VocabEmission)
      (:trading::vocab::market::price-action::encode-price-action-holons
        o p (:test::empty-scales)))
     ((holons :wat::holon::Holons) (:wat::core::first e))
     ((actual :wat::holon::HolonAST)
      (:wat::core::match (:wat::core::get holons 4)
                         -> :wat::holon::HolonAST
        ((Some h) h)
        (:None (:wat::holon::Atom "unreachable"))))

     ((expected-value :f64)
      (:trading::encoding::round-to-2
        (:wat::core::f64::/
          (:wat::core::f64::abs (:wat::core::f64::- 102.0 100.0))
          (:wat::core::f64::- 105.0 95.0))))
     ((expected-tracker :trading::encoding::ScaleTracker)
      (:trading::encoding::ScaleTracker::update
        (:trading::encoding::ScaleTracker::fresh) expected-value))
     ((scale :f64)
      (:trading::encoding::ScaleTracker::scale expected-tracker))
     ((neg-scale :f64) (:wat::core::f64::- 0.0 scale))
     ((expected :wat::holon::HolonAST)
      (:wat::holon::Bind
        (:wat::holon::Atom "body-ratio-pa")
        (:wat::holon::Thermometer expected-value neg-scale scale))))
    (:wat::test::assert-eq
      (:wat::holon::coincident? actual expected)
      true)))

;; ─── 7. upper-wick — fact[5], tests f64::max ────────────────────

(:deftest :trading::test::vocab::market::price-action::test-upper-wick-shape
  (:wat::core::let*
    (;; open=100, close=102 → max(open,close)=102; high=105
     ;; (105-102)/range = 3/10 = 0.3 → round-to-2 = 0.3
     ((o :trading::types::Ohlcv) (:test::fresh-ohlcv 100.0 105.0 95.0 102.0))
     ((p :trading::types::Candle::PriceAction)
      (:test::fresh-price-action 0.05 0.01 2.0 0.0))
     ((e :trading::encoding::VocabEmission)
      (:trading::vocab::market::price-action::encode-price-action-holons
        o p (:test::empty-scales)))
     ((holons :wat::holon::Holons) (:wat::core::first e))
     ((actual :wat::holon::HolonAST)
      (:wat::core::match (:wat::core::get holons 5)
                         -> :wat::holon::HolonAST
        ((Some h) h)
        (:None (:wat::holon::Atom "unreachable"))))

     ((expected-value :f64)
      (:trading::encoding::round-to-2
        (:wat::core::f64::/
          (:wat::core::f64::- 105.0 (:wat::core::f64::max 100.0 102.0))
          (:wat::core::f64::- 105.0 95.0))))
     ((expected-tracker :trading::encoding::ScaleTracker)
      (:trading::encoding::ScaleTracker::update
        (:trading::encoding::ScaleTracker::fresh) expected-value))
     ((scale :f64)
      (:trading::encoding::ScaleTracker::scale expected-tracker))
     ((neg-scale :f64) (:wat::core::f64::- 0.0 scale))
     ((expected :wat::holon::HolonAST)
      (:wat::holon::Bind
        (:wat::holon::Atom "upper-wick")
        (:wat::holon::Thermometer expected-value neg-scale scale))))
    (:wat::test::assert-eq
      (:wat::holon::coincident? actual expected)
      true)))

;; ─── 8. lower-wick — fact[6], tests f64::min (first lab use) ────

(:deftest :trading::test::vocab::market::price-action::test-lower-wick-shape
  (:wat::core::let*
    (;; open=100, close=102 → min(open,close)=100; low=95
     ;; (100-95)/range = 5/10 = 0.5 → round-to-2 = 0.5
     ((o :trading::types::Ohlcv) (:test::fresh-ohlcv 100.0 105.0 95.0 102.0))
     ((p :trading::types::Candle::PriceAction)
      (:test::fresh-price-action 0.05 0.01 2.0 0.0))
     ((e :trading::encoding::VocabEmission)
      (:trading::vocab::market::price-action::encode-price-action-holons
        o p (:test::empty-scales)))
     ((holons :wat::holon::Holons) (:wat::core::first e))
     ((actual :wat::holon::HolonAST)
      (:wat::core::match (:wat::core::get holons 6)
                         -> :wat::holon::HolonAST
        ((Some h) h)
        (:None (:wat::holon::Atom "unreachable"))))

     ((expected-value :f64)
      (:trading::encoding::round-to-2
        (:wat::core::f64::/
          (:wat::core::f64::- (:wat::core::f64::min 100.0 102.0) 95.0)
          (:wat::core::f64::- 105.0 95.0))))
     ((expected-tracker :trading::encoding::ScaleTracker)
      (:trading::encoding::ScaleTracker::update
        (:trading::encoding::ScaleTracker::fresh) expected-value))
     ((scale :f64)
      (:trading::encoding::ScaleTracker::scale expected-tracker))
     ((neg-scale :f64) (:wat::core::f64::- 0.0 scale))
     ((expected :wat::holon::HolonAST)
      (:wat::holon::Bind
        (:wat::holon::Atom "lower-wick")
        (:wat::holon::Thermometer expected-value neg-scale scale))))
    (:wat::test::assert-eq
      (:wat::holon::coincident? actual expected)
      true)))
