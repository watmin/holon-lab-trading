;; wat-tests/vocab/market/persistence.wat — Lab arc 008.
;;
;; Five tests for :trading::vocab::market::persistence — count,
;; two shape checks (one per sub-struct source), scales
;; accumulation, and distinguishability. First cross-sub-struct
;; module — exercises the signature rule from task #49:
;; alphabetical-by-type parameter order.


(:wat::test::make-deftest :deftest
  ((:wat::load-file! "wat/vocab/market/persistence.wat")
   (:wat::core::define
     (:test::fresh-momentum
       (adx :f64)
       -> :trading::types::Candle::Momentum)
     (:trading::types::Candle::Momentum/new
       0.0 0.0 0.0 0.0    ;; rsi, macd-hist, plus-di, minus-di
       adx                ;; adx (position 5)
       0.0 0.0 0.0        ;; stoch-k, stoch-d, williams-r
       0.0 0.0 0.0 0.0))  ;; cci, mfi, obv-slope-12, volume-accel
   (:wat::core::define
     (:test::fresh-persistence
       (hurst :f64) (autocorr :f64)
       -> :trading::types::Candle::Persistence)
     (:trading::types::Candle::Persistence/new
       hurst autocorr 0.0))  ;; hurst, autocorrelation, vwap-distance
   (:wat::core::define
     (:test::empty-scales -> :trading::encoding::Scales)
     (:wat::core::HashMap :(String,trading::encoding::ScaleTracker)))))

;; ─── 1. count — 3 holons emitted ───────────────────────────────

(:deftest :trading::test::vocab::market::persistence::test-holons-count
  (:wat::core::let*
    (((m :trading::types::Candle::Momentum) (:test::fresh-momentum 50.0))
     ((p :trading::types::Candle::Persistence) (:test::fresh-persistence 0.5 0.3))
     ((e :trading::encoding::VocabEmission)
      (:trading::vocab::market::persistence::encode-persistence-holons
        m p (:test::empty-scales)))
     ((holons :wat::holon::Holons) (:wat::core::first e)))
    (:wat::test::assert-eq
      (:wat::core::length holons)
      3)))

;; ─── 2. hurst shape — fact[0] from Persistence sub-struct ──────

(:deftest :trading::test::vocab::market::persistence::test-hurst-shape
  (:wat::core::let*
    (((m :trading::types::Candle::Momentum) (:test::fresh-momentum 50.0))
     ((p :trading::types::Candle::Persistence) (:test::fresh-persistence 0.5 0.3))
     ((e :trading::encoding::VocabEmission)
      (:trading::vocab::market::persistence::encode-persistence-holons
        m p (:test::empty-scales)))
     ((holons :wat::holon::Holons) (:wat::core::first e))
     ((actual :wat::holon::HolonAST)
      (:wat::core::match (:wat::core::get holons 0)
                         -> :wat::holon::HolonAST
        ((Some h) h)
        (:None (:wat::holon::Atom "unreachable"))))

     ((expected-tracker :trading::encoding::ScaleTracker)
      (:trading::encoding::ScaleTracker::update
        (:trading::encoding::ScaleTracker::fresh) 0.5))
     ((scale :f64)
      (:trading::encoding::ScaleTracker::scale expected-tracker))
     ((neg-scale :f64) (:wat::core::f64::- 0.0 scale))
     ((rounded :f64) (:trading::encoding::round-to-2 0.5))
     ((expected :wat::holon::HolonAST)
      (:wat::holon::Bind
        (:wat::holon::Atom "hurst")
        (:wat::holon::Thermometer rounded neg-scale scale))))
    (:wat::test::assert-eq
      (:wat::holon::coincident? actual expected)
      true)))

;; ─── 3. adx shape — fact[2] from Momentum sub-struct (/ 100) ──

(:deftest :trading::test::vocab::market::persistence::test-adx-shape
  (:wat::core::let*
    (;; adx=50 → normalized 50/100 = 0.5 → round-to-2 = 0.5
     ((m :trading::types::Candle::Momentum) (:test::fresh-momentum 50.0))
     ((p :trading::types::Candle::Persistence) (:test::fresh-persistence 0.5 0.3))
     ((e :trading::encoding::VocabEmission)
      (:trading::vocab::market::persistence::encode-persistence-holons
        m p (:test::empty-scales)))
     ((holons :wat::holon::Holons) (:wat::core::first e))
     ;; fact[2] is adx (order: hurst, autocorrelation, adx).
     ((actual :wat::holon::HolonAST)
      (:wat::core::match (:wat::core::get holons 2)
                         -> :wat::holon::HolonAST
        ((Some h) h)
        (:None (:wat::holon::Atom "unreachable"))))

     ((rounded :f64) (:trading::encoding::round-to-2 0.5))
     ((expected-tracker :trading::encoding::ScaleTracker)
      (:trading::encoding::ScaleTracker::update
        (:trading::encoding::ScaleTracker::fresh) rounded))
     ((scale :f64)
      (:trading::encoding::ScaleTracker::scale expected-tracker))
     ((neg-scale :f64) (:wat::core::f64::- 0.0 scale))
     ((expected :wat::holon::HolonAST)
      (:wat::holon::Bind
        (:wat::holon::Atom "adx")
        (:wat::holon::Thermometer rounded neg-scale scale))))
    (:wat::test::assert-eq
      (:wat::holon::coincident? actual expected)
      true)))

;; ─── 4. scales accumulate 3 entries after one call ─────────────

(:deftest :trading::test::vocab::market::persistence::test-scales-accumulate-3-entries
  (:wat::core::let*
    (((m :trading::types::Candle::Momentum) (:test::fresh-momentum 50.0))
     ((p :trading::types::Candle::Persistence) (:test::fresh-persistence 0.5 0.3))
     ((e :trading::encoding::VocabEmission)
      (:trading::vocab::market::persistence::encode-persistence-holons
        m p (:test::empty-scales)))
     ((updated :trading::encoding::Scales) (:wat::core::second e)))
    (:wat::test::assert-eq
      (:wat::core::length updated)
      3)))

;; ─── 5. different candles differ ───────────────────────────────

(:deftest :trading::test::vocab::market::persistence::test-different-candles-differ
  (:wat::core::let*
    ;; Values chosen so the first-call ScaleTracker rounding lands
    ;; on different scales: V=0.1 → scale=0.001 (floored), V=0.9 →
    ;; scale=0.02. Same-scale values (e.g. 0.3 vs 0.7 both round to
    ;; 0.01) would produce coincident Thermometer encodings because
    ;; both saturate identically. Mirrors arc 007 fibonacci's shape.
    (((m-a :trading::types::Candle::Momentum) (:test::fresh-momentum 10.0))
     ((p-a :trading::types::Candle::Persistence) (:test::fresh-persistence 0.1 0.05))
     ((m-b :trading::types::Candle::Momentum) (:test::fresh-momentum 90.0))
     ((p-b :trading::types::Candle::Persistence) (:test::fresh-persistence 0.9 0.7))
     ((e-a :trading::encoding::VocabEmission)
      (:trading::vocab::market::persistence::encode-persistence-holons
        m-a p-a (:test::empty-scales)))
     ((e-b :trading::encoding::VocabEmission)
      (:trading::vocab::market::persistence::encode-persistence-holons
        m-b p-b (:test::empty-scales)))
     ((holons-a :wat::holon::Holons) (:wat::core::first e-a))
     ((holons-b :wat::holon::Holons) (:wat::core::first e-b))
     ;; Compare fact[0] (hurst) — distinct inputs → distinct
     ;; rounded atoms via scaled-linear.
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
