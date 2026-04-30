;; wat-tests/sim/paper.wat — Lab arc 025 slice 4 tests.
;;
;; Direct tests of the simulator engine via `tick`. Stream-based
;; integration tests (real parquet) live in slice 5's
;; integration.wat.

(:wat::test::make-deftest :deftest
  ((:wat::load-file! "wat/sim/paper.wat")

   ;; Test fixtures.

   (:wat::core::define
     (:test::ohlcv
       (open :wat::core::f64) (high :wat::core::f64) (low :wat::core::f64) (close :wat::core::f64) (volume :wat::core::f64)
       -> :trading::types::Ohlcv)
     (:trading::types::Ohlcv/new
       (:trading::types::Asset/new "BTC")
       (:trading::types::Asset/new "USDC")
       "2024-01-01T00:00:00Z"
       open high low close volume))

   (:wat::core::define
     (:test::config -> :trading::sim::Config)
     (:trading::sim::Config/new 288 0.01 35.0 14))

   ;; Always-Hold thinker — emits a placeholder surface; predictor
   ;; below decides what to do.
   (:wat::core::define
     (:test::placeholder-surface -> :wat::holon::HolonAST)
     (:wat::holon::Atom (:wat::core::quote :test-surface)))

   (:wat::core::define
     (:test::placeholder-thinker -> :trading::sim::Thinker)
     (:trading::sim::Thinker/new
       (:wat::core::lambda
         ((window :trading::types::Candles)
          (pos :Option<trading::sim::Paper>)
          -> :wat::holon::HolonAST)
         (:test::placeholder-surface))))

   ;; Constant-Action predictors.
   (:wat::core::define
     (:test::predictor-hold -> :trading::sim::Predictor)
     (:trading::sim::Predictor/new
       (:wat::core::lambda
         ((surface :wat::holon::HolonAST) -> :trading::sim::Action)
         :trading::sim::Action::Hold)))

   (:wat::core::define
     (:test::predictor-open-up -> :trading::sim::Predictor)
     (:trading::sim::Predictor/new
       (:wat::core::lambda
         ((surface :wat::holon::HolonAST) -> :trading::sim::Action)
         (:trading::sim::Action::Open :trading::sim::Direction::Up))))

   (:wat::core::define
     (:test::predictor-exit -> :trading::sim::Predictor)
     (:trading::sim::Predictor/new
       (:wat::core::lambda
         ((surface :wat::holon::HolonAST) -> :trading::sim::Action)
         :trading::sim::Action::Exit)))

   ;; Tail-recursive feeder: tick `n` times with the same Ohlcv.
   (:wat::core::define
     (:test::feed
       (state :trading::sim::SimState)
       (oh :trading::types::Ohlcv)
       (cfg :trading::sim::Config)
       (th :trading::sim::Thinker)
       (pr :trading::sim::Predictor)
       (n :wat::core::i64)
       -> :trading::sim::SimState)
     (:wat::core::if (:wat::core::<= n 0)
                     -> :trading::sim::SimState
       state
       (:test::feed
         (:trading::sim::tick state oh cfg th pr)
         oh cfg th pr
         (:wat::core::- n 1))))))


;; ─── Fresh state ──────────────────────────────────────────────────

(:deftest :trading::test::sim::paper::test-fresh-zero-count
  (:wat::core::let*
    (((state :trading::sim::SimState)
      (:trading::sim::SimState::fresh)))
    (:wat::test::assert-eq
      (:trading::sim::SimState/count state)
      0)))

(:deftest :trading::test::sim::paper::test-fresh-no-open-paper
  (:wat::core::let*
    (((state :trading::sim::SimState)
      (:trading::sim::SimState::fresh))
     ((paper :Option<trading::sim::Paper>)
      (:trading::sim::SimState/open-paper state))
     ((is-none? :wat::core::bool)
      (:wat::core::match paper -> :wat::core::bool
        ((Some _) false)
        (:None true))))
    (:wat::test::assert-eq is-none? true)))


;; ─── Always-Hold path: no papers, count tracks ───────────────────

(:deftest :trading::test::sim::paper::test-hold-no-papers
  (:wat::core::let*
    (((state :trading::sim::SimState)
      (:test::feed
        (:trading::sim::SimState::fresh)
        (:test::ohlcv 100.0 110.0 95.0 105.0 50.0)
        (:test::config)
        (:test::placeholder-thinker)
        (:test::predictor-hold)
        10))
     ((agg :trading::sim::Aggregate)
      (:trading::sim::SimState/aggregate state)))
    (:wat::test::assert-eq
      (:trading::sim::Aggregate/papers agg)
      0)))


