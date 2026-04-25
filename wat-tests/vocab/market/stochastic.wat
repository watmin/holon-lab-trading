;; wat-tests/vocab/market/stochastic.wat — Lab arc 009.
;;
;; Five tests for :trading::vocab::market::stochastic. Second
;; cross-sub-struct module — inherits arc 008's signature rule
;; without rederivation. Adds one test for the inline clamp.


(:wat::test::make-deftest :deftest
  ((:wat::load-file! "wat/vocab/market/stochastic.wat")
   (:wat::core::define
     (:test::fresh-momentum-with-stoch
       (k :f64) (d :f64)
       -> :trading::types::Candle::Momentum)
     (:trading::types::Candle::Momentum/new
       0.0 0.0 0.0 0.0 0.0    ;; rsi, macd-hist, plus-di, minus-di, adx
       k d                    ;; stoch-k (position 6), stoch-d (position 7)
       0.0 0.0 0.0 0.0 0.0))  ;; williams-r, cci, mfi, obv-slope-12, volume-accel
   (:wat::core::define
     (:test::fresh-divergence-with-delta
       (delta :f64)
       -> :trading::types::Candle::Divergence)
     (:trading::types::Candle::Divergence/new
       0.0 0.0 0.0 delta))    ;; bull, bear, tk-cross-delta, stoch-cross-delta
   (:wat::core::define
     (:test::empty-scales -> :trading::encoding::Scales)
     (:wat::core::HashMap :(String,trading::encoding::ScaleTracker)))))

;; ─── 1. count — 4 holons emitted ───────────────────────────────

(:deftest :trading::test::vocab::market::stochastic::test-holons-count
  (:wat::core::let*
    (((m :trading::types::Candle::Momentum)
      (:test::fresh-momentum-with-stoch 70.0 60.0))
     ((d :trading::types::Candle::Divergence)
      (:test::fresh-divergence-with-delta 0.3))
     ((e :trading::encoding::VocabEmission)
      (:trading::vocab::market::stochastic::encode-stochastic-holons
        d m (:test::empty-scales)))
     ((holons :wat::holon::Holons) (:wat::core::first e)))
    (:wat::test::assert-eq
      (:wat::core::length holons)
      4)))

;; ─── 2. stoch-k shape — fact[0], /100 normalized ──────────────

(:deftest :trading::test::vocab::market::stochastic::test-stoch-k-shape
  (:wat::core::let*
    (;; stoch-k=70 → 70/100 = 0.7 → round-to-2 = 0.7
     ((m :trading::types::Candle::Momentum)
      (:test::fresh-momentum-with-stoch 70.0 60.0))
     ((d :trading::types::Candle::Divergence)
      (:test::fresh-divergence-with-delta 0.3))
     ((e :trading::encoding::VocabEmission)
      (:trading::vocab::market::stochastic::encode-stochastic-holons
        d m (:test::empty-scales)))
     ((holons :wat::holon::Holons) (:wat::core::first e))
     ((actual :wat::holon::HolonAST)
      (:wat::core::match (:wat::core::get holons 0)
                         -> :wat::holon::HolonAST
        ((Some h) h)
        (:None (:wat::holon::Atom "unreachable"))))

     ((rounded :f64) (:trading::encoding::round-to-2 0.7))
     ((expected-tracker :trading::encoding::ScaleTracker)
      (:trading::encoding::ScaleTracker::update
        (:trading::encoding::ScaleTracker::fresh) rounded))
     ((scale :f64)
      (:trading::encoding::ScaleTracker::scale expected-tracker))
     ((neg-scale :f64) (:wat::core::- 0.0 scale))
     ((expected :wat::holon::HolonAST)
      (:wat::holon::Bind
        (:wat::holon::Atom "stoch-k")
        (:wat::holon::Thermometer rounded neg-scale scale))))
    (:wat::test::assert-eq
      (:wat::holon::coincident? actual expected)
      true)))

;; ─── 3. cross-delta clamp — raw 1.5 encodes as 1.0 ─────────────

