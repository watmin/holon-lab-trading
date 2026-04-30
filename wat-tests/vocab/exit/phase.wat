;; wat-tests/vocab/exit/phase.wat — Lab arc 019.
;;
;; Tests for :trading::vocab::exit::phase. First exit sub-tree
;; vocab; first lab user-enum match consumer (phase-label-name).

(:wat::test::make-deftest :deftest
  ((:wat::load-file! "wat/vocab/exit/phase.wat")

   (:wat::core::define
     (:test::fresh-phase
       (label :trading::types::PhaseLabel)
       (direction :trading::types::PhaseDirection)
       (duration :wat::core::i64)
       -> :trading::types::Candle::Phase)
     (:trading::types::Candle::Phase/new
       label direction duration
       (:wat::core::vec :trading::types::PhaseRecord)))

   (:wat::core::define
     (:test::fresh-record
       (label :trading::types::PhaseLabel)
       (direction :trading::types::PhaseDirection)
       (duration :wat::core::i64)
       (close-min :wat::core::f64) (close-max :wat::core::f64) (close-avg :wat::core::f64)
       -> :trading::types::PhaseRecord)
     (:trading::types::PhaseRecord/new
       label direction 0 0 duration
       close-min close-max close-avg
       0.0 0.0 0.0))

   (:wat::core::define
     (:test::empty-scales -> :trading::encoding::Scales)
     (:wat::core::HashMap :(String,trading::encoding::ScaleTracker)))))

;; ─── phase-label-name: unit variants ───────────────────────────

(:deftest :trading::test::vocab::exit::phase::test-label-name-valley
  (:wat::test::assert-eq
    (:trading::vocab::exit::phase::phase-label-name
      :trading::types::PhaseLabel::Valley
      :trading::types::PhaseDirection::None)
    "valley"))

(:deftest :trading::test::vocab::exit::phase::test-label-name-peak
  (:wat::test::assert-eq
    (:trading::vocab::exit::phase::phase-label-name
      :trading::types::PhaseLabel::Peak
      :trading::types::PhaseDirection::None)
    "peak"))

(:deftest :trading::test::vocab::exit::phase::test-label-name-transition-up
  (:wat::test::assert-eq
    (:trading::vocab::exit::phase::phase-label-name
      :trading::types::PhaseLabel::Transition
      :trading::types::PhaseDirection::Up)
    "transition-up"))

(:deftest :trading::test::vocab::exit::phase::test-label-name-transition-down
  (:wat::test::assert-eq
    (:trading::vocab::exit::phase::phase-label-name
      :trading::types::PhaseLabel::Transition
      :trading::types::PhaseDirection::Down)
    "transition-down"))

(:deftest :trading::test::vocab::exit::phase::test-label-name-transition-none
  (:wat::test::assert-eq
    (:trading::vocab::exit::phase::phase-label-name
      :trading::types::PhaseLabel::Transition
      :trading::types::PhaseDirection::None)
    "transition"))

;; ─── encode-phase-current-holons ───────────────────────────────

(:deftest :trading::test::vocab::exit::phase::test-current-holons-count
  (:wat::core::let*
    (((p :trading::types::Candle::Phase)
      (:test::fresh-phase
        :trading::types::PhaseLabel::Valley
        :trading::types::PhaseDirection::None
        5))
     ((e :trading::encoding::VocabEmission)
      (:trading::vocab::exit::phase::encode-phase-current-holons
        p (:test::empty-scales)))
     ((holons :wat::holon::Holons) (:wat::core::first e)))
    (:wat::test::assert-eq
      (:wat::core::length holons)
      2)))

(:deftest :trading::test::vocab::exit::phase::test-current-holons-label-binding
  (:wat::core::let*
    (((p :trading::types::Candle::Phase)
      (:test::fresh-phase
        :trading::types::PhaseLabel::Peak
        :trading::types::PhaseDirection::None
        3))
     ((e :trading::encoding::VocabEmission)
      (:trading::vocab::exit::phase::encode-phase-current-holons
        p (:test::empty-scales)))
     ((holons :wat::holon::Holons) (:wat::core::first e))
     ((actual :wat::holon::HolonAST)
      (:wat::core::match (:wat::core::get holons 0)
                         -> :wat::holon::HolonAST
        ((Some h) h)
        (:None (:wat::holon::Atom "unreachable"))))
     ((expected :wat::holon::HolonAST)
      (:wat::holon::Bind
        (:wat::holon::Atom "phase")
        (:wat::holon::Atom "peak"))))
    (:wat::test::assert-eq
      (:wat::holon::coincident? actual expected)
      true)))

