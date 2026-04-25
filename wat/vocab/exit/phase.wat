;; wat/vocab/exit/phase.wat — Phase 2.16 (lab arc 019).
;;
;; Port of archived/pre-wat-native/src/vocab/exit/phase.rs (348L).
;; Ships TWO of three archive functions: current-facts + scalar-facts.
;; The third (phase-rhythm) defers to arc 020 — stateful 5-way-index
;; iteration + bigrams-of-trigrams + budget truncation is its own
;; arc's worth of work.
;;
;; FIRST EXIT SUB-TREE VOCAB. First lab code to exercise arc 048's
;; user-enum match outside the wat-rs test suite — the
;; `phase-label-name` helper dispatches on `PhaseLabel` +
;; `PhaseDirection` via nested match.
;;
;; Three entries here:
;;   phase-label-name            — helper: PhaseLabel × PhaseDirection → String
;;   encode-phase-current-holons — 2 atoms (label binding + duration)
;;   encode-phase-scalar-holons  — up to 4 atoms (trend ratios), conditional

(:wat::load-file! "../../types/candle.wat")
(:wat::load-file! "../../types/pivot.wat")
(:wat::load-file! "../../encoding/round.wat")
(:wat::load-file! "../../encoding/scale-tracker.wat")
(:wat::load-file! "../../encoding/scaled-linear.wat")

;; ─── phase-label-name ──────────────────────────────────────────
;;
;; Nested user-enum match per arc 048. PhaseLabel's Valley + Peak
;; map to single strings; Transition further-dispatches on
;; PhaseDirection.

(:wat::core::define
  (:trading::vocab::exit::phase::phase-label-name
    (label :trading::types::PhaseLabel)
    (direction :trading::types::PhaseDirection)
    -> :String)
  (:wat::core::match label -> :String
    (:trading::types::PhaseLabel::Valley "valley")
    (:trading::types::PhaseLabel::Peak   "peak")
    (:trading::types::PhaseLabel::Transition
      (:wat::core::match direction -> :String
        (:trading::types::PhaseDirection::Up   "transition-up")
        (:trading::types::PhaseDirection::Down "transition-down")
        (:trading::types::PhaseDirection::None "transition")))))

;; ─── encode-phase-current-holons ───────────────────────────────
;;
;; 2 atoms: the phase-label binding + phase-duration scaled-linear.
;; The label binding is NOT scaled-linear — it's a nominal Bind to
;; a name-atom (no scale tracking). Duration converts i64 → f64 for
;; scaled-linear's f64 input.

(:wat::core::define
  (:trading::vocab::exit::phase::encode-phase-current-holons
    (p :trading::types::Candle::Phase)
    (scales :trading::encoding::Scales)
    -> :trading::encoding::VocabEmission)
  (:wat::core::let*
    (((label :trading::types::PhaseLabel)
      (:trading::types::Candle::Phase/label p))
     ((direction :trading::types::PhaseDirection)
      (:trading::types::Candle::Phase/direction p))
     ((duration-i64 :i64) (:trading::types::Candle::Phase/duration p))
     ((duration :f64) (:wat::core::i64::to-f64 duration-i64))

     ;; Fact 0 — label binding.
     ((name :String)
      (:trading::vocab::exit::phase::phase-label-name label direction))
     ((h1 :wat::holon::HolonAST)
      (:wat::holon::Bind
        (:wat::holon::Atom "phase")
        (:wat::holon::Atom name)))

     ;; Fact 1 — phase-duration scaled-linear.
     ((e2 :trading::encoding::ScaleEmission)
      (:trading::encoding::scaled-linear "phase-duration" duration scales))
     ((h2 :wat::holon::HolonAST) (:wat::core::first e2))
     ((s2 :trading::encoding::Scales) (:wat::core::second e2))

     ((holons :wat::holon::Holons)
      (:wat::core::vec :wat::holon::HolonAST h1 h2)))
    (:wat::core::tuple holons s2)))

;; ─── encode-phase-scalar-holons ────────────────────────────────
;;
;; Up to 4 atoms, each CONDITIONALLY emitted. Threads a single
;; (holons, scales) accumulator through four conj-or-skip steps.
;;
;;   phase-valley-trend   — if ≥ 2 Valley records (round-to-4)
;;   phase-peak-trend     — if ≥ 2 Peak records (round-to-4)
;;   phase-range-trend    — if ≥ 2 records + prev-range > 0 (round-to-2)
;;   phase-spacing-trend  — if ≥ 2 records + prev-duration > 0 (round-to-2)
;;
;; Early return (zero holons) if history has < 2 records — none of
;; the trends are computable.

