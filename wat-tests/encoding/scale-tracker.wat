;; wat-tests/encoding/scale-tracker.wat — Phase 3.2 tests.
;;
;; Tests :trading::encoding::ScaleTracker (::fresh, ::update, ::scale)
;; against its source at wat/encoding/scale-tracker.wat.
;;
;; Arc 003 retrofit: uses arc 031's make-deftest + inherited-config
;; shape. Outer preamble commits dims + capacity-mode once; sandbox
;; inherits. Default-prelude loads the module plus a tail-recursive
;; helper used by the convergence test.


(:wat::test::make-deftest :deftest
  ((:wat::load-file! "wat/encoding/scale-tracker.wat")
   (:wat::core::define
     (:test::repeat-update
       (t :trading::encoding::ScaleTracker)
       (v :wat::core::f64)
       (n :wat::core::i64)
       -> :trading::encoding::ScaleTracker)
     (:wat::core::if (:wat::core::<= n 0)
                     -> :trading::encoding::ScaleTracker
       t
       (:test::repeat-update
         (:trading::encoding::ScaleTracker::update t v)
         v
         (:wat::core::- n 1))))))

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

;; ─── arc 012 — geometric bucketing ──────────────────────────────

;; bucket-width = scale × noise-floor. At d=1024, noise-floor = 1/32
;; = 0.03125. So scale=1.0 → bucket-width = 0.03125. scale=0.5 →
;; bucket-width = 0.015625.
(:deftest :trading::test::encoding::scale-tracker::test-bucket-width-matches-scale-times-noise-floor
  (:wat::core::let*
    (((bw-at-1 :wat::core::f64) (:trading::encoding::ScaleTracker::bucket-width 1.0))
     ((bw-at-half :wat::core::f64) (:trading::encoding::ScaleTracker::bucket-width 0.5))
     ((nf :wat::core::f64) (:wat::config::noise-floor)))
    (:wat::test::assert-eq
      bw-at-1
      nf)))

;; Two values inside the same bucket get snapped to the same output.
;; Bucket-width is dim-relative: scale × noise-floor, where
;; noise-floor = 1/sqrt(d). The test reads the actual bucket-width
;; at runtime and offsets the second value by 0.25 × bucket-width
;; (well within one bucket) — honest at any default dim, no
;; hand-calibration to a specific d.
(:deftest :trading::test::encoding::scale-tracker::test-values-in-same-bucket-snap-identical
  (:wat::core::let*
    (((bw :wat::core::f64) (:trading::encoding::ScaleTracker::bucket-width 1.0))
     ((within :wat::core::f64) (:wat::core::* 0.25 bw))
     ((a :wat::core::f64) (:trading::encoding::ScaleTracker::bucket 0.50 1.0))
     ((b :wat::core::f64)
       (:trading::encoding::ScaleTracker::bucket
         (:wat::core::+ 0.50 within) 1.0)))
    (:wat::test::assert-eq a b)))

;; Values across bucket boundaries snap to different outputs.
;; Use 5 × bucket-width — clearly across multiple buckets at any d.
(:deftest :trading::test::encoding::scale-tracker::test-values-across-buckets-differ
  (:wat::core::let*
    (((bw :wat::core::f64) (:trading::encoding::ScaleTracker::bucket-width 1.0))
     ((across :wat::core::f64) (:wat::core::* 5.0 bw))
     ((a :wat::core::f64) (:trading::encoding::ScaleTracker::bucket 0.50 1.0))
     ((b :wat::core::f64)
       (:trading::encoding::ScaleTracker::bucket
         (:wat::core::+ 0.50 across) 1.0))
     ((different :wat::core::bool)
      (:wat::core::not (:wat::core::= a b))))
    (:wat::test::assert-eq different true)))

;; Bucketing is idempotent — running it twice gives the same result.
;; bucket(bucket(V, s), s) == bucket(V, s). Critical for cache-key
;; stability under repeated lookup.
(:deftest :trading::test::encoding::scale-tracker::test-bucket-idempotent
  (:wat::core::let*
    (((once :wat::core::f64) (:trading::encoding::ScaleTracker::bucket 0.51 1.0))
     ((twice :wat::core::f64) (:trading::encoding::ScaleTracker::bucket once 1.0)))
    (:wat::test::assert-eq once twice)))

;; Zero-scale fallback — Option B. When scale is 0, bucket-width is 0,
;; bucket returns value unchanged (defensive against the pre-arc-012
;; ScaleTracker::scale formula quirk that can emit 0.00 for fresh
;; trackers with zero EMA).
(:deftest :trading::test::encoding::scale-tracker::test-bucket-zero-scale-returns-value
  (:wat::core::let*
    (((result :wat::core::f64) (:trading::encoding::ScaleTracker::bucket 0.42 0.0)))
    (:wat::test::assert-eq result 0.42)))
