;; wat-tests/sim/types.wat — Lab arc 025 slice 3 tests (types).
;;
;; Round-trip every struct + variant to confirm the type surface is
;; coherent. No logic exercised here — that's slice 4's territory.

(:wat::test::make-deftest :deftest
  ((:wat::load-file! "wat/sim/types.wat")))


;; ─── Struct round-trip — Aggregate ────────────────────────────────

(:deftest :trading::test::sim::types::test-aggregate-round-trip
  (:wat::core::let*
    (((agg :trading::sim::Aggregate)
      (:trading::sim::Aggregate/new 5 3 2 0.42 0.08)))
    (:wat::core::let*
      (((u1 :())
        (:wat::test::assert-eq (:trading::sim::Aggregate/papers agg) 5))
       ((u2 :())
        (:wat::test::assert-eq (:trading::sim::Aggregate/grace-count agg) 3))
       ((u3 :())
        (:wat::test::assert-eq (:trading::sim::Aggregate/violence-count agg) 2))
       ((u4 :())
        (:wat::test::assert-eq (:trading::sim::Aggregate/total-residue agg) 0.42)))
      (:wat::test::assert-eq (:trading::sim::Aggregate/total-loss agg) 0.08))))


;; ─── Struct round-trip — Config defaults shape ────────────────────

(:deftest :trading::test::sim::types::test-config-round-trip
  (:wat::core::let*
    (((cfg :trading::sim::Config)
      (:trading::sim::Config/new 288 0.01 35.0 14)))
    (:wat::core::let*
      (((u1 :()) (:wat::test::assert-eq (:trading::sim::Config/deadline cfg) 288))
       ((u2 :()) (:wat::test::assert-eq (:trading::sim::Config/min-residue cfg) 0.01))
       ((u3 :()) (:wat::test::assert-eq (:trading::sim::Config/fee-bps cfg) 35.0)))
      (:wat::test::assert-eq (:trading::sim::Config/atr-period cfg) 14))))


;; ─── Variant construction — Action ────────────────────────────────

(:deftest :trading::test::sim::types::test-action-open-up
  (:wat::core::let*
    (((a :trading::sim::Action)
      (:trading::sim::Action::Open :trading::sim::Direction::Up))
     ((is-open-up? :bool)
      (:wat::core::match a -> :bool
        ((:trading::sim::Action::Open dir)
          (:wat::core::match dir -> :bool
            (:trading::sim::Direction::Up true)
            (_ false)))
        (_ false))))
    (:wat::test::assert-eq is-open-up? true)))

(:deftest :trading::test::sim::types::test-action-hold-and-exit
  (:wat::core::let*
    (((h :trading::sim::Action) :trading::sim::Action::Hold)
     ((e :trading::sim::Action) :trading::sim::Action::Exit)
     ((h-is-hold? :bool)
      (:wat::core::match h -> :bool
        (:trading::sim::Action::Hold true)
        (_ false)))
     ((e-is-exit? :bool)
      (:wat::core::match e -> :bool
        (:trading::sim::Action::Exit true)
        (_ false))))
    (:wat::core::let*
      (((u1 :()) (:wat::test::assert-eq h-is-hold? true)))
      (:wat::test::assert-eq e-is-exit? true))))


;; ─── Variant construction — PositionState ─────────────────────────

(:deftest :trading::test::sim::types::test-position-state-grace-residue
  (:wat::core::let*
    (((ps :trading::sim::PositionState)
      (:trading::sim::PositionState::Grace 0.04))
     ((residue :f64)
      (:wat::core::match ps -> :f64
        ((:trading::sim::PositionState::Grace r) r)
        (:trading::sim::PositionState::Active 0.0)
        (:trading::sim::PositionState::Violence 0.0))))
    (:wat::test::assert-eq residue 0.04)))


;; ─── TriggerEvent carries surface (Chapter 55) ────────────────────

(:deftest :trading::test::sim::types::test-trigger-event-carries-surface
  (:wat::core::let*
    (;; A small surface AST — atom of an opaque marker.
     ((surf :wat::holon::HolonAST)
      (:wat::holon::Atom (:wat::core::quote :test-surface)))
     ((te :trading::sim::TriggerEvent)
      (:trading::sim::TriggerEvent/new
        42
        :trading::types::PhaseLabel::Peak
        :trading::sim::Decision::Hold
        surf))
     ;; Round-trip: cosine of the field's surface against itself = 1.
     ((self-cos :f64)
      (:wat::holon::cosine
        (:trading::sim::TriggerEvent/surface te)
        surf)))
    (:wat::test::assert-eq self-cos 1.0)))


;; ─── Thinker + Predictor records constructible ────────────────────

(:deftest :trading::test::sim::types::test-thinker-and-predictor-constructible
  (:wat::core::let*
    (((thinker :trading::sim::Thinker)
      (:trading::sim::Thinker/new
        (:wat::core::lambda
          ((window :trading::types::Candles)
           (pos :Option<trading::sim::Paper>)
           -> :wat::holon::HolonAST)
          (:wat::holon::Atom (:wat::core::quote :empty)))))
     ((predictor :trading::sim::Predictor)
      (:trading::sim::Predictor/new
        (:wat::core::lambda
          ((surface :wat::holon::HolonAST)
           -> :trading::sim::Action)
          :trading::sim::Action::Hold)))
     ;; Smoke — can we apply the predictor? Hold-thinker's surface
     ;; is irrelevant to the predictor since this predictor ignores
     ;; its argument and always returns Hold.
     ((dummy :wat::holon::HolonAST)
      (:wat::holon::Atom (:wat::core::quote :anything)))
     ((action :trading::sim::Action)
      ((:trading::sim::Predictor/predict predictor) dummy))
     ((is-hold? :bool)
      (:wat::core::match action -> :bool
        (:trading::sim::Action::Hold true)
        (_ false))))
    (:wat::test::assert-eq is-hold? true)))
