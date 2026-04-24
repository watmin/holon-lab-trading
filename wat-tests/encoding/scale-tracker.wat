;; wat-tests/encoding/scale-tracker.wat — Phase 3.2 tests.
;;
;; Tests :trading::encoding::ScaleTracker (::fresh, ::update, ::scale)
;; against its source at wat/encoding/scale-tracker.wat.
;;
;; Arc 003 retrofit: uses arc 031's make-deftest + inherited-config
;; shape. Outer preamble commits dims + capacity-mode once; sandbox
;; inherits. Default-prelude loads the module plus a tail-recursive
;; helper used by the convergence test.

(:wat::config::set-capacity-mode! :error)
(:wat::config::set-dims! 1024)

(:wat::test::make-deftest :deftest
  ((:wat::load-file! "wat/encoding/scale-tracker.wat")
   (:wat::core::define
     (:test::repeat-update
       (t :trading::encoding::ScaleTracker)
       (v :f64)
       (n :i64)
       -> :trading::encoding::ScaleTracker)
     (:wat::core::if (:wat::core::<= n 0)
                     -> :trading::encoding::ScaleTracker
       t
       (:test::repeat-update
         (:trading::encoding::ScaleTracker::update t v)
         v
         (:wat::core::i64::- n 1))))))

;; ─── ::fresh — zero-tracker invariants ────────────────────────────

(:deftest :trading::test::encoding::scale-tracker::test-fresh-has-zero-count
  (:wat::core::let*
    (((t :trading::encoding::ScaleTracker)
      (:trading::encoding::ScaleTracker::fresh)))
    (:wat::test::assert-eq
      (:trading::encoding::ScaleTracker/count t)
      0)))

(:deftest :trading::test::encoding::scale-tracker::test-fresh-has-zero-ema
  (:wat::core::let*
    (((t :trading::encoding::ScaleTracker)
      (:trading::encoding::ScaleTracker::fresh)))
    (:wat::test::assert-eq
      (:trading::encoding::ScaleTracker/ema-abs t)
      0.0)))

;; ─── ::update — count + EMA progression ──────────────────────────

(:deftest :trading::test::encoding::scale-tracker::test-update-increments-count
  (:wat::core::let*
    (((t0 :trading::encoding::ScaleTracker)
      (:trading::encoding::ScaleTracker::fresh))
     ((t1 :trading::encoding::ScaleTracker)
      (:trading::encoding::ScaleTracker::update t0 0.5))
     ((t2 :trading::encoding::ScaleTracker)
      (:trading::encoding::ScaleTracker::update t1 0.5)))
    (:wat::test::assert-eq
      (:trading::encoding::ScaleTracker/count t2)
      2)))

;; Negative values are absolute-value'd before EMA blend; feeding +0.5
;; and -0.5 should produce the same EMA as feeding +0.5 twice.
(:deftest :trading::test::encoding::scale-tracker::test-update-takes-abs-of-value
  (:wat::core::let*
    (((pos :trading::encoding::ScaleTracker)
      (:trading::encoding::ScaleTracker::update
        (:trading::encoding::ScaleTracker::fresh) 0.5))
     ((neg :trading::encoding::ScaleTracker)
      (:trading::encoding::ScaleTracker::update
        (:trading::encoding::ScaleTracker::fresh) -0.5)))
    (:wat::test::assert-eq
      (:trading::encoding::ScaleTracker/ema-abs pos)
      (:trading::encoding::ScaleTracker/ema-abs neg))))

;; ─── ::scale — floor + convergence ───────────────────────────────

;; Fresh tracker has EMA 0 → scale = max(0, 0.001) rounded = 0.0
;; (the 0.001 floor rounds away at 2 decimals).
(:deftest :trading::test::encoding::scale-tracker::test-scale-of-fresh-is-zero
  (:wat::core::let*
    (((t :trading::encoding::ScaleTracker)
      (:trading::encoding::ScaleTracker::fresh)))
    (:wat::test::assert-eq
      (:trading::encoding::ScaleTracker::scale t)
      0.0)))

;; Convergence — feeding a constant value many times drives EMA→|v|
;; and scale→2·|v| (floored + rounded). At d=1024, alpha=1/max(count,100)
;; means the first 99 iterations blend at 0.01 reaching EMA≈0.315;
;; subsequent iterations use alpha=1/count, which gives the closed-form
;; EMA_K = 0.315·(99/K) + 0.5·(K-99)/K for K≥100. At K=10_000 with v=0.5
;; that's EMA≈0.4982 → scale 0.9964 → rounded to 2 = 1.00. Proof that
;; the tracker converges to the expected long-run scale.
;;
;; The :test::repeat-update helper lives in the deftest factory's
;; default-prelude — every test has access; only this one uses it.
(:deftest :trading::test::encoding::scale-tracker::test-converges-to-twice-ema
  (:wat::core::let*
    (((fresh :trading::encoding::ScaleTracker)
      (:trading::encoding::ScaleTracker::fresh))
     ((trained :trading::encoding::ScaleTracker)
      (:test::repeat-update fresh 0.5 10000)))
    ;; EMA converges to 0.5 → scale = round(2·0.5, 2) = 1.00
    (:wat::test::assert-eq
      (:trading::encoding::ScaleTracker::scale trained)
      1.0)))