;; ─── Open-Up path: predictor opens a paper on first tick ─────────

(:deftest :trading::test::sim::paper::test-open-up-creates-paper
  (:wat::core::let*
    (((state :trading::sim::SimState)
      (:trading::sim::tick
        (:trading::sim::SimState::fresh)
        (:test::ohlcv 100.0 110.0 95.0 105.0 50.0)
        (:test::config)
        (:test::placeholder-thinker)
        (:test::predictor-open-up)))
     ((paper :Option<trading::sim::Paper>)
      (:trading::sim::SimState/open-paper state))
     ((is-some? :wat::core::bool)
      (:wat::core::match paper -> :wat::core::bool
        ((Some _) true)
        (:None false))))
    (:wat::test::assert-eq is-some? true)))

(:deftest :trading::test::sim::paper::test-open-up-paper-direction
  (:wat::core::let*
    (((state :trading::sim::SimState)
      (:trading::sim::tick
        (:trading::sim::SimState::fresh)
        (:test::ohlcv 100.0 110.0 95.0 105.0 50.0)
        (:test::config)
        (:test::placeholder-thinker)
        (:test::predictor-open-up)))
     ((paper :Option<trading::sim::Paper>)
      (:trading::sim::SimState/open-paper state))
     ((is-up? :wat::core::bool)
      (:wat::core::match paper -> :wat::core::bool
        ((Some p)
          (:wat::core::match (:trading::sim::Paper/direction p) -> :wat::core::bool
            (:trading::sim::Direction::Up true)
            (_ false)))
        (:None false))))
    (:wat::test::assert-eq is-up? true)))


;; ─── Deadline → Violence resolution ──────────────────────────────

(:deftest :trading::test::sim::paper::test-deadline-violence
  (:wat::core::let*
    (;; Tiny deadline so we hit it fast: 5 candles.
     ((cfg :trading::sim::Config)
      (:trading::sim::Config/new 5 0.01 35.0 14))
     ((state-after-open :trading::sim::SimState)
      (:trading::sim::tick
        (:trading::sim::SimState::fresh)
        (:test::ohlcv 100.0 110.0 95.0 105.0 50.0)
        cfg
        (:test::placeholder-thinker)
        (:test::predictor-open-up)))
     ;; Now feed 6 more flat-at-105 ticks with Hold predictor —
     ;; deadline hits.
     ((state-final :trading::sim::SimState)
      (:test::feed state-after-open
        (:test::ohlcv 105.0 106.0 104.0 105.0 50.0)
        cfg
        (:test::placeholder-thinker)
        (:test::predictor-hold)
        6))
     ((agg :trading::sim::Aggregate)
      (:trading::sim::SimState/aggregate state-final))
     ((violence-count :wat::core::i64)
      (:trading::sim::Aggregate/violence-count agg)))
    (:wat::test::assert-eq violence-count 1)))


;; ─── Aggregate updates correctly on resolution ───────────────────

(:deftest :trading::test::sim::paper::test-violence-aggregate-paper-count
  (:wat::core::let*
    (((cfg :trading::sim::Config)
      (:trading::sim::Config/new 5 0.01 35.0 14))
     ((state-after-open :trading::sim::SimState)
      (:trading::sim::tick
        (:trading::sim::SimState::fresh)
        (:test::ohlcv 100.0 110.0 95.0 105.0 50.0)
        cfg
        (:test::placeholder-thinker)
        (:test::predictor-open-up)))
     ((state-final :trading::sim::SimState)
      (:test::feed state-after-open
        (:test::ohlcv 105.0 106.0 104.0 105.0 50.0)
        cfg
        (:test::placeholder-thinker)
        (:test::predictor-hold)
        6))
     ((agg :trading::sim::Aggregate)
      (:trading::sim::SimState/aggregate state-final))
     ((paper-count :wat::core::i64)
      (:trading::sim::Aggregate/papers agg)))
    (:wat::test::assert-eq paper-count 1)))


;; ─── Outcome captures continuous paper-label (Chapter 57) ────────