(:deftest :trading::test::vocab::market::stochastic::test-cross-delta-clamp-high
  (:wat::core::let*
    (;; Raw delta 1.5 → clamped to 1.0 → rounded 1.0
     ((m :trading::types::Candle::Momentum)
      (:test::fresh-momentum-with-stoch 50.0 50.0))
     ((d :trading::types::Candle::Divergence)
      (:test::fresh-divergence-with-delta 1.5))
     ((e :trading::encoding::VocabEmission)
      (:trading::vocab::market::stochastic::encode-stochastic-holons
        d m (:test::empty-scales)))
     ((holons :wat::holon::Holons) (:wat::core::first e))
     ;; fact[3] is stoch-cross-delta.
     ((actual :wat::holon::HolonAST)
      (:wat::core::match (:wat::core::get holons 3)
                         -> :wat::holon::HolonAST
        ((Some h) h)
        (:None (:wat::holon::Atom "unreachable"))))

     ;; Expected: the clamp-and-round produced 1.0, so the fact
     ;; should coincide with a fresh-tracker encoding of value 1.0.
     ;; Scales accumulate across earlier atoms, but stoch-cross-delta
     ;; is its own key — first observation, fresh tracker.
     ((rounded :f64) (:trading::encoding::round-to-2 1.0))
     ((expected-tracker :trading::encoding::ScaleTracker)
      (:trading::encoding::ScaleTracker::update
        (:trading::encoding::ScaleTracker::fresh) rounded))
     ((scale :f64)
      (:trading::encoding::ScaleTracker::scale expected-tracker))
     ((neg-scale :f64) (:wat::core::- 0.0 scale))
     ((expected :wat::holon::HolonAST)
      (:wat::holon::Bind
        (:wat::holon::Atom "stoch-cross-delta")
        (:wat::holon::Thermometer rounded neg-scale scale))))
    (:wat::test::assert-eq
      (:wat::holon::coincident? actual expected)
      true)))

;; ─── 4. scales accumulate 4 entries after one call ─────────────

(:deftest :trading::test::vocab::market::stochastic::test-scales-accumulate-4-entries
  (:wat::core::let*
    (((m :trading::types::Candle::Momentum)
      (:test::fresh-momentum-with-stoch 70.0 60.0))
     ((d :trading::types::Candle::Divergence)
      (:test::fresh-divergence-with-delta 0.3))
     ((e :trading::encoding::VocabEmission)
      (:trading::vocab::market::stochastic::encode-stochastic-holons
        d m (:test::empty-scales)))
     ((updated :trading::encoding::Scales) (:wat::core::second e)))
    (:wat::test::assert-eq
      (:wat::core::length updated)
      4)))

;; ─── 5. different candles differ — scale-boundary values ──────

(:deftest :trading::test::vocab::market::stochastic::test-different-candles-differ
  (:wat::core::let*
    ;; Per arc 008's scale-collision footnote: pick values whose
    ;; first-call ScaleTracker rounds to distinct scales. Normalized
    ;; values 0.1 → scale 0.001 (floor); 0.9 → scale 0.02. Raw
    ;; stoch-k=10 → 0.1 norm; raw stoch-k=90 → 0.9 norm.
    (((m-a :trading::types::Candle::Momentum)
      (:test::fresh-momentum-with-stoch 10.0 5.0))
     ((d-a :trading::types::Candle::Divergence)
      (:test::fresh-divergence-with-delta 0.1))
     ((m-b :trading::types::Candle::Momentum)
      (:test::fresh-momentum-with-stoch 90.0 80.0))
     ((d-b :trading::types::Candle::Divergence)
      (:test::fresh-divergence-with-delta 0.9))
     ((e-a :trading::encoding::VocabEmission)
      (:trading::vocab::market::stochastic::encode-stochastic-holons
        d-a m-a (:test::empty-scales)))
     ((e-b :trading::encoding::VocabEmission)
      (:trading::vocab::market::stochastic::encode-stochastic-holons
        d-b m-b (:test::empty-scales)))
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