(:wat::core::define
  (:trading::vocab::exit::phase::encode-phase-scalar-holons
    (history :Vec<trading::types::PhaseRecord>)
    (scales :trading::encoding::Scales)
    -> :trading::encoding::VocabEmission)
  (:wat::core::if
    (:wat::core::< (:wat::core::length history) 2) -> :trading::encoding::VocabEmission
    (:wat::core::tuple
      (:wat::core::vec :wat::holon::HolonAST)
      scales)
    (:wat::core::let*
      (;; Fetch last + second-to-last records once — used by range +
       ;; spacing trends directly, and by the helper for valley/peak.
       ((n :i64) (:wat::core::length history))
       ((last-rec :trading::types::PhaseRecord)
        (:wat::core::match (:wat::core::last history)
                           -> :trading::types::PhaseRecord
          ((Some r) r)
          (:None (:trading::vocab::exit::phase::default-record))))
       ((prev-rec :trading::types::PhaseRecord)
        (:wat::core::match (:wat::core::get history (:wat::core::i64::- n 2))
                           -> :trading::types::PhaseRecord
          ((Some r) r)
          (:None (:trading::vocab::exit::phase::default-record))))

       ;; Filter valleys / peaks from history.
       ((valleys :Vec<trading::types::PhaseRecord>)
        (:wat::core::filter history
          (:wat::core::lambda ((r :trading::types::PhaseRecord) -> :bool)
            (:trading::vocab::exit::phase::is-valley? r))))
       ((peaks :Vec<trading::types::PhaseRecord>)
        (:wat::core::filter history
          (:wat::core::lambda ((r :trading::types::PhaseRecord) -> :bool)
            (:trading::vocab::exit::phase::is-peak? r))))

       ;; ─── Thread a (holons, scales) accumulator through four
       ;; conj-or-skip steps.
       ((acc0 :trading::encoding::VocabEmission)
        (:wat::core::tuple
          (:wat::core::vec :wat::holon::HolonAST)
          scales))

       ;; Step 1: valley trend.
       ((acc1 :trading::encoding::VocabEmission)
        (:wat::core::if (:wat::core::>= (:wat::core::length valleys) 2)
                        -> :trading::encoding::VocabEmission
          (:trading::vocab::exit::phase::append-close-avg-trend
            acc0 valleys "phase-valley-trend")
          acc0))

       ;; Step 2: peak trend.
       ((acc2 :trading::encoding::VocabEmission)
        (:wat::core::if (:wat::core::>= (:wat::core::length peaks) 2)
                        -> :trading::encoding::VocabEmission
          (:trading::vocab::exit::phase::append-close-avg-trend
            acc1 peaks "phase-peak-trend")
          acc1))

       ;; Step 3: range trend.
       ((last-range :f64)
        (:wat::core::f64::-
          (:trading::types::PhaseRecord/close-max last-rec)
          (:trading::types::PhaseRecord/close-min last-rec)))
       ((prev-range :f64)
        (:wat::core::f64::-
          (:trading::types::PhaseRecord/close-max prev-rec)
          (:trading::types::PhaseRecord/close-min prev-rec)))
       ((acc3 :trading::encoding::VocabEmission)
        (:wat::core::if (:wat::core::> prev-range 0.0)
                        -> :trading::encoding::VocabEmission
          (:trading::vocab::exit::phase::append-ratio-round-2
            acc2 "phase-range-trend"
            (:wat::core::f64::/ last-range prev-range))
          acc2))

       ;; Step 4: spacing trend.
       ((last-duration :f64)
        (:wat::core::i64::to-f64
          (:trading::types::PhaseRecord/duration last-rec)))
       ((prev-duration :f64)
        (:wat::core::i64::to-f64
          (:trading::types::PhaseRecord/duration prev-rec)))
       ((acc4 :trading::encoding::VocabEmission)
        (:wat::core::if (:wat::core::> prev-duration 0.0)
                        -> :trading::encoding::VocabEmission
          (:trading::vocab::exit::phase::append-ratio-round-2
            acc3 "phase-spacing-trend"
            (:wat::core::f64::/ last-duration prev-duration))
          acc3)))
      acc4)))

;; ─── Internal helpers ──────────────────────────────────────────

