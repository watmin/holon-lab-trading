;; wat-tests/vocab/market/regime.wat — Lab arc 010.
;;
;; Six tests for :trading::vocab::market::regime. Single sub-struct
;; (K=1). Exercises both scaled-linear thread and ReciprocalLog 10.0
;; for variance-ratio. Includes explicit floor-behavior test for the
;; one-sided max(raw, 0.001) guard.


(:wat::test::make-deftest :deftest
  ((:wat::load-file! "wat/vocab/market/regime.wat")
   (:wat::core::define
     (:test::fresh-regime
       (kama :f64) (vr :f64)
       -> :trading::types::Candle::Regime)
     ;; 8-arg constructor: kama-er, choppiness, dfa-alpha,
     ;; variance-ratio, entropy-rate, aroon-up, aroon-down,
     ;; fractal-dim.
     (:trading::types::Candle::Regime/new
       kama 0.0 0.0 vr 0.0 0.0 0.0 1.0))
   (:wat::core::define
     (:test::empty-scales -> :trading::encoding::Scales)
     (:wat::core::HashMap :(String,trading::encoding::ScaleTracker)))))

;; ─── 1. count — 8 holons emitted ───────────────────────────────

(:deftest :trading::test::vocab::market::regime::test-holons-count
  (:wat::core::let*
    (((r :trading::types::Candle::Regime) (:test::fresh-regime 0.5 1.0))
     ((e :trading::encoding::VocabEmission)
      (:trading::vocab::market::regime::encode-regime-holons
        r (:test::empty-scales)))
     ((holons :wat::holon::Holons) (:wat::core::first e)))
    (:wat::test::assert-eq
      (:wat::core::length holons)
      8)))

;; ─── 2. kama-er shape — fact[0], raw (no normalization) ────────

(:deftest :trading::test::vocab::market::regime::test-kama-er-shape
  (:wat::core::let*
    (((r :trading::types::Candle::Regime) (:test::fresh-regime 0.5 1.0))
     ((e :trading::encoding::VocabEmission)
      (:trading::vocab::market::regime::encode-regime-holons
        r (:test::empty-scales)))
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
        (:wat::holon::Atom "kama-er")
        (:wat::holon::Thermometer rounded neg-scale scale))))
    (:wat::test::assert-eq
      (:wat::holon::coincident? actual expected)
      true)))

;; ─── 3. variance-ratio shape — fact[3], ReciprocalLog 10.0 ─────

(:deftest :trading::test::vocab::market::regime::test-variance-ratio-shape
  (:wat::core::let*
    (((r :trading::types::Candle::Regime) (:test::fresh-regime 0.5 1.5))
     ((e :trading::encoding::VocabEmission)
      (:trading::vocab::market::regime::encode-regime-holons
        r (:test::empty-scales)))
     ((holons :wat::holon::Holons) (:wat::core::first e))
     ;; fact[3] is variance-ratio (order: kama-er, choppiness,
     ;; dfa-alpha, variance-ratio, entropy-rate, aroon-up,
     ;; aroon-down, fractal-dim).
     ((actual :wat::holon::HolonAST)
      (:wat::core::match (:wat::core::get holons 3)
                         -> :wat::holon::HolonAST
        ((Some h) h)
        (:None (:wat::holon::Atom "unreachable"))))

     ;; Expected: Bind(Atom("variance-ratio"), ReciprocalLog 10.0 rounded).
     ;; Raw 1.5 → floor(1.5, 0.001) = 1.5 → round-to-2 = 1.5.
     ((rounded :f64) (:trading::encoding::round-to-2 1.5))
     ((expected :wat::holon::HolonAST)
      (:wat::holon::Bind
        (:wat::holon::Atom "variance-ratio")
        (:wat::holon::ReciprocalLog 10.0 rounded))))
    (:wat::test::assert-eq
      (:wat::holon::coincident? actual expected)
      true)))

;; ─── 4. variance-ratio floor — raw 0.0 encodes as 0.001 ────────

(:deftest :trading::test::vocab::market::regime::test-variance-ratio-floor
  (:wat::core::let*
    (;; Raw vr=0.0 → floored to 0.001 → rounded to 0.00 (since
     ;; round-to-2 of 0.001 = 0.00). Expected matches ReciprocalLog
     ;; of that rounded value.
     ((r :trading::types::Candle::Regime) (:test::fresh-regime 0.5 0.0))
     ((e :trading::encoding::VocabEmission)
      (:trading::vocab::market::regime::encode-regime-holons
        r (:test::empty-scales)))
     ((holons :wat::holon::Holons) (:wat::core::first e))
     ((actual :wat::holon::HolonAST)
      (:wat::core::match (:wat::core::get holons 3)
                         -> :wat::holon::HolonAST
        ((Some h) h)
        (:None (:wat::holon::Atom "unreachable"))))

     ((floored-rounded :f64) (:trading::encoding::round-to-2 0.001))
     ((expected :wat::holon::HolonAST)
      (:wat::holon::Bind
        (:wat::holon::Atom "variance-ratio")
        (:wat::holon::ReciprocalLog 10.0 floored-rounded))))
    (:wat::test::assert-eq
      (:wat::holon::coincident? actual expected)
      true)))

;; ─── 5. scales accumulate 7 entries (variance-ratio bypasses) ──

(:deftest :trading::test::vocab::market::regime::test-scales-accumulate-7-entries
  (:wat::core::let*
    (((r :trading::types::Candle::Regime) (:test::fresh-regime 0.5 1.0))
     ((e :trading::encoding::VocabEmission)
      (:trading::vocab::market::regime::encode-regime-holons
        r (:test::empty-scales)))
     ((updated :trading::encoding::Scales) (:wat::core::second e)))
    ;; 7 scaled-linear atoms → 7 scale entries. variance-ratio
    ;; uses Log (no scales).
    (:wat::test::assert-eq
      (:wat::core::length updated)
      7)))

;; ─── 6. different candles differ — scale-boundary kama-er ──────

(:deftest :trading::test::vocab::market::regime::test-different-candles-differ
  (:wat::core::let*
    ;; Per arc 008's footnote: values across the scale-rounding
    ;; boundary. kama-er 0.1 → scale 0.001 (floor); 0.9 → scale 0.02.
    (((r-a :trading::types::Candle::Regime) (:test::fresh-regime 0.1 1.0))
     ((r-b :trading::types::Candle::Regime) (:test::fresh-regime 0.9 1.0))
     ((e-a :trading::encoding::VocabEmission)
      (:trading::vocab::market::regime::encode-regime-holons
        r-a (:test::empty-scales)))
     ((e-b :trading::encoding::VocabEmission)
      (:trading::vocab::market::regime::encode-regime-holons
        r-b (:test::empty-scales)))
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
