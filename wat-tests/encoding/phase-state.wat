;; wat-tests/encoding/phase-state.wat — Lab arc 025 slice 2 tests.
;;
;; Tests :trading::encoding::PhaseState (::fresh, ::step) against its
;; source at wat/encoding/phase-state.wat. Test scenarios ported
;; verbatim from archive's tests in
;; archived/pre-wat-native/src/types/pivot.rs:285-432.

(:wat::test::make-deftest :deftest
  ((:wat::load-file! "wat/encoding/phase-state.wat")))

;; ─── ::fresh ───────────────────────────────────────────────────────

;; Archive: test_phase_state_new
(:deftest :trading::test::encoding::phase-state::test-fresh-is-valley
  (:wat::core::let*
    (((s :trading::encoding::PhaseState)
      (:trading::encoding::PhaseState::fresh)))
    (:wat::core::match (:trading::encoding::PhaseState/current-label s) -> :()
      (:trading::types::PhaseLabel::Valley
        (:wat::test::assert-eq true true))
      (_
        (:wat::test::assert-eq true false)))))

(:deftest :trading::test::encoding::phase-state::test-fresh-zero-count
  (:wat::core::let*
    (((s :trading::encoding::PhaseState)
      (:trading::encoding::PhaseState::fresh)))
    (:wat::test::assert-eq
      (:trading::encoding::PhaseState/count s)
      0)))

(:deftest :trading::test::encoding::phase-state::test-fresh-empty-history
  (:wat::core::let*
    (((s :trading::encoding::PhaseState)
      (:trading::encoding::PhaseState::fresh)))
    (:wat::test::assert-eq
      (:wat::core::length (:trading::encoding::PhaseState/phase-history s))
      0)))

;; ─── single step (archive: test_single_step) ──────────────────────

(:deftest :trading::test::encoding::phase-state::test-single-step-is-valley
  (:wat::core::let*
    (((s0 :trading::encoding::PhaseState)
      (:trading::encoding::PhaseState::fresh))
     ((s1 :trading::encoding::PhaseState)
      (:trading::encoding::PhaseState::step s0 100.0 50.0 1 5.0)))
    (:wat::core::let*
      (((u1 :())
        (:wat::test::assert-eq (:trading::encoding::PhaseState/count s1) 1)))
      (:wat::core::match (:trading::encoding::PhaseState/current-label s1) -> :()
        (:trading::types::PhaseLabel::Valley
          (:wat::test::assert-eq true true))
        (_
          (:wat::test::assert-eq true false))))))

;; ─── valley → transition → peak (archive: test_valley_to_transition_to_peak) ──

(:deftest :trading::test::encoding::phase-state::test-valley-to-peak-cycle
  (:wat::core::let*
    (((s0 :trading::encoding::PhaseState)
      (:trading::encoding::PhaseState::fresh))
     ;; Valley sequence — Falling, near low.
     ((s1 :trading::encoding::PhaseState)
      (:trading::encoding::PhaseState::step s0 100.0 50.0 1 5.0))
     ((s2 :trading::encoding::PhaseState)
      (:trading::encoding::PhaseState::step s1 98.0 50.0 2 5.0))
     ((s3 :trading::encoding::PhaseState)
      (:trading::encoding::PhaseState::step s2 97.0 50.0 3 5.0))
     ;; Rise past smoothing (97 + 5 = 102; 103 > 102) — switch to Rising,
     ;; extreme=103, close=103, 103 >= 103-2.5 → Peak.
     ((s4 :trading::encoding::PhaseState)
      (:trading::encoding::PhaseState::step s3 103.0 50.0 4 5.0))
     ((label-is-peak? :wat::core::bool)
      (:wat::core::match (:trading::encoding::PhaseState/current-label s4) -> :wat::core::bool
        (:trading::types::PhaseLabel::Peak true)
        (_ false)))
     ((tracking-is-rising? :wat::core::bool)
      (:wat::core::match (:trading::encoding::PhaseState/tracking s4) -> :wat::core::bool
        (:trading::encoding::TrackingState::Rising true)
        (_ false)))
     ((history-len :wat::core::i64)
      (:wat::core::length (:trading::encoding::PhaseState/phase-history s4))))
    (:wat::core::let*
      (((u1 :()) (:wat::test::assert-eq label-is-peak? true))
       ((u2 :()) (:wat::test::assert-eq tracking-is-rising? true)))
      (:wat::test::assert-eq history-len 1))))

;; ─── full cycle (archive: test_full_cycle) ─────────────────────────