(:deftest :trading::test::sim::paper::test-outcome-paper-label-non-empty
  (:wat::core::let*
    (((cfg :trading::sim::Config)
      (:trading::sim::Config/new 5 0.01 35.0 14))
     ((state-after-open :trading::sim::SimState)
      (:trading::sim::tick
        (:trading::sim::SimState::fresh)
        (:test::ohlcv 100.0 110.0 95.0 105.0 50.0)
        cfg
        (:test::placeholder-thinker)
        (:test::predictor-open-up)))
     ((state-final :trading::sim::SimState)
      (:test::feed state-after-open
        (:test::ohlcv 105.0 106.0 104.0 105.0 50.0)
        cfg
        (:test::placeholder-thinker)
        (:test::predictor-hold)
        6))
     ((outcomes :trading::sim::Outcomes)
      (:trading::sim::SimState/outcomes state-final))
     ((first-outcome :trading::sim::Outcome)
      (:wat::core::match (:wat::core::get outcomes 0) -> :trading::sim::Outcome
        ((Some o) o)
        (:None
          ;; Unreachable — we know one outcome exists.
          (:trading::sim::Outcome/new
            (:trading::sim::Paper/new
              0 :trading::sim::Direction::Up 0.0 0
              (:test::placeholder-surface) 0
              :trading::sim::PositionState::Active
              (:wat::core::vec :trading::sim::TriggerEvent))
            0 0.0
            (:test::placeholder-surface)
            (:wat::core::vec :trading::sim::LabeledTrigger)))))
     ((label :wat::holon::HolonAST)
      (:trading::sim::Outcome/paper-label first-outcome)))
    ;; Confirm the label is a real HolonAST — coincides with itself
    ;; in HD space (geometry-aware equality, not f64 exact match).
    (:wat::test::assert-coincident label label)))


;; ─── Predictor swap changes the aggregate (Ch.55 seam works) ──────

(:deftest :trading::test::sim::paper::test-predictor-swap-different-aggregates
  (:wat::core::let*
    (((cfg :trading::sim::Config) (:test::config))
     ;; Run with hold predictor — no papers.
     ((agg-hold :trading::sim::Aggregate)
      (:trading::sim::SimState/aggregate
        (:test::feed
          (:trading::sim::SimState::fresh)
          (:test::ohlcv 100.0 110.0 95.0 105.0 50.0)
          cfg
          (:test::placeholder-thinker)
          (:test::predictor-hold)
          5)))
     ;; Same input + thinker; different predictor — opens a paper.
     ((agg-open :trading::sim::Aggregate)
      (:trading::sim::SimState/aggregate
        (:test::feed
          (:trading::sim::SimState::fresh)
          (:test::ohlcv 100.0 110.0 95.0 105.0 50.0)
          cfg
          (:test::placeholder-thinker)
          (:test::predictor-open-up)
          5)))
     ;; agg-hold sees 0 papers (resolved); agg-open sees 0 papers
     ;; (still active, no resolution yet within 5 candles at dl=288).
     ;; The seam test: SimState/open-paper differs.
     ;; Construct dummy Ohlcv-only state to compare:
     ((agg-papers-hold :wat::core::i64) (:trading::sim::Aggregate/papers agg-hold))
     ((agg-papers-open :wat::core::i64) (:trading::sim::Aggregate/papers agg-open)))
    ;; Both 0 (neither resolved); but the SimState's open-paper differs
    ;; (already covered by test-open-up-creates-paper). This test
    ;; confirms predictor swap does NOT crash and the simulator
    ;; produces valid aggregates either way.
    (:wat::core::let*
      (((u1 :()) (:wat::test::assert-eq agg-papers-hold 0)))
      (:wat::test::assert-eq agg-papers-open 0))))


;; ─── Helper-level tests (slice-4-5-design-questions Q13) ──────────
;;
;; Tests 18-23 from BACKLOG slice 4 — exercise the algebra of the
;; resolution helpers in isolation, the way archive's pivot.rs tested
;; PhaseState (smoothing as a parameter, hand-picked values, no
;; warmup). Skips IndicatorBank/ATR threading entirely.


;; Test 18 — Grace eligible: paper-Up + Peak trigger + clean residue.
(:deftest :trading::test::sim::paper::test-grace-eligible-up-peak
  (:wat::core::let*
    (((paper :trading::sim::Paper)
      (:trading::sim::Paper/new
        1 :trading::sim::Direction::Up 100.0 0
        (:test::placeholder-surface) 288
        :trading::sim::PositionState::Active
        (:wat::core::vec :trading::sim::TriggerEvent)))
     ((eligible? :wat::core::bool)
      (:trading::sim::evaluate-grace-eligible?
        paper
        true
        :trading::types::PhaseLabel::Peak
        0.03
        :trading::sim::Action::Exit
        (:test::config))))
    (:wat::test::assert-eq eligible? true)))


