;; wat-tests/vocab/market/fibonacci.wat — Lab arc 007.
;;
;; Five tests for :trading::vocab::market::fibonacci — count,
;; two shape checks (one range-pos, one fib-dist to prove the
;; subtraction math), scales accumulation, and distinguishability
;; across distinct input candles.


(:wat::test::make-deftest :deftest
  ((:wat::load-file! "wat/vocab/market/fibonacci.wat")
   (:wat::core::define
     (:test::fresh-roc
       (rp-12 :f64) (rp-24 :f64) (rp-48 :f64)
       -> :trading::types::Candle::RateOfChange)
     (:trading::types::Candle::RateOfChange/new
       0.0 0.0 0.0 0.0    ;; roc-1, roc-3, roc-6, roc-12
       rp-12 rp-24 rp-48))
   (:wat::core::define
     (:test::empty-scales -> :trading::encoding::Scales)
     (:wat::core::HashMap :(String,trading::encoding::ScaleTracker)))))

;; ─── 1. count — 8 holons emitted ───────────────────────────────

(:deftest :trading::test::vocab::market::fibonacci::test-holons-count
  (:wat::core::let*
    (((r :trading::types::Candle::RateOfChange)
      (:test::fresh-roc 0.3 0.5 0.6))
     ((e :trading::encoding::VocabEmission)
      (:trading::vocab::market::fibonacci::encode-fibonacci-holons
        r (:test::empty-scales)))
     ((holons :wat::holon::Holons) (:wat::core::first e)))
    (:wat::test::assert-eq
      (:wat::core::length holons)
      8)))

;; ─── 2. range-pos-12 shape — fact[0] coincides with hand-built ─

(:deftest :trading::test::vocab::market::fibonacci::test-range-pos-12-shape
  (:wat::core::let*
    (((r :trading::types::Candle::RateOfChange)
      (:test::fresh-roc 0.3 0.5 0.6))
     ((e :trading::encoding::VocabEmission)
      (:trading::vocab::market::fibonacci::encode-fibonacci-holons
        r (:test::empty-scales)))
     ((holons :wat::holon::Holons) (:wat::core::first e))
     ((actual :wat::holon::HolonAST)
      (:wat::core::match (:wat::core::get holons 0)
                         -> :wat::holon::HolonAST
        ((Some h) h)
        (:None (:wat::holon::Atom "unreachable"))))

     ((expected-tracker :trading::encoding::ScaleTracker)
      (:trading::encoding::ScaleTracker::update
        (:trading::encoding::ScaleTracker::fresh) 0.3))
     ((scale :f64)
      (:trading::encoding::ScaleTracker::scale expected-tracker))
     ((neg-scale :f64) (:wat::core::f64::- 0.0 scale))
     ((rounded :f64) (:trading::encoding::round-to-2 0.3))
     ((expected :wat::holon::HolonAST)
      (:wat::holon::Bind
        (:wat::holon::Atom "range-pos-12")
        (:wat::holon::Thermometer rounded neg-scale scale))))
    (:wat::test::assert-eq
      (:wat::holon::coincident? actual expected)
      true)))

;; ─── 3. fib-dist-500 shape — fact[5] = rp-48 - 0.5, rounded ────

(:deftest :trading::test::vocab::market::fibonacci::test-fib-dist-500-shape
  (:wat::core::let*
    (((r :trading::types::Candle::RateOfChange)
      (:test::fresh-roc 0.3 0.5 0.6))
     ((e :trading::encoding::VocabEmission)
      (:trading::vocab::market::fibonacci::encode-fibonacci-holons
        r (:test::empty-scales)))
     ((holons :wat::holon::Holons) (:wat::core::first e))
     ;; fact[5] is fib-dist-500 (fact order: rp-12, rp-24, rp-48,
     ;; fib-236, fib-382, fib-500, fib-618, fib-786).
     ((actual :wat::holon::HolonAST)
      (:wat::core::match (:wat::core::get holons 5)
                         -> :wat::holon::HolonAST
        ((Some h) h)
        (:None (:wat::holon::Atom "unreachable"))))

     ;; Expected: Bind(Atom("fib-dist-500"),
     ;;                Thermometer(round-to-2(0.6 - 0.5),
     ;;                            -scale, scale))
     ((rounded :f64)
      (:trading::encoding::round-to-2
        (:wat::core::f64::- 0.6 0.5)))
     ((expected-tracker :trading::encoding::ScaleTracker)
      (:trading::encoding::ScaleTracker::update
        (:trading::encoding::ScaleTracker::fresh) rounded))
     ((scale :f64)
      (:trading::encoding::ScaleTracker::scale expected-tracker))
     ((neg-scale :f64) (:wat::core::f64::- 0.0 scale))
     ((expected :wat::holon::HolonAST)
      (:wat::holon::Bind
        (:wat::holon::Atom "fib-dist-500")
        (:wat::holon::Thermometer rounded neg-scale scale))))
    (:wat::test::assert-eq
      (:wat::holon::coincident? actual expected)
      true)))

;; ─── 4. scales accumulate 8 entries after one call ─────────────

(:deftest :trading::test::vocab::market::fibonacci::test-scales-accumulate-8-entries
  (:wat::core::let*
    (((r :trading::types::Candle::RateOfChange)
      (:test::fresh-roc 0.3 0.5 0.6))
     ((e :trading::encoding::VocabEmission)
      (:trading::vocab::market::fibonacci::encode-fibonacci-holons
        r (:test::empty-scales)))
     ((updated :trading::encoding::Scales) (:wat::core::second e)))
    (:wat::test::assert-eq
      (:wat::core::length updated)
      8)))

;; ─── 5. different candles differ ───────────────────────────────

(:deftest :trading::test::vocab::market::fibonacci::test-different-candles-differ
  (:wat::core::let*
    (((r-a :trading::types::Candle::RateOfChange)
      (:test::fresh-roc 0.1 0.2 0.3))
     ((r-b :trading::types::Candle::RateOfChange)
      (:test::fresh-roc 0.7 0.8 0.9))
     ((e-a :trading::encoding::VocabEmission)
      (:trading::vocab::market::fibonacci::encode-fibonacci-holons
        r-a (:test::empty-scales)))
     ((e-b :trading::encoding::VocabEmission)
      (:trading::vocab::market::fibonacci::encode-fibonacci-holons
        r-b (:test::empty-scales)))
     ((holons-a :wat::holon::Holons) (:wat::core::first e-a))
     ((holons-b :wat::holon::Holons) (:wat::core::first e-b))
     ;; Compare fact[0] (range-pos-12) — distinct input values give
     ;; distinct rounded atoms via scaled-linear.
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
