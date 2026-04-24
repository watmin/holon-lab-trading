;; wat-tests/vocab/market/oscillators.wat — Lab arc 005.
;;
;; Five outstanding tests for :trading::vocab::market::oscillators —
;; anchored in the module's specific claims:
;;
;; 1. count — returns 8 holons.
;; 2. rsi holon shape — fact[0] coincides with hand-built
;;    Bind(Atom("rsi"), Thermometer(rsi, -scale, scale)).
;; 3. roc-1 holon shape — fact[4] coincides with hand-built
;;    Bind(Atom("roc-1"), Log(value, 0.5, 2.0)) via ReciprocalLog.
;; 4. scales-accumulate — updated Scales has 4 entries after one
;;    call (rsi, cci, mfi, williams-r).
;; 5. different candles differ — two distinct inputs encode to
;;    non-coincident holons at the scaled-linear positions.

(:wat::config::set-capacity-mode! :error)
(:wat::config::set-dims! 1024)

;; Default-prelude owns the load chain AND the test helpers. Arc 003
;; established this pattern — sandbox-local defines spliced into
;; every test freeze. Helpers reference :Scales and sub-struct
;; constructors from oscillators' dep chain, which the load brings in.
(:wat::test::make-deftest :deftest
  ((:wat::load-file! "wat/vocab/market/oscillators.wat")
   (:wat::core::define
     (:test::fresh-momentum
       (rsi :f64) (williams-r :f64) (cci :f64) (mfi :f64)
       -> :trading::types::Candle::Momentum)
     (:trading::types::Candle::Momentum/new
       rsi          ;; rsi
       0.0          ;; macd-hist
       0.0          ;; plus-di
       0.0          ;; minus-di
       0.0          ;; adx
       0.0          ;; stoch-k
       0.0          ;; stoch-d
       williams-r   ;; williams-r
       cci          ;; cci
       mfi          ;; mfi
       0.0          ;; obv-slope-12
       0.0))        ;; volume-accel
   (:wat::core::define
     (:test::fresh-roc
       (r1 :f64) (r3 :f64) (r6 :f64) (r12 :f64)
       -> :trading::types::Candle::RateOfChange)
     (:trading::types::Candle::RateOfChange/new
       r1 r3 r6 r12
       0.0 0.0 0.0))  ;; range-pos-12/24/48
   (:wat::core::define
     (:test::empty-scales -> :trading::encoding::Scales)
     (:wat::core::HashMap :(String,trading::encoding::ScaleTracker)))))

;; ─── 1. count ─────────────────────────────────────────────────

(:deftest :trading::test::vocab::market::oscillators::test-count
  (:wat::core::let*
    (((m :trading::types::Candle::Momentum)
      (:test::fresh-momentum 55.0 -30.0 50.0 60.0))
     ((r :trading::types::Candle::RateOfChange)
      (:test::fresh-roc 0.01 0.03 0.06 0.12))
     ((emission :trading::encoding::VocabEmission)
      (:trading::vocab::market::oscillators::encode-oscillators-holons
        m r (:test::empty-scales)))
     ((holons :wat::holon::Holons) (:wat::core::first emission)))
    (:wat::test::assert-eq
      (:wat::core::length holons)
      8)))

;; ─── 2. rsi holon shape ──────────────────────────────────────
;;
;; fact[0] is the rsi emission from scaled-linear, which produces
;; Bind(Atom("rsi"), Thermometer(round-to-2(rsi), -scale, scale))
;; where scale comes from the tracker after one update.

(:deftest :trading::test::vocab::market::oscillators::test-rsi-holon-shape
  (:wat::core::let*
    (((m :trading::types::Candle::Momentum)
      (:test::fresh-momentum 55.0 -30.0 50.0 60.0))
     ((r :trading::types::Candle::RateOfChange)
      (:test::fresh-roc 0.01 0.03 0.06 0.12))
     ((emission :trading::encoding::VocabEmission)
      (:trading::vocab::market::oscillators::encode-oscillators-holons
        m r (:test::empty-scales)))
     ((holons :wat::holon::Holons) (:wat::core::first emission))
     ((actual :wat::holon::HolonAST)
      (:wat::core::match (:wat::core::get holons 0)
                         -> :wat::holon::HolonAST
        ((Some h) h)
        (:None (:wat::holon::Atom "unreachable"))))

     ;; Compute the expected shape the same way scaled-linear does:
     ;; reconstruct the tracker's post-update scale, build by hand.
     ((expected-tracker :trading::encoding::ScaleTracker)
      (:trading::encoding::ScaleTracker::update
        (:trading::encoding::ScaleTracker::fresh) 55.0))
     ((scale :f64)
      (:trading::encoding::ScaleTracker::scale expected-tracker))
     ((neg-scale :f64) (:wat::core::f64::- 0.0 scale))
     ((rounded-rsi :f64) (:trading::encoding::round-to-2 55.0))
     ((expected :wat::holon::HolonAST)
      (:wat::holon::Bind
        (:wat::holon::Atom "rsi")
        (:wat::holon::Thermometer rounded-rsi neg-scale scale))))
    (:wat::test::assert-eq
      (:wat::holon::coincident? actual expected)
      true)))

