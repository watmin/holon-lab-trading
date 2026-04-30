;; wat-tests/vocab/market/divergence.wat — Lab arc 006.
;;
;; Six outstanding tests for :trading::vocab::market::divergence —
;; each anchored in the module's specific claims. Divergence is the
;; first conditional-emission vocab module; tests cover the
;; emission truth table (none / bull-only / bear-only / both) plus
;; shape + no-scales-pollution claims.


(:wat::test::make-deftest :deftest
  ((:wat::load-file! "wat/vocab/market/divergence.wat")
   (:wat::core::define
     (:test::fresh-divergence
       (bull :wat::core::f64) (bear :wat::core::f64)
       -> :trading::types::Candle::Divergence)
     (:trading::types::Candle::Divergence/new
       bull bear 0.0 0.0))  ;; tk-cross-delta, stoch-cross-delta
   (:wat::core::define
     (:test::empty-scales -> :trading::encoding::Scales)
     (:wat::core::HashMap :(String,trading::encoding::ScaleTracker)))))

;; ─── 1. no emit — both inputs zero → empty Holons ──────────────

(:deftest :trading::test::vocab::market::divergence::test-no-emit-when-zero
  (:wat::core::let*
    (((d :trading::types::Candle::Divergence)
      (:test::fresh-divergence 0.0 0.0))
     ((e :trading::encoding::VocabEmission)
      (:trading::vocab::market::divergence::encode-divergence-holons
        d (:test::empty-scales)))
     ((holons :wat::holon::Holons) (:wat::core::first e)))
    (:wat::test::assert-eq
      (:wat::core::length holons)
      0)))

;; ─── 2. bull only — 2 holons (bull + spread) ──────────────────

(:deftest :trading::test::vocab::market::divergence::test-bull-only-emits-two
  (:wat::core::let*
    (((d :trading::types::Candle::Divergence)
      (:test::fresh-divergence 0.5 0.0))
     ((e :trading::encoding::VocabEmission)
      (:trading::vocab::market::divergence::encode-divergence-holons
        d (:test::empty-scales)))
     ((holons :wat::holon::Holons) (:wat::core::first e)))
    (:wat::test::assert-eq
      (:wat::core::length holons)
      2)))

;; ─── 3. bear only — 2 holons (bear + spread) ──────────────────

(:deftest :trading::test::vocab::market::divergence::test-bear-only-emits-two
  (:wat::core::let*
    (((d :trading::types::Candle::Divergence)
      (:test::fresh-divergence 0.0 0.4))
     ((e :trading::encoding::VocabEmission)
      (:trading::vocab::market::divergence::encode-divergence-holons
        d (:test::empty-scales)))
     ((holons :wat::holon::Holons) (:wat::core::first e)))
    (:wat::test::assert-eq
      (:wat::core::length holons)
      2)))

;; ─── 4. both — 3 holons (bull + bear + spread) ───────────────

(:deftest :trading::test::vocab::market::divergence::test-both-emit-three
  (:wat::core::let*
    (((d :trading::types::Candle::Divergence)
      (:test::fresh-divergence 0.5 0.3))
     ((e :trading::encoding::VocabEmission)
      (:trading::vocab::market::divergence::encode-divergence-holons
        d (:test::empty-scales)))
     ((holons :wat::holon::Holons) (:wat::core::first e)))
    (:wat::test::assert-eq
      (:wat::core::length holons)
      3)))

;; ─── 5. bull holon shape — coincides with hand-built form ────

(:deftest :trading::test::vocab::market::divergence::test-bull-holon-shape
  (:wat::core::let*
    (((d :trading::types::Candle::Divergence)
      (:test::fresh-divergence 0.5 0.0))
     ((e :trading::encoding::VocabEmission)
      (:trading::vocab::market::divergence::encode-divergence-holons
        d (:test::empty-scales)))
     ((holons :wat::holon::Holons) (:wat::core::first e))
     ;; fact[0] is rsi-divergence-bull (the first emitted atom).
     ((actual :wat::holon::HolonAST)
      (:wat::core::match (:wat::core::get holons 0)
                         -> :wat::holon::HolonAST
        ((Some h) h)
        (:None (:wat::holon::Atom "unreachable"))))

     ;; Expected shape: Bind(Atom("rsi-divergence-bull"),
     ;;                      Thermometer(0.5, -scale, scale))
     ;; Scale comes from fresh tracker's first update with value 0.5.
     ((expected-tracker :trading::encoding::ScaleTracker)
      (:trading::encoding::ScaleTracker::update
        (:trading::encoding::ScaleTracker::fresh) 0.5))
     ((scale :wat::core::f64)
      (:trading::encoding::ScaleTracker::scale expected-tracker))
     ((neg-scale :wat::core::f64) (:wat::core::- 0.0 scale))
     ((rounded :wat::core::f64) (:trading::encoding::round-to-2 0.5))
     ((expected :wat::holon::HolonAST)
      (:wat::holon::Bind
        (:wat::holon::Atom "rsi-divergence-bull")
        (:wat::holon::Thermometer rounded neg-scale scale))))
    (:wat::test::assert-eq
      (:wat::holon::coincident? actual expected)
      true)))

;; ─── 6. no-emit leaves scales empty ──────────────────────────

(:deftest :trading::test::vocab::market::divergence::test-no-emit-preserves-scales
  (:wat::core::let*
    (((d :trading::types::Candle::Divergence)
      (:test::fresh-divergence 0.0 0.0))
     ((e :trading::encoding::VocabEmission)
      (:trading::vocab::market::divergence::encode-divergence-holons
        d (:test::empty-scales)))
     ((updated :trading::encoding::Scales) (:wat::core::second e))
     ;; No emissions fired → no scales updates → none of the atom
     ;; names should be present in the returned Scales.
     ((has-bull   :wat::core::bool) (:wat::core::contains? updated "rsi-divergence-bull"))
     ((has-bear   :wat::core::bool) (:wat::core::contains? updated "rsi-divergence-bear"))
     ((has-spread :wat::core::bool) (:wat::core::contains? updated "divergence-spread")))
    (:wat::test::assert-eq
      (:wat::core::or has-bull (:wat::core::or has-bear has-spread))
      false)))