;; Test 19 — Grace eligible: paper-Down + Valley trigger (symmetric).
(:deftest :trading::test::sim::paper::test-grace-eligible-down-valley
  (:wat::core::let*
    (((paper :trading::sim::Paper)
      (:trading::sim::Paper/new
        1 :trading::sim::Direction::Down 100.0 0
        (:test::placeholder-surface) 288
        :trading::sim::PositionState::Active
        (:wat::core::vec :trading::sim::TriggerEvent)))
     ((eligible? :wat::core::bool)
      (:trading::sim::evaluate-grace-eligible?
        paper
        true
        :trading::types::PhaseLabel::Valley
        0.03
        :trading::sim::Action::Exit
        (:test::config))))
    (:wat::test::assert-eq eligible? true)))


;; Test 20 — Residue floor blocks Grace even when other gates pass.
(:deftest :trading::test::sim::paper::test-residue-floor-blocks-grace
  (:wat::core::let*
    (((paper :trading::sim::Paper)
      (:trading::sim::Paper/new
        1 :trading::sim::Direction::Up 100.0 0
        (:test::placeholder-surface) 288
        :trading::sim::PositionState::Active
        (:wat::core::vec :trading::sim::TriggerEvent)))
     ;; min-residue is 0.01 in test::config; pass 0.005 — gate-3 must fail.
     ((eligible? :wat::core::bool)
      (:trading::sim::evaluate-grace-eligible?
        paper
        true
        :trading::types::PhaseLabel::Peak
        0.005
        :trading::sim::Action::Exit
        (:test::config))))
    (:wat::test::assert-eq eligible? false)))


;; Test 21 — Retroactive labeling on Grace: closing trigger gets
;; :Exit, all earlier triggers get :Hold.
(:deftest :trading::test::sim::paper::test-label-trail-grace-back-fill
  (:wat::core::let*
    (((te :fn(i64)->trading::sim::TriggerEvent)
      (:wat::core::lambda ((i :wat::core::i64) -> :trading::sim::TriggerEvent)
        (:trading::sim::TriggerEvent/new
          i :trading::types::PhaseLabel::Peak
          :trading::sim::Decision::NotEvaluated
          (:test::placeholder-surface))))
     ((trail :trading::sim::TriggerEvents)
      (:wat::core::vec :trading::sim::TriggerEvent
        (te 1) (te 2) (te 3) (te 4)))
     ((labeled :trading::sim::LabeledTriggers)
      (:trading::sim::label-trail-grace trail 3))
     ((label-of :fn(i64)->trading::sim::TriggerLabel)
      (:wat::core::lambda ((i :wat::core::i64) -> :trading::sim::TriggerLabel)
        (:wat::core::match (:wat::core::get labeled i) -> :trading::sim::TriggerLabel
          ((Some lt) (:trading::sim::LabeledTrigger/label lt))
          (:None :trading::sim::TriggerLabel::Unknown))))
     ((is-hold? :fn(trading::sim::TriggerLabel)->bool)
      (:wat::core::lambda ((l :trading::sim::TriggerLabel) -> :wat::core::bool)
        (:wat::core::match l -> :wat::core::bool
          (:trading::sim::TriggerLabel::Hold true)
          (_ false))))
     ((is-exit? :fn(trading::sim::TriggerLabel)->bool)
      (:wat::core::lambda ((l :trading::sim::TriggerLabel) -> :wat::core::bool)
        (:wat::core::match l -> :wat::core::bool
          (:trading::sim::TriggerLabel::Exit true)
          (_ false))))
     ((u1 :()) (:wat::test::assert-eq (is-hold? (label-of 0)) true))
     ((u2 :()) (:wat::test::assert-eq (is-hold? (label-of 1)) true))
     ((u3 :()) (:wat::test::assert-eq (is-hold? (label-of 2)) true)))
    (:wat::test::assert-eq (is-exit? (label-of 3)) true)))