;; ─── 3. roc-1 holon shape via ReciprocalLog ─────────────────

(:deftest :trading::test::vocab::market::oscillators::test-roc-1-holon-shape
  (:wat::core::let*
    (((m :trading::types::Candle::Momentum)
      (:test::fresh-momentum 55.0 -30.0 50.0 60.0))
     ((r :trading::types::Candle::RateOfChange)
      (:test::fresh-roc 0.05 0.03 0.06 0.12))  ;; roc-1 = 0.05
     ((emission :trading::encoding::VocabEmission)
      (:trading::vocab::market::oscillators::encode-oscillators-holons
        m r (:test::empty-scales)))
     ((holons :wat::holon::Holons) (:wat::core::first emission))
     ;; fact[4] is roc-1 (positions 0-3 are rsi/cci/mfi/williams-r)
     ((actual :wat::holon::HolonAST)
      (:wat::core::match (:wat::core::get holons 4)
                         -> :wat::holon::HolonAST
        ((Some h) h)
        (:None (:wat::holon::Atom "unreachable"))))
     ;; Expected: 1.0 + 0.05 = 1.05, round-to-2 → 1.05
     ((rounded-roc :f64) (:trading::encoding::round-to-2 1.05))
     ((expected :wat::holon::HolonAST)
      (:wat::holon::Bind
        (:wat::holon::Atom "roc-1")
        (:wat::holon::ReciprocalLog 2.0 rounded-roc))))
    (:wat::test::assert-eq
      (:wat::holon::coincident? actual expected)
      true)))

;; ─── 4. scales accumulate four entries ──────────────────────

(:deftest :trading::test::vocab::market::oscillators::test-scales-accumulate-four-entries
  (:wat::core::let*
    (((m :trading::types::Candle::Momentum)
      (:test::fresh-momentum 55.0 -30.0 50.0 60.0))
     ((r :trading::types::Candle::RateOfChange)
      (:test::fresh-roc 0.01 0.03 0.06 0.12))
     ((emission :trading::encoding::VocabEmission)
      (:trading::vocab::market::oscillators::encode-oscillators-holons
        m r (:test::empty-scales)))
     ((updated :trading::encoding::Scales) (:wat::core::second emission))
     ((has-rsi   :bool) (:wat::core::contains? updated "rsi"))
     ((has-cci   :bool) (:wat::core::contains? updated "cci"))
     ((has-mfi   :bool) (:wat::core::contains? updated "mfi"))
     ((has-will  :bool) (:wat::core::contains? updated "williams-r")))
    (:wat::test::assert-eq
      (:wat::core::and
        (:wat::core::and has-rsi   has-cci)
        (:wat::core::and has-mfi   has-will))
      true)))

;; ─── 5. different candles produce different holons ─────────

(:deftest :trading::test::vocab::market::oscillators::test-different-candles-differ
  ;; Two candles with distinct ROC-1 values should produce non-
  ;; coincident ROC-1 encodings. ROC atoms use ReciprocalLog with
  ;; fixed bounds (0.5, 2.0) — a single-call scaled-linear
  ;; comparison would saturate trivially with fresh scales, but
  ;; ReciprocalLog's bounds give meaningful gradient per arc 034's
  ;; exploration (0.9 → 0.95 coincident; 0.9 → 1.2 distinct).
  (:wat::core::let*
    (((m :trading::types::Candle::Momentum)
      (:test::fresh-momentum 55.0 -30.0 50.0 60.0))
     ;; ROC-1 = -0.10 → value 0.90; ROC-1 = +0.20 → value 1.20.
     ;; At (0.5, 2.0) bounds these sit at distinct gradient
     ;; positions and don't coincide.
     ((ra :trading::types::Candle::RateOfChange)
      (:test::fresh-roc -0.10 0.0 0.0 0.0))
     ((rb :trading::types::Candle::RateOfChange)
      (:test::fresh-roc  0.20 0.0 0.0 0.0))

     ((ea :trading::encoding::VocabEmission)
      (:trading::vocab::market::oscillators::encode-oscillators-holons
        m ra (:test::empty-scales)))
     ((eb :trading::encoding::VocabEmission)
      (:trading::vocab::market::oscillators::encode-oscillators-holons
        m rb (:test::empty-scales)))
     ((ha :wat::holon::Holons) (:wat::core::first ea))
     ((hb :wat::holon::Holons) (:wat::core::first eb))
     ;; fact[4] is the ROC-1 atom (positions 0-3 are scaled-linear).
     ((roc-a :wat::holon::HolonAST)
      (:wat::core::match (:wat::core::get ha 4)
                         -> :wat::holon::HolonAST
        ((Some h) h)
        (:None (:wat::holon::Atom "unreachable"))))
     ((roc-b :wat::holon::HolonAST)
      (:wat::core::match (:wat::core::get hb 4)
                         -> :wat::holon::HolonAST
        ((Some h) h)
        (:None (:wat::holon::Atom "unreachable")))))
    (:wat::test::assert-eq
      (:wat::holon::coincident? roc-a roc-b)
      false)))
