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
    -> :wat::core::String)
  (:wat::core::match label -> :wat::core::String
    (:trading::types::PhaseLabel::Valley "valley")
    (:trading::types::PhaseLabel::Peak   "peak")
    (:trading::types::PhaseLabel::Transition
      (:wat::core::match direction -> :wat::core::String
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
     ((duration-i64 :wat::core::i64) (:trading::types::Candle::Phase/duration p))
     ((duration :wat::core::f64) (:wat::core::i64::to-f64 duration-i64))

     ;; Fact 0 — label binding.
     ((name :wat::core::String)
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
    (history :trading::types::PhaseRecords)
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
       ((n :wat::core::i64) (:wat::core::length history))
       ((last-rec :trading::types::PhaseRecord)
        (:wat::core::match (:wat::core::last history)
                           -> :trading::types::PhaseRecord
          ((Some r) r)
          (:None (:trading::vocab::exit::phase::default-record))))
       ((prev-rec :trading::types::PhaseRecord)
        (:wat::core::match (:wat::core::get history (:wat::core::- n 2))
                           -> :trading::types::PhaseRecord
          ((Some r) r)
          (:None (:trading::vocab::exit::phase::default-record))))

       ;; Filter valleys / peaks from history.
       ((valleys :trading::types::PhaseRecords)
        (:wat::core::filter history
          (:wat::core::lambda ((r :trading::types::PhaseRecord) -> :wat::core::bool)
            (:trading::vocab::exit::phase::is-valley? r))))
       ((peaks :trading::types::PhaseRecords)
        (:wat::core::filter history
          (:wat::core::lambda ((r :trading::types::PhaseRecord) -> :wat::core::bool)
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
       ((last-range :wat::core::f64)
        (:wat::core::-
          (:trading::types::PhaseRecord/close-max last-rec)
          (:trading::types::PhaseRecord/close-min last-rec)))
       ((prev-range :wat::core::f64)
        (:wat::core::-
          (:trading::types::PhaseRecord/close-max prev-rec)
          (:trading::types::PhaseRecord/close-min prev-rec)))
       ((acc3 :trading::encoding::VocabEmission)
        (:wat::core::if (:wat::core::> prev-range 0.0)
                        -> :trading::encoding::VocabEmission
          (:trading::vocab::exit::phase::append-ratio-round-2
            acc2 "phase-range-trend"
            (:wat::core::/ last-range prev-range))
          acc2))

       ;; Step 4: spacing trend.
       ((last-duration :wat::core::f64)
        (:wat::core::i64::to-f64
          (:trading::types::PhaseRecord/duration last-rec)))
       ((prev-duration :wat::core::f64)
        (:wat::core::i64::to-f64
          (:trading::types::PhaseRecord/duration prev-rec)))
       ((acc4 :trading::encoding::VocabEmission)
        (:wat::core::if (:wat::core::> prev-duration 0.0)
                        -> :trading::encoding::VocabEmission
          (:trading::vocab::exit::phase::append-ratio-round-2
            acc3 "phase-spacing-trend"
            (:wat::core::/ last-duration prev-duration))
          acc3)))
      acc4)))

;; ─── Internal helpers ──────────────────────────────────────────

;; is-valley? / is-peak? — label predicates for the filter.
;; Transition records return false in both.
(:wat::core::define
  (:trading::vocab::exit::phase::is-valley?
    (r :trading::types::PhaseRecord)
    -> :wat::core::bool)
  (:wat::core::match (:trading::types::PhaseRecord/label r) -> :wat::core::bool
    (:trading::types::PhaseLabel::Valley     true)
    (:trading::types::PhaseLabel::Peak       false)
    (:trading::types::PhaseLabel::Transition false)))

(:wat::core::define
  (:trading::vocab::exit::phase::is-peak?
    (r :trading::types::PhaseRecord)
    -> :wat::core::bool)
  (:wat::core::match (:trading::types::PhaseRecord/label r) -> :wat::core::bool
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
    (records :trading::types::PhaseRecords)
    (name :wat::core::String)
    -> :trading::encoding::VocabEmission)
  (:wat::core::let*
    (((n :wat::core::i64) (:wat::core::length records))
     ((last-rec :trading::types::PhaseRecord)
      (:wat::core::match (:wat::core::last records)
                         -> :trading::types::PhaseRecord
        ((Some r) r)
        (:None (:trading::vocab::exit::phase::default-record))))
     ((prev-rec :trading::types::PhaseRecord)
      (:wat::core::match (:wat::core::get records (:wat::core::- n 2))
                         -> :trading::types::PhaseRecord
        ((Some r) r)
        (:None (:trading::vocab::exit::phase::default-record))))
     ((prev-avg :wat::core::f64) (:trading::types::PhaseRecord/close-avg prev-rec)))
    (:wat::core::if (:wat::core::> prev-avg 0.0)
                    -> :trading::encoding::VocabEmission
      (:wat::core::let*
        (((last-avg :wat::core::f64) (:trading::types::PhaseRecord/close-avg last-rec))
         ((trend :wat::core::f64)
          (:trading::encoding::round-to-4
            (:wat::core::/
              (:wat::core::- last-avg prev-avg) prev-avg))))
        (:trading::vocab::exit::phase::append-scaled-linear acc name trend))
      acc)))

;; append-ratio-round-2 — compute range-trend / spacing-trend shape.
(:wat::core::define
  (:trading::vocab::exit::phase::append-ratio-round-2
    (acc :trading::encoding::VocabEmission)
    (name :wat::core::String)
    (raw :wat::core::f64)
    -> :trading::encoding::VocabEmission)
  (:trading::vocab::exit::phase::append-scaled-linear
    acc name (:trading::encoding::round-to-2 raw)))

;; append-scaled-linear — append one scaled-linear holon to the
;; accumulator's Holons vec; thread scales through the encoder.
(:wat::core::define
  (:trading::vocab::exit::phase::append-scaled-linear
    (acc :trading::encoding::VocabEmission)
    (name :wat::core::String)
    (value :wat::core::f64)
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

;; ─── Phase rhythm (arc 020) ────────────────────────────────────
;;
;; The third archive function — phase_rhythm_thought. Builds the
;; structural memory of phase history: per-record Bundles →
;; Sequential trigrams → plain-Bind pairs → top-level Bundle,
;; wrapped in (Bind (Atom "phase-rhythm") <bundle>).
;;
;; Same-label lookup uses find-last-index per record (O(n²) but n
;; ≤ 103 by budget); avoids 5-tuple state thread. Each record's
;; Bundle has 5-11 facts depending on i > 0 + same-label hit.

;; ─── Numeric helpers ───────────────────────────────────────────

(:wat::core::define
  (:trading::vocab::exit::phase::rec-duration
    (r :trading::types::PhaseRecord)
    -> :wat::core::f64)
  (:wat::core::i64::to-f64 (:trading::types::PhaseRecord/duration r)))

(:wat::core::define
  (:trading::vocab::exit::phase::rec-range
    (r :trading::types::PhaseRecord)
    -> :wat::core::f64)
  (:wat::core::let*
    (((avg :wat::core::f64) (:trading::types::PhaseRecord/close-avg r)))
    (:wat::core::if (:wat::core::> avg 0.0) -> :wat::core::f64
      (:wat::core::/
        (:wat::core::-
          (:trading::types::PhaseRecord/close-max r)
          (:trading::types::PhaseRecord/close-min r))
        avg)
      0.0)))

(:wat::core::define
  (:trading::vocab::exit::phase::rec-move
    (r :trading::types::PhaseRecord)
    -> :wat::core::f64)
  (:wat::core::let*
    (((open :wat::core::f64) (:trading::types::PhaseRecord/close-open r)))
    (:wat::core::if (:wat::core::> open 0.0) -> :wat::core::f64
      (:wat::core::/
        (:wat::core::-
          (:trading::types::PhaseRecord/close-final r) open)
        open)
      0.0)))

(:wat::core::define
  (:trading::vocab::exit::phase::rec-volume
    (r :trading::types::PhaseRecord)
    -> :wat::core::f64)
  (:trading::types::PhaseRecord/volume-avg r))

;; rel — relative-delta with epsilon guard. (a - b) / |b| if |b|
;; > 0.0001 else 0.
(:wat::core::define
  (:trading::vocab::exit::phase::rel
    (a :wat::core::f64) (b :wat::core::f64)
    -> :wat::core::f64)
  (:wat::core::let*
    (((b-abs :wat::core::f64) (:wat::core::f64::abs b)))
    (:wat::core::if (:wat::core::> b-abs 0.0001) -> :wat::core::f64
      (:wat::core::/ (:wat::core::- a b) b-abs)
      0.0)))

;; ─── same-label-and-direction? — user-enum predicate ───────────
;;
;; Returns true iff records have matching (label, direction). For
;; Valley/Peak, direction is ignored (set to None by convention);
;; for Transition, direction matters.

(:wat::core::define
  (:trading::vocab::exit::phase::direction=
    (a :trading::types::PhaseDirection)
    (b :trading::types::PhaseDirection)
    -> :wat::core::bool)
  (:wat::core::match a -> :wat::core::bool
    (:trading::types::PhaseDirection::Up
      (:wat::core::match b -> :wat::core::bool
        (:trading::types::PhaseDirection::Up   true)
        (:trading::types::PhaseDirection::Down false)
        (:trading::types::PhaseDirection::None false)))
    (:trading::types::PhaseDirection::Down
      (:wat::core::match b -> :wat::core::bool
        (:trading::types::PhaseDirection::Up   false)
        (:trading::types::PhaseDirection::Down true)
        (:trading::types::PhaseDirection::None false)))
    (:trading::types::PhaseDirection::None
      (:wat::core::match b -> :wat::core::bool
        (:trading::types::PhaseDirection::Up   false)
        (:trading::types::PhaseDirection::Down false)
        (:trading::types::PhaseDirection::None true)))))

(:wat::core::define
  (:trading::vocab::exit::phase::same-label-and-direction?
    (a :trading::types::PhaseRecord)
    (b :trading::types::PhaseRecord)
    -> :wat::core::bool)
  (:wat::core::let*
    (((al :trading::types::PhaseLabel) (:trading::types::PhaseRecord/label a))
     ((bl :trading::types::PhaseLabel) (:trading::types::PhaseRecord/label b)))
    (:wat::core::match al -> :wat::core::bool
      (:trading::types::PhaseLabel::Valley
        (:wat::core::match bl -> :wat::core::bool
          (:trading::types::PhaseLabel::Valley     true)
          (:trading::types::PhaseLabel::Peak       false)
          (:trading::types::PhaseLabel::Transition false)))
      (:trading::types::PhaseLabel::Peak
        (:wat::core::match bl -> :wat::core::bool
          (:trading::types::PhaseLabel::Valley     false)
          (:trading::types::PhaseLabel::Peak       true)
          (:trading::types::PhaseLabel::Transition false)))
      (:trading::types::PhaseLabel::Transition
        (:wat::core::match bl -> :wat::core::bool
          (:trading::types::PhaseLabel::Valley     false)
          (:trading::types::PhaseLabel::Peak       false)
          (:trading::types::PhaseLabel::Transition
            (:trading::vocab::exit::phase::direction=
              (:trading::types::PhaseRecord/direction a)
              (:trading::types::PhaseRecord/direction b))))))))

;; ─── Per-record Bundle facts ───────────────────────────────────
;;
;; build-fact — common shape `(Bind (Atom name) (Thermometer v min max))`.
(:wat::core::define
  (:trading::vocab::exit::phase::thermometer-fact
    (name :wat::core::String) (value :wat::core::f64) (lo :wat::core::f64) (hi :wat::core::f64)
    -> :wat::holon::HolonAST)
  (:wat::holon::Bind
    (:wat::holon::Atom name)
    (:wat::holon::Thermometer value lo hi)))

;; record-bundle-at-index — produces the Bundle for one record in
;; the history at index i. 5 base facts + up to 6 conditional
;; deltas. Bundle returns Result; phase bundles are small (≤11
;; facts), capacity is not a concern, so the Err sentinel is
;; unreachable but match-required.
(:wat::core::define
  (:trading::vocab::exit::phase::record-bundle-at-index
    (history :trading::types::PhaseRecords)
    (i :wat::core::i64)
    -> :wat::holon::HolonAST)
  (:wat::core::let*
    (((current :trading::types::PhaseRecord)
      (:wat::core::match (:wat::core::get history i)
                         -> :trading::types::PhaseRecord
        ((Some r) r)
        (:None (:trading::vocab::exit::phase::default-record))))

     ;; Base facts.
     ((label :trading::types::PhaseLabel)
      (:trading::types::PhaseRecord/label current))
     ((direction :trading::types::PhaseDirection)
      (:trading::types::PhaseRecord/direction current))
     ((label-name :wat::core::String)
      (:trading::vocab::exit::phase::phase-label-name label direction))
     ((label-fact :wat::holon::HolonAST)
      (:wat::holon::Bind
        (:wat::holon::Atom "phase")
        (:wat::holon::Atom label-name)))
     ((dur :wat::core::f64) (:trading::vocab::exit::phase::rec-duration current))
     ((mv  :wat::core::f64) (:trading::vocab::exit::phase::rec-move current))
     ((rng :wat::core::f64) (:trading::vocab::exit::phase::rec-range current))
     ((vol :wat::core::f64) (:trading::vocab::exit::phase::rec-volume current))
     ((dur-fact :wat::holon::HolonAST)
      (:trading::vocab::exit::phase::thermometer-fact "rec-duration" dur 0.0 200.0))
     ((mv-fact :wat::holon::HolonAST)
      (:trading::vocab::exit::phase::thermometer-fact "rec-move" mv -0.1 0.1))
     ((rng-fact :wat::holon::HolonAST)
      (:trading::vocab::exit::phase::thermometer-fact "rec-range" rng 0.0 0.1))
     ((vol-fact :wat::holon::HolonAST)
      (:trading::vocab::exit::phase::thermometer-fact "rec-volume" vol 0.0 10000.0))
     ((base :wat::holon::Holons)
      (:wat::core::vec :wat::holon::HolonAST
        label-fact dur-fact mv-fact rng-fact vol-fact))

     ;; Prior-deltas if i > 0.
     ((with-prior :wat::holon::Holons)
      (:wat::core::if (:wat::core::> i 0) -> :wat::holon::Holons
        (:wat::core::let*
          (((prev :trading::types::PhaseRecord)
            (:wat::core::match (:wat::core::get history (:wat::core::- i 1))
                               -> :trading::types::PhaseRecord
              ((Some r) r)
              (:None (:trading::vocab::exit::phase::default-record))))
           ((p-dur :wat::core::f64) (:trading::vocab::exit::phase::rec-duration prev))
           ((p-mv  :wat::core::f64) (:trading::vocab::exit::phase::rec-move prev))
           ((p-vol :wat::core::f64) (:trading::vocab::exit::phase::rec-volume prev))
           ((pd-fact :wat::holon::HolonAST)
            (:trading::vocab::exit::phase::thermometer-fact "prior-duration-delta"
              (:trading::vocab::exit::phase::rel dur p-dur) -2.0 2.0))
           ((pm-fact :wat::holon::HolonAST)
            (:trading::vocab::exit::phase::thermometer-fact "prior-move-delta"
              (:wat::core::- mv p-mv) -0.1 0.1))
           ((pv-fact :wat::holon::HolonAST)
            (:trading::vocab::exit::phase::thermometer-fact "prior-volume-delta"
              (:trading::vocab::exit::phase::rel vol p-vol) -2.0 2.0))
           ((b1 :wat::holon::Holons) (:wat::core::conj base pd-fact))
           ((b2 :wat::holon::Holons) (:wat::core::conj b1 pm-fact))
           ((b3 :wat::holon::Holons) (:wat::core::conj b2 pv-fact)))
          b3)
        base))

     ;; Same-label-and-direction lookup via find-last-index.
     ((earlier :trading::types::PhaseRecords)
      (:wat::core::take history i))
     ((same-idx :Option<i64>)
      (:wat::core::find-last-index earlier
        (:wat::core::lambda ((r :trading::types::PhaseRecord) -> :wat::core::bool)
          (:trading::vocab::exit::phase::same-label-and-direction? r current))))

     ((with-same :wat::holon::Holons)
      (:wat::core::match same-idx -> :wat::holon::Holons
        ((Some si)
          (:wat::core::let*
            (((same-rec :trading::types::PhaseRecord)
              (:wat::core::match (:wat::core::get history si)
                                 -> :trading::types::PhaseRecord
                ((Some r) r)
                (:None (:trading::vocab::exit::phase::default-record))))
             ((s-dur :wat::core::f64) (:trading::vocab::exit::phase::rec-duration same-rec))
             ((s-mv  :wat::core::f64) (:trading::vocab::exit::phase::rec-move same-rec))
             ((s-vol :wat::core::f64) (:trading::vocab::exit::phase::rec-volume same-rec))
             ((sm-fact :wat::holon::HolonAST)
              (:trading::vocab::exit::phase::thermometer-fact "same-move-delta"
                (:wat::core::- mv s-mv) -0.1 0.1))
             ((sd-fact :wat::holon::HolonAST)
              (:trading::vocab::exit::phase::thermometer-fact "same-duration-delta"
                (:trading::vocab::exit::phase::rel dur s-dur) -2.0 2.0))
             ((sv-fact :wat::holon::HolonAST)
              (:trading::vocab::exit::phase::thermometer-fact "same-volume-delta"
                (:trading::vocab::exit::phase::rel vol s-vol) -2.0 2.0))
             ((b1 :wat::holon::Holons) (:wat::core::conj with-prior sm-fact))
             ((b2 :wat::holon::Holons) (:wat::core::conj b1 sd-fact))
             ((b3 :wat::holon::Holons) (:wat::core::conj b2 sv-fact)))
            b3))
        (:None with-prior))))

    ;; Wrap in Bundle. Match the BundleResult; Err sentinel for
    ;; unreachable capacity-exceeded path.
    (:wat::core::match (:wat::holon::Bundle with-same) -> :wat::holon::HolonAST
      ((Ok h) h)
      ((Err _) (:wat::holon::Atom "phase-rhythm-record-bundle-overflow")))))

;; ─── phase-rhythm-holon — top level ────────────────────────────

;; phase-rhythm-empty-sentinel — singleton-Bundle placeholder.
;; Per arc 026's empty-Bundle convention (holon-rs panics on
;; empty bundles), the empty rhythm wraps a single placeholder
;; Atom inside a Bundle. Used for both insufficient-history
;; (< 4 records) and empty-pairs (post-windowing) cases.
(:wat::core::define
  (:trading::vocab::exit::phase::empty-rhythm-bundle -> :wat::holon::HolonAST)
  (:wat::core::match
    (:wat::holon::Bundle
      (:wat::core::vec :wat::holon::HolonAST
        (:wat::holon::Atom "phase-rhythm-empty")))
    -> :wat::holon::HolonAST
    ((Ok h) h)
    ((Err _) (:wat::holon::Atom "phase-rhythm-sentinel-overflow"))))

(:wat::core::define
  (:trading::vocab::exit::phase::phase-rhythm-holon
    (history :trading::types::PhaseRecords)
    -> :wat::holon::HolonAST)
  (:wat::core::if (:wat::core::< (:wat::core::length history) 4)
                  -> :wat::holon::HolonAST
    ;; Insufficient history — wrap the empty-rhythm sentinel.
    (:wat::holon::Bind
      (:wat::holon::Atom "phase-rhythm")
      (:trading::vocab::exit::phase::empty-rhythm-bundle))
    (:wat::core::let*
      (;; Build all per-record Bundles.
       ((n :wat::core::i64) (:wat::core::length history))
       ((indices :Vec<i64>) (:wat::core::range 0 n))
       ((all-records :wat::holon::Holons)
        (:wat::core::map indices
          (:wat::core::lambda ((i :wat::core::i64) -> :wat::holon::HolonAST)
            (:trading::vocab::exit::phase::record-bundle-at-index history i))))

       ;; Truncate to last (budget + 3) = 103 records.
       ((budget :wat::core::i64) 100)
       ((max-records :wat::core::i64) (:wat::core::+ budget 3))
       ((records-len :wat::core::i64) (:wat::core::length all-records))
       ((records :wat::holon::Holons)
        (:wat::core::if (:wat::core::> records-len max-records)
                        -> :wat::holon::Holons
          (:wat::core::drop all-records
            (:wat::core::- records-len max-records))
          all-records))

       ;; window-3 → Sequential trigrams.
       ((win3 :Vec<wat::holon::Holons>)
        (:wat::std::list::window records 3))
       ((trigrams :wat::holon::Holons)
        (:wat::core::map win3
          (:wat::core::lambda ((w :wat::holon::Holons) -> :wat::holon::HolonAST)
            (:wat::holon::Sequential w))))

       ;; window-2 → plain-Bind pairs (NOT Bigram — archive does not
       ;; Permute the second element).
       ((win2 :Vec<wat::holon::Holons>)
        (:wat::std::list::window trigrams 2))
       ((pairs :wat::holon::Holons)
        (:wat::core::map win2
          (:wat::core::lambda ((w :wat::holon::Holons) -> :wat::holon::HolonAST)
            (:wat::core::let*
              (((a :wat::holon::HolonAST)
                (:wat::core::match (:wat::core::first w)
                                   -> :wat::holon::HolonAST
                  ((Some h) h)
                  (:None (:wat::holon::Atom "unreachable"))))
               ((b :wat::holon::HolonAST)
                (:wat::core::match (:wat::core::second w)
                                   -> :wat::holon::HolonAST
                  ((Some h) h)
                  (:None (:wat::holon::Atom "unreachable")))))
              (:wat::holon::Bind a b)))))

       ;; Truncate pairs to last `budget` (= 100).
       ((pairs-len :wat::core::i64) (:wat::core::length pairs))
       ((trimmed-pairs :wat::holon::Holons)
        (:wat::core::if (:wat::core::> pairs-len budget)
                        -> :wat::holon::Holons
          (:wat::core::drop pairs (:wat::core::- pairs-len budget))
          pairs))

       ;; Bundle the pairs.
       ((bundle-result :wat::holon::BundleResult)
        (:wat::holon::Bundle trimmed-pairs))
       ((inner :wat::holon::HolonAST)
        (:wat::core::match bundle-result -> :wat::holon::HolonAST
          ((Ok h) h)
          ((Err _) (:wat::holon::Atom "phase-rhythm-bundle-overflow")))))

      ;; Wrap in (Bind (Atom "phase-rhythm") <bundle>).
      (:wat::holon::Bind
        (:wat::holon::Atom "phase-rhythm")
        inner))))