(:deftest :trading::test::vocab::exit::phase::test-current-transition-up-label
  (:wat::core::let*
    (((p :trading::types::Candle::Phase)
      (:test::fresh-phase
        :trading::types::PhaseLabel::Transition
        :trading::types::PhaseDirection::Up
        7))
     ((e :trading::encoding::VocabEmission)
      (:trading::vocab::exit::phase::encode-phase-current-holons
        p (:test::empty-scales)))
     ((holons :wat::holon::Holons) (:wat::core::first e))
     ((actual :wat::holon::HolonAST)
      (:wat::core::match (:wat::core::get holons 0)
                         -> :wat::holon::HolonAST
        ((Some h) h)
        (:None (:wat::holon::Atom "unreachable"))))
     ((expected :wat::holon::HolonAST)
      (:wat::holon::Bind
        (:wat::holon::Atom "phase")
        (:wat::holon::Atom "transition-up"))))
    (:wat::test::assert-eq
      (:wat::holon::coincident? actual expected)
      true)))

;; ─── encode-phase-scalar-holons ────────────────────────────────

(:deftest :trading::test::vocab::exit::phase::test-scalar-empty-history
  (:wat::core::let*
    (((history :trading::types::PhaseRecords)
      (:wat::core::vec :trading::types::PhaseRecord))
     ((e :trading::encoding::VocabEmission)
      (:trading::vocab::exit::phase::encode-phase-scalar-holons
        history (:test::empty-scales)))
     ((holons :wat::holon::Holons) (:wat::core::first e)))
    (:wat::test::assert-eq
      (:wat::core::length holons)
      0)))

(:deftest :trading::test::vocab::exit::phase::test-scalar-single-record
  (:wat::core::let*
    (((r :trading::types::PhaseRecord)
      (:test::fresh-record
        :trading::types::PhaseLabel::Valley
        :trading::types::PhaseDirection::None
        5 95.0 100.0 97.0))
     ((history :trading::types::PhaseRecords)
      (:wat::core::vec :trading::types::PhaseRecord r))
     ((e :trading::encoding::VocabEmission)
      (:trading::vocab::exit::phase::encode-phase-scalar-holons
        history (:test::empty-scales)))
     ((holons :wat::holon::Holons) (:wat::core::first e)))
    (:wat::test::assert-eq
      (:wat::core::length holons)
      0)))

(:deftest :trading::test::vocab::exit::phase::test-scalar-two-valleys
  ;; Two Valley records + range + spacing preconditions met.
  ;; Expect 3 atoms: valley-trend, range-trend, spacing-trend
  ;; (peak-trend not emitted — 0 peaks).
  (:wat::core::let*
    (((r1 :trading::types::PhaseRecord)
      (:test::fresh-record
        :trading::types::PhaseLabel::Valley
        :trading::types::PhaseDirection::None
        5 95.0 100.0 97.0))
     ((r2 :trading::types::PhaseRecord)
      (:test::fresh-record
        :trading::types::PhaseLabel::Valley
        :trading::types::PhaseDirection::None
        6 100.0 106.0 103.0))
     ((history :trading::types::PhaseRecords)
      (:wat::core::vec :trading::types::PhaseRecord r1 r2))
     ((e :trading::encoding::VocabEmission)
      (:trading::vocab::exit::phase::encode-phase-scalar-holons
        history (:test::empty-scales)))
     ((holons :wat::holon::Holons) (:wat::core::first e)))
    (:wat::test::assert-eq
      (:wat::core::length holons)
      3)))

;; ─── Phase rhythm (arc 020) ────────────────────────────────────

(:deftest :trading::test::vocab::exit::phase::test-rhythm-insufficient-history
  ;; < 4 records returns (Bind (Atom "phase-rhythm")
  ;; (Bundle [(Atom "phase-rhythm-empty")])) — the singleton-
  ;; sentinel from arc 026's empty-Bundle convention.
  (:wat::core::let*
    (((r :trading::types::PhaseRecord)
      (:test::fresh-record
        :trading::types::PhaseLabel::Valley
        :trading::types::PhaseDirection::None
        5 95.0 100.0 97.0))
     ((history :trading::types::PhaseRecords)
      (:wat::core::vec :trading::types::PhaseRecord r r r))
     ((actual :wat::holon::HolonAST)
      (:trading::vocab::exit::phase::phase-rhythm-holon history))
     ((expected :wat::holon::HolonAST)
      (:wat::holon::Bind
        (:wat::holon::Atom "phase-rhythm")
        (:trading::vocab::exit::phase::empty-rhythm-bundle))))
    (:wat::test::assert-eq
      (:wat::holon::coincident? actual expected)
      true)))

