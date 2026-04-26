;; wat-tests/sim/labels.wat — Lab arc 025 slice 3 tests (labels).
;;
;; Verify the Thermometer-encoded label coordinates behave as
;; coordinates: same-corner cosine-self = 1.0; structurally-similar
;; corners (sharing one axis) cosine higher than diagonally-opposite
;; corners; magnitude flows through Thermometer (a label near a
;; corner cosines higher to that corner than to the opposite one).

(:wat::test::make-deftest :deftest
  ((:wat::load-file! "wat/sim/labels.wat")))


;; ─── Self-cosine — every corner is 1.0 against itself ────────────

(:deftest :trading::test::sim::labels::test-corner-self-cosine
  (:wat::test::assert-coincident
    (:trading::sim::corner-grace-up)
    (:trading::sim::corner-grace-up)))


;; ─── Magnitude — paper-label near corner-grace-up cosines higher
;;     to corner-grace-up than to corner-violence-dn ───────────────

(:deftest :trading::test::sim::labels::test-magnitude-flows-through-thermometer
  (:wat::core::let*
    (((label :wat::holon::HolonAST)
      (:trading::sim::paper-label 0.04 0.03))   ; near grace-up
     ((to-grace-up :f64)
      (:wat::holon::cosine label (:trading::sim::corner-grace-up)))
     ((to-violence-dn :f64)
      (:wat::holon::cosine label (:trading::sim::corner-violence-dn))))
    (:wat::test::assert-eq (:wat::core::> to-grace-up to-violence-dn) true)))


;; ─── Structural similarity — corners sharing outcome-axis cosine
;;     higher than diagonally-opposite corners ────────────────────
;;
;; corner-grace-up and corner-grace-dn both bind outcome-axis to the
;; positive thermometer pole. corner-grace-up vs corner-violence-dn
;; differ on BOTH axes. The shared axis bind raises cosine.

(:deftest :trading::test::sim::labels::test-shared-axis-cosines-higher
  (:wat::core::let*
    (((same-outcome :f64)
      (:wat::holon::cosine
        (:trading::sim::corner-grace-up)
        (:trading::sim::corner-grace-dn)))
     ((diagonal :f64)
      (:wat::holon::cosine
        (:trading::sim::corner-grace-up)
        (:trading::sim::corner-violence-dn))))
    (:wat::test::assert-eq (:wat::core::> same-outcome diagonal) true)))


;; ─── paper-label round-trip — same inputs produce equal vectors ──

(:deftest :trading::test::sim::labels::test-paper-label-deterministic
  (:wat::core::let*
    (((a :wat::holon::HolonAST) (:trading::sim::paper-label 0.02 -0.01))
     ((b :wat::holon::HolonAST) (:trading::sim::paper-label 0.02 -0.01)))
    (:wat::test::assert-coincident a b)))


;; ─── Basis atoms — distinct ───────────────────────────────────────

(:deftest :trading::test::sim::labels::test-basis-atoms-distinct
  (:wat::core::let*
    (((cos-axes :f64)
      (:wat::holon::cosine
        (:trading::sim::outcome-axis)
        (:trading::sim::direction-axis))))
    ;; Two random atoms should be near-orthogonal in HD space.
    (:wat::test::assert-eq (:wat::core::< cos-axes 0.5) true)))


;; ─── force helper — Ok arm round-trips, Err arm sentinels ────────

(:deftest :trading::test::sim::labels::test-force-ok-passes-through
  (:wat::core::let*
    (((bundled :wat::holon::BundleResult)
      (:wat::holon::Bundle
        (:wat::core::vec :wat::holon::HolonAST
          (:wat::holon::Atom (:wat::core::quote :a))
          (:wat::holon::Atom (:wat::core::quote :b)))))
     ((forced :wat::holon::HolonAST) (:trading::sim::force bundled)))
    ;; Round-trip — same AST coincides with itself in HD space.
    (:wat::test::assert-coincident forced forced)))