(:deftest :trading::test::encoding::phase-state::test-full-cycle
  (:wat::core::let*
    (((s0 :trading::encoding::PhaseState)
      (:trading::encoding::PhaseState::fresh))
     ;; Valley.
     ((s1 :trading::encoding::PhaseState)
      (:trading::encoding::PhaseState::step s0 100.0 50.0 1 5.0))
     ((s2 :trading::encoding::PhaseState)
      (:trading::encoding::PhaseState::step s1 95.0 50.0 2 5.0))
     ;; Rise past smoothing — switch to Rising → Peak.
     ((s3 :trading::encoding::PhaseState)
      (:trading::encoding::PhaseState::step s2 101.0 50.0 3 5.0))
     ;; Continue up — still Peak.
     ((s4 :trading::encoding::PhaseState)
      (:trading::encoding::PhaseState::step s3 105.0 50.0 4 5.0))
     ;; Eases slightly but still near extreme — Peak.
     ((s5 :trading::encoding::PhaseState)
      (:trading::encoding::PhaseState::step s4 103.0 50.0 5 5.0))
     ;; Drops below half_smooth but not past full smoothing — Transition-up.
     ((s6 :trading::encoding::PhaseState)
      (:trading::encoding::PhaseState::step s5 100.0 50.0 6 5.0))
     ;; Drops past smoothing — switch to Falling → Valley.
     ((s7 :trading::encoding::PhaseState)
      (:trading::encoding::PhaseState::step s6 99.0 50.0 7 5.0))
     ((label-s6 :trading::types::PhaseLabel)
      (:trading::encoding::PhaseState/current-label s6))
     ((label-s7 :trading::types::PhaseLabel)
      (:trading::encoding::PhaseState/current-label s7))
     ((s6-is-transition? :wat::core::bool)
      (:wat::core::match label-s6 -> :wat::core::bool
        (:trading::types::PhaseLabel::Transition true)
        (_ false)))
     ((s7-is-valley? :wat::core::bool)
      (:wat::core::match label-s7 -> :wat::core::bool
        (:trading::types::PhaseLabel::Valley true)
        (_ false)))
     ((s7-tracking-falling? :wat::core::bool)
      (:wat::core::match (:trading::encoding::PhaseState/tracking s7) -> :wat::core::bool
        (:trading::encoding::TrackingState::Falling true)
        (_ false))))
    (:wat::core::let*
      (((u1 :()) (:wat::test::assert-eq s6-is-transition? true))
       ((u2 :()) (:wat::test::assert-eq s7-is-valley? true)))
      (:wat::test::assert-eq s7-tracking-falling? true))))

;; ─── peak-at-high, valley-at-low (archive: test_peak_at_high_valley_at_low) ──

(:deftest :trading::test::encoding::phase-state::test-peak-at-high-valley-at-low
  (:wat::core::let*
    (((s0 :trading::encoding::PhaseState)
      (:trading::encoding::PhaseState::fresh))
     ((s1 :trading::encoding::PhaseState)
      (:trading::encoding::PhaseState::step s0 100.0 50.0 1 10.0))
     ;; Rise to 115 (100+10=110, 115>110 → switch to Rising).
     ;; extreme=115, close=115, 115 >= 115-5 → Peak at HIGH.
     ((s2 :trading::encoding::PhaseState)
      (:trading::encoding::PhaseState::step s1 115.0 50.0 2 10.0))
     ;; Drop past smoothing (115-104=11>10) → switch to Falling.
     ;; extreme=104, close=104, 104 <= 104+5 → Valley at LOW.
     ((s3 :trading::encoding::PhaseState)
      (:trading::encoding::PhaseState::step s2 112.0 50.0 3 10.0))
     ((s4 :trading::encoding::PhaseState)
      (:trading::encoding::PhaseState::step s3 108.0 50.0 4 10.0))
     ((s5 :trading::encoding::PhaseState)
      (:trading::encoding::PhaseState::step s4 104.0 50.0 5 10.0))
     ((s2-is-peak? :wat::core::bool)
      (:wat::core::match (:trading::encoding::PhaseState/current-label s2) -> :wat::core::bool
        (:trading::types::PhaseLabel::Peak true)
        (_ false)))
     ((s5-is-valley? :wat::core::bool)
      (:wat::core::match (:trading::encoding::PhaseState/current-label s5) -> :wat::core::bool
        (:trading::types::PhaseLabel::Valley true)
        (_ false))))
    (:wat::core::let*
      (((u1 :()) (:wat::test::assert-eq s2-is-peak? true)))
      (:wat::test::assert-eq s5-is-valley? true))))

;; ─── HISTORY-MAX-AGE constant ──────────────────────────────────────

(:deftest :trading::test::encoding::phase-state::test-history-max-age-is-2016
  (:wat::test::assert-eq
    (:trading::encoding::PhaseState::HISTORY-MAX-AGE)
    2016))
