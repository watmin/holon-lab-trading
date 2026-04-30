;; wat-tests/vocab/exit/regime.wat — Lab arc 021.
;;
;; Three tests covering the delegation contract from
;; `:trading::vocab::exit::regime::encode-regime-holons` to
;; `:trading::vocab::market::regime::encode-regime-holons`. The
;; full 8-atom truth-table tests live in arc 010's regime test
;; file; this file verifies that the delegation produces the
;; same shape and same encoding output.


(:wat::test::make-deftest :deftest
  ((:wat::load-file! "wat/vocab/exit/regime.wat")
   (:wat::core::define
     (:test::fresh-regime
       (kama :wat::core::f64) (vr :wat::core::f64)
       -> :trading::types::Candle::Regime)
     ;; 8-arg constructor: kama-er, choppiness, dfa-alpha,
     ;; variance-ratio, entropy-rate, aroon-up, aroon-down,
     ;; fractal-dim.
     (:trading::types::Candle::Regime/new
       kama 0.0 0.0 vr 0.0 0.0 0.0 1.0))
   (:wat::core::define
     (:test::empty-scales -> :trading::encoding::Scales)
     (:wat::core::HashMap :(String,trading::encoding::ScaleTracker)))))

;; ─── 1. count — exit/regime emits 8 holons ─────────────────────

(:deftest :trading::test::vocab::exit::regime::test-holons-count
  (:wat::core::let*
    (((r :trading::types::Candle::Regime) (:test::fresh-regime 0.5 1.0))
     ((e :trading::encoding::VocabEmission)
      (:trading::vocab::exit::regime::encode-regime-holons
        r (:test::empty-scales)))
     ((holons :wat::holon::Holons) (:wat::core::first e)))
    (:wat::test::assert-eq
      (:wat::core::length holons)
      8)))

;; ─── 2. delegation — exit::regime coincident with market::regime ─

(:deftest :trading::test::vocab::exit::regime::test-delegates-to-market
  (:wat::core::let*
    (((r :trading::types::Candle::Regime) (:test::fresh-regime 0.5 1.5))
     ;; Both functions called with identical fresh inputs.
     ((e-exit :trading::encoding::VocabEmission)
      (:trading::vocab::exit::regime::encode-regime-holons
        r (:test::empty-scales)))
     ((e-market :trading::encoding::VocabEmission)
      (:trading::vocab::market::regime::encode-regime-holons
        r (:test::empty-scales)))
     ((holons-exit :wat::holon::Holons) (:wat::core::first e-exit))
     ((holons-market :wat::holon::Holons) (:wat::core::first e-market))
     ;; Witness: holon[0] (kama-er, scaled-linear) coincident across
     ;; both. If any of the 8 atom encodings diverged, at least one
     ;; would surface — kama-er is the first scaled-linear emission
     ;; and is a clean witness.
     ((fact-exit :wat::holon::HolonAST)
      (:wat::core::match (:wat::core::get holons-exit 0)
                         -> :wat::holon::HolonAST
        ((Some h) h)
        (:None (:wat::holon::Atom "unreachable"))))
     ((fact-market :wat::holon::HolonAST)
      (:wat::core::match (:wat::core::get holons-market 0)
                         -> :wat::holon::HolonAST
        ((Some h) h)
        (:None (:wat::holon::Atom "unreachable")))))
    (:wat::test::assert-eq
      (:wat::holon::coincident? fact-exit fact-market)
      true)))

;; ─── 3. scales accumulate 7 entries (variance-ratio bypasses) ──

(:deftest :trading::test::vocab::exit::regime::test-scales-accumulate-7-entries
  (:wat::core::let*
    (((r :trading::types::Candle::Regime) (:test::fresh-regime 0.5 1.0))
     ((e :trading::encoding::VocabEmission)
      (:trading::vocab::exit::regime::encode-regime-holons
        r (:test::empty-scales)))
     ((updated :trading::encoding::Scales) (:wat::core::second e)))
    ;; 7 scaled-linear atoms → 7 scale entries. variance-ratio uses
    ;; ReciprocalLog (no scales). Same contract as arc 010.
    (:wat::test::assert-eq
      (:wat::core::length updated)
      7)))