;; is-valley? / is-peak? — label predicates for the filter.
;; Transition records return false in both.
(:wat::core::define
  (:trading::vocab::exit::phase::is-valley?
    (r :trading::types::PhaseRecord)
    -> :bool)
  (:wat::core::match (:trading::types::PhaseRecord/label r) -> :bool
    (:trading::types::PhaseLabel::Valley     true)
    (:trading::types::PhaseLabel::Peak       false)
    (:trading::types::PhaseLabel::Transition false)))

(:wat::core::define
  (:trading::vocab::exit::phase::is-peak?
    (r :trading::types::PhaseRecord)
    -> :bool)
  (:wat::core::match (:trading::types::PhaseRecord/label r) -> :bool
    (:trading::types::PhaseLabel::Peak       true)
    (:trading::types::PhaseLabel::Valley     false)
    (:trading::types::PhaseLabel::Transition false)))

;; append-close-avg-trend — compute valley-trend / peak-trend shape.
;; Takes the accumulator's current (holons, scales), the filtered
;; records (≥ 2 by caller's guard), and the atom name. Appends a
;; new holon + updates scales; if prev.close-avg ≤ 0 the trend is
;; undefined and the accumulator passes through unchanged.
(:wat::core::define
  (:trading::vocab::exit::phase::append-close-avg-trend
    (acc :trading::encoding::VocabEmission)
    (records :Vec<trading::types::PhaseRecord>)
    (name :String)
    -> :trading::encoding::VocabEmission)
  (:wat::core::let*
    (((n :i64) (:wat::core::length records))
     ((last-rec :trading::types::PhaseRecord)
      (:wat::core::match (:wat::core::last records)
                         -> :trading::types::PhaseRecord
        ((Some r) r)
        (:None (:trading::vocab::exit::phase::default-record))))
     ((prev-rec :trading::types::PhaseRecord)
      (:wat::core::match (:wat::core::get records (:wat::core::i64::- n 2))
                         -> :trading::types::PhaseRecord
        ((Some r) r)
        (:None (:trading::vocab::exit::phase::default-record))))
     ((prev-avg :f64) (:trading::types::PhaseRecord/close-avg prev-rec)))
    (:wat::core::if (:wat::core::> prev-avg 0.0)
                    -> :trading::encoding::VocabEmission
      (:wat::core::let*
        (((last-avg :f64) (:trading::types::PhaseRecord/close-avg last-rec))
         ((trend :f64)
          (:trading::encoding::round-to-4
            (:wat::core::f64::/
              (:wat::core::f64::- last-avg prev-avg) prev-avg))))
        (:trading::vocab::exit::phase::append-scaled-linear acc name trend))
      acc)))

;; append-ratio-round-2 — compute range-trend / spacing-trend shape.
(:wat::core::define
  (:trading::vocab::exit::phase::append-ratio-round-2
    (acc :trading::encoding::VocabEmission)
    (name :String)
    (raw :f64)
    -> :trading::encoding::VocabEmission)
  (:trading::vocab::exit::phase::append-scaled-linear
    acc name (:trading::encoding::round-to-2 raw)))

;; append-scaled-linear — append one scaled-linear holon to the
;; accumulator's Holons vec; thread scales through the encoder.
(:wat::core::define
  (:trading::vocab::exit::phase::append-scaled-linear
    (acc :trading::encoding::VocabEmission)
    (name :String)
    (value :f64)
    -> :trading::encoding::VocabEmission)
  (:wat::core::let*
    (((holons :wat::holon::Holons) (:wat::core::first acc))
     ((scales :trading::encoding::Scales) (:wat::core::second acc))
     ((e :trading::encoding::ScaleEmission)
      (:trading::encoding::scaled-linear name value scales))
     ((h :wat::holon::HolonAST) (:wat::core::first e))
     ((s-next :trading::encoding::Scales) (:wat::core::second e))
     ((holons-next :wat::holon::Holons) (:wat::core::conj holons h)))
    (:wat::core::tuple holons-next s-next)))

;; default-record — unreachable sentinel for match-unwraps. All
;; callsites pre-guard that the Vec is non-empty; the :None arms
;; here never fire in practice but the type checker requires a
;; value for the unreachable branch.
(:wat::core::define
  (:trading::vocab::exit::phase::default-record -> :trading::types::PhaseRecord)
  (:trading::types::PhaseRecord/new
    :trading::types::PhaseLabel::Transition
    :trading::types::PhaseDirection::None
    0 0 0 0.0 0.0 0.0 0.0 0.0 0.0))