(:deftest :trading::test::vocab::exit::phase::test-rhythm-four-records
  ;; Exactly 4 records — produces 2 trigrams, 1 pair, wrapped in
  ;; (Bind (Atom "phase-rhythm") <bundle>). The HolonAST should
  ;; coincide with itself when re-evaluated; just check that the
  ;; result is non-empty (length > 0 substitute via coincident?
  ;; against a known-different empty-bundle).
  (:wat::core::let*
    (((rv :trading::types::PhaseRecord)
      (:test::fresh-record
        :trading::types::PhaseLabel::Valley
        :trading::types::PhaseDirection::None
        5 95.0 100.0 97.0))
     ((rp :trading::types::PhaseRecord)
      (:test::fresh-record
        :trading::types::PhaseLabel::Peak
        :trading::types::PhaseDirection::None
        4 102.0 108.0 105.0))
     ((rtu :trading::types::PhaseRecord)
      (:test::fresh-record
        :trading::types::PhaseLabel::Transition
        :trading::types::PhaseDirection::Up
        2 104.0 109.0 106.0))
     ((rtd :trading::types::PhaseRecord)
      (:test::fresh-record
        :trading::types::PhaseLabel::Transition
        :trading::types::PhaseDirection::Down
        3 100.0 105.0 102.0))
     ((history :trading::types::PhaseRecords)
      (:wat::core::vec :trading::types::PhaseRecord rv rp rtu rtd))
     ((actual :wat::holon::HolonAST)
      (:trading::vocab::exit::phase::phase-rhythm-holon history))
     ;; Compare against the empty-rhythm sentinel (insufficient
     ;; history) — non-empty rhythm should NOT coincide with it.
     ;; Bare `(Bundle empty-vec)` would panic during encoding
     ;; (holon-rs's vector-layer bundle requires non-empty input).
     ((empty-rhythm :wat::holon::HolonAST)
      (:wat::holon::Bind
        (:wat::holon::Atom "phase-rhythm")
        (:trading::vocab::exit::phase::empty-rhythm-bundle))))
    (:wat::test::assert-eq
      (:wat::holon::coincident? actual empty-rhythm)
      false)))

;; ─── same-label-and-direction? predicate ───────────────────────

(:deftest :trading::test::vocab::exit::phase::test-same-valley-valley
  (:wat::core::let*
    (((a :trading::types::PhaseRecord)
      (:test::fresh-record
        :trading::types::PhaseLabel::Valley
        :trading::types::PhaseDirection::None
        5 95.0 100.0 97.0))
     ((b :trading::types::PhaseRecord)
      (:test::fresh-record
        :trading::types::PhaseLabel::Valley
        :trading::types::PhaseDirection::None
        6 100.0 106.0 103.0)))
    (:wat::test::assert-eq
      (:trading::vocab::exit::phase::same-label-and-direction? a b)
      true)))

(:deftest :trading::test::vocab::exit::phase::test-same-valley-peak
  (:wat::core::let*
    (((a :trading::types::PhaseRecord)
      (:test::fresh-record
        :trading::types::PhaseLabel::Valley
        :trading::types::PhaseDirection::None
        5 95.0 100.0 97.0))
     ((b :trading::types::PhaseRecord)
      (:test::fresh-record
        :trading::types::PhaseLabel::Peak
        :trading::types::PhaseDirection::None
        4 102.0 108.0 105.0)))
    (:wat::test::assert-eq
      (:trading::vocab::exit::phase::same-label-and-direction? a b)
      false)))

(:deftest :trading::test::vocab::exit::phase::test-same-transition-up-up
  (:wat::core::let*
    (((a :trading::types::PhaseRecord)
      (:test::fresh-record
        :trading::types::PhaseLabel::Transition
        :trading::types::PhaseDirection::Up
        2 104.0 109.0 106.0))
     ((b :trading::types::PhaseRecord)
      (:test::fresh-record
        :trading::types::PhaseLabel::Transition
        :trading::types::PhaseDirection::Up
        3 110.0 115.0 112.0)))
    (:wat::test::assert-eq
      (:trading::vocab::exit::phase::same-label-and-direction? a b)
      true)))

(:deftest :trading::test::vocab::exit::phase::test-same-transition-up-down
  (:wat::core::let*
    (((a :trading::types::PhaseRecord)
      (:test::fresh-record
        :trading::types::PhaseLabel::Transition
        :trading::types::PhaseDirection::Up
        2 104.0 109.0 106.0))
     ((b :trading::types::PhaseRecord)
      (:test::fresh-record
        :trading::types::PhaseLabel::Transition
        :trading::types::PhaseDirection::Down
        3 100.0 105.0 102.0)))
    (:wat::test::assert-eq
      (:trading::vocab::exit::phase::same-label-and-direction? a b)
      false)))