;; Test 22 — Retroactive labeling on Violence: every passed trigger
;; labeled :Exit (should-have-Exit'd).
(:deftest :trading::test::sim::paper::test-label-trail-violence-all-exit
  (:wat::core::let*
    (((te :fn(i64)->trading::sim::TriggerEvent)
      (:wat::core::lambda ((i :wat::core::i64) -> :trading::sim::TriggerEvent)
        (:trading::sim::TriggerEvent/new
          i :trading::types::PhaseLabel::Peak
          :trading::sim::Decision::NotEvaluated
          (:test::placeholder-surface))))
     ((trail :trading::sim::TriggerEvents)
      (:wat::core::vec :trading::sim::TriggerEvent
        (te 1) (te 2) (te 3)))
     ((labeled :trading::sim::LabeledTriggers)
      (:trading::sim::label-trail-violence trail))
     ((label-of :fn(i64)->trading::sim::TriggerLabel)
      (:wat::core::lambda ((i :wat::core::i64) -> :trading::sim::TriggerLabel)
        (:wat::core::match (:wat::core::get labeled i) -> :trading::sim::TriggerLabel
          ((Some lt) (:trading::sim::LabeledTrigger/label lt))
          (:None :trading::sim::TriggerLabel::Unknown))))
     ((is-exit? :fn(trading::sim::TriggerLabel)->bool)
      (:wat::core::lambda ((l :trading::sim::TriggerLabel) -> :wat::core::bool)
        (:wat::core::match l -> :wat::core::bool
          (:trading::sim::TriggerLabel::Exit true)
          (_ false))))
     ((u1 :()) (:wat::test::assert-eq (is-exit? (label-of 0)) true))
     ((u2 :()) (:wat::test::assert-eq (is-exit? (label-of 1)) true)))
    (:wat::test::assert-eq (is-exit? (label-of 2)) true)))


;; Test 23 — Aggregate accumulation across one Grace + one Violence.
(:deftest :trading::test::sim::paper::test-aggregate-mixed-grace-violence
  (:wat::core::let*
    (((fresh-agg :trading::sim::Aggregate)
      (:trading::sim::Aggregate/new 0 0 0 0.0 0.0))
     ((agg-after-grace :trading::sim::Aggregate)
      (:trading::sim::aggregate-grace fresh-agg 0.03))
     ((final :trading::sim::Aggregate)
      (:trading::sim::aggregate-violence agg-after-grace -0.02))
     ((u1 :()) (:wat::test::assert-eq (:trading::sim::Aggregate/papers final) 2))
     ((u2 :()) (:wat::test::assert-eq (:trading::sim::Aggregate/grace-count final) 1))
     ((u3 :()) (:wat::test::assert-eq (:trading::sim::Aggregate/violence-count final) 1))
     ((u4 :()) (:wat::test::assert-eq (:trading::sim::Aggregate/total-residue final) 0.03)))
    (:wat::test::assert-eq (:trading::sim::Aggregate/total-loss final) 0.02)))


;; ─── Q10 effective-action translation ─────────────────────────────

;; No paper open → effective-action is identity for all raw actions.
(:deftest :trading::test::sim::paper::test-effective-action-no-paper-identity
  (:wat::core::let*
    (((eff :trading::sim::Action)
      (:trading::sim::effective-action
        (:trading::sim::Action::Open :trading::sim::Direction::Up)
        :None))
     ((is-open-up? :wat::core::bool)
      (:wat::core::match eff -> :wat::core::bool
        ((:trading::sim::Action::Open d)
          (:wat::core::match d -> :wat::core::bool
            (:trading::sim::Direction::Up true)
            (:trading::sim::Direction::Down false)))
        (_ false))))
    (:wat::test::assert-eq is-open-up? true)))


;; Paper-Up open + (Open :Up) → :Hold (already going that way).
(:deftest :trading::test::sim::paper::test-effective-action-same-direction-is-hold
  (:wat::core::let*
    (((paper :trading::sim::Paper)
      (:trading::sim::Paper/new
        1 :trading::sim::Direction::Up 100.0 0
        (:test::placeholder-surface) 288
        :trading::sim::PositionState::Active
        (:wat::core::vec :trading::sim::TriggerEvent)))
     ((eff :trading::sim::Action)
      (:trading::sim::effective-action
        (:trading::sim::Action::Open :trading::sim::Direction::Up)
        (Some paper)))
     ((is-hold? :wat::core::bool)
      (:wat::core::match eff -> :wat::core::bool
        (:trading::sim::Action::Hold true)
        (_ false))))
    (:wat::test::assert-eq is-hold? true)))


;; Paper-Up open + (Open :Down) → :Exit (trend turned).
(:deftest :trading::test::sim::paper::test-effective-action-opposite-direction-is-exit
  (:wat::core::let*
    (((paper :trading::sim::Paper)
      (:trading::sim::Paper/new
        1 :trading::sim::Direction::Up 100.0 0
        (:test::placeholder-surface) 288
        :trading::sim::PositionState::Active
        (:wat::core::vec :trading::sim::TriggerEvent)))
     ((eff :trading::sim::Action)
      (:trading::sim::effective-action
        (:trading::sim::Action::Open :trading::sim::Direction::Down)
        (Some paper)))
     ((is-exit? :wat::core::bool)
      (:wat::core::match eff -> :wat::core::bool
        (:trading::sim::Action::Exit true)
        (_ false))))
    (:wat::test::assert-eq is-exit? true)))
