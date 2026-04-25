;; wat-tests/encoding/indicator-bank/volume.wat — Lab arc 026 slice 5.
;;
;; Tests OBV + volume-accel + the linreg-slope free function.

(:wat::test::make-deftest :deftest
  ((:wat::load-file! "wat/encoding/indicator-bank/volume.wat")

   (:wat::core::define
     (:test::obv-feed
       (s :trading::encoding::ObvState)
       (c :f64) (v :f64)
       (n :i64)
       -> :trading::encoding::ObvState)
     (:wat::core::if (:wat::core::<= n 0)
                     -> :trading::encoding::ObvState
       s
       (:test::obv-feed
         (:trading::encoding::ObvState::update s c v)
         c v
         (:wat::core::- n 1))))))


;; ─── linreg-slope ────────────────────────────────────────────────

;; Test 1 — perfect linear y = 2x + 1 → slope 2.
(:deftest :trading::test::encoding::indicator-bank::test-linreg-perfect-line
  (:wat::core::let*
    (((ys :Vec<f64>)
      (:wat::core::vec :f64 1.0 3.0 5.0 7.0 9.0))
     ((slope :f64) (:trading::encoding::compute-linreg-slope ys)))
    (:wat::test::assert-eq slope 2.0)))

;; Test 2 — flat input → slope 0.
(:deftest :trading::test::encoding::indicator-bank::test-linreg-flat-zero
  (:wat::core::let*
    (((ys :Vec<f64>)
      (:wat::core::vec :f64 5.0 5.0 5.0 5.0 5.0))
     ((slope :f64) (:trading::encoding::compute-linreg-slope ys)))
    (:wat::test::assert-eq slope 0.0)))


;; ─── OBV ─────────────────────────────────────────────────────────

;; Test 3 — fresh: obv 0, slope 0.
(:deftest :trading::test::encoding::indicator-bank::test-obv-fresh-zero
  (:wat::core::let*
    (((s :trading::encoding::ObvState)
      (:trading::encoding::ObvState::fresh 12)))
    (:wat::core::let*
      (((u1 :())
        (:wat::test::assert-eq (:trading::encoding::ObvState::value s) 0.0)))
      (:wat::test::assert-eq (:trading::encoding::ObvState::slope s) 0.0))))

;; Test 4 — sustained up-close → OBV monotonically grows; slope > 0.
(:deftest :trading::test::encoding::indicator-bank::test-obv-uptrend-slope-positive
  (:wat::core::let*
    (((s0 :trading::encoding::ObvState)
      (:trading::encoding::ObvState::fresh 12))
     ;; First call seeds. Then 8 rising candles.
     ((s1 :trading::encoding::ObvState) (:trading::encoding::ObvState::update s0 100.0 50.0))
     ((s2 :trading::encoding::ObvState) (:trading::encoding::ObvState::update s1 102.0 50.0))
     ((s3 :trading::encoding::ObvState) (:trading::encoding::ObvState::update s2 104.0 50.0))
     ((s4 :trading::encoding::ObvState) (:trading::encoding::ObvState::update s3 106.0 50.0))
     ((s5 :trading::encoding::ObvState) (:trading::encoding::ObvState::update s4 108.0 50.0))
     ((s6 :trading::encoding::ObvState) (:trading::encoding::ObvState::update s5 110.0 50.0))
     ((s7 :trading::encoding::ObvState) (:trading::encoding::ObvState::update s6 112.0 50.0))
     ((s8 :trading::encoding::ObvState) (:trading::encoding::ObvState::update s7 114.0 50.0))
     ((obv :f64) (:trading::encoding::ObvState::value s8))
     ((slope :f64) (:trading::encoding::ObvState::slope s8)))
    (:wat::core::let*
      (((u1 :()) (:wat::test::assert-eq (:wat::core::> obv 0.0) true)))
      (:wat::test::assert-eq (:wat::core::> slope 0.0) true))))

;; Test 5 — sustained down-close → OBV negative; slope < 0.
(:deftest :trading::test::encoding::indicator-bank::test-obv-downtrend-slope-negative
  (:wat::core::let*
    (((s0 :trading::encoding::ObvState)
      (:trading::encoding::ObvState::fresh 12))
     ((s1 :trading::encoding::ObvState) (:trading::encoding::ObvState::update s0 100.0 50.0))
     ((s2 :trading::encoding::ObvState) (:trading::encoding::ObvState::update s1 98.0 50.0))
     ((s3 :trading::encoding::ObvState) (:trading::encoding::ObvState::update s2 96.0 50.0))
     ((s4 :trading::encoding::ObvState) (:trading::encoding::ObvState::update s3 94.0 50.0))
     ((s5 :trading::encoding::ObvState) (:trading::encoding::ObvState::update s4 92.0 50.0))
     ((s6 :trading::encoding::ObvState) (:trading::encoding::ObvState::update s5 90.0 50.0))
     ((s7 :trading::encoding::ObvState) (:trading::encoding::ObvState::update s6 88.0 50.0))
     ((s8 :trading::encoding::ObvState) (:trading::encoding::ObvState::update s7 86.0 50.0))
     ((obv :f64) (:trading::encoding::ObvState::value s8))
     ((slope :f64) (:trading::encoding::ObvState::slope s8)))
    (:wat::core::let*
      (((u1 :()) (:wat::test::assert-eq (:wat::core::< obv 0.0) true)))
      (:wat::test::assert-eq (:wat::core::< slope 0.0) true))))


;; ─── VolumeAccel ─────────────────────────────────────────────────

;; Test 6 — fresh: value defaults to 1.0 (sma=0 → fallback).
(:deftest :trading::test::encoding::indicator-bank::test-volume-accel-fresh-is-one
  (:wat::core::let*
    (((s :trading::encoding::VolumeAccelState)
      (:trading::encoding::VolumeAccelState::fresh 20)))
    (:wat::test::assert-eq
      (:trading::encoding::VolumeAccelState::value s)
      1.0)))

;; Test 7 — flat input → ratio = 1.0 (volume == its own SMA).
(:deftest :trading::test::encoding::indicator-bank::test-volume-accel-flat-is-one
  (:wat::core::let*
    (((s0 :trading::encoding::VolumeAccelState)
      (:trading::encoding::VolumeAccelState::fresh 5))
     ((s1 :trading::encoding::VolumeAccelState)
      (:trading::encoding::VolumeAccelState::update s0 100.0))
     ((s2 :trading::encoding::VolumeAccelState)
      (:trading::encoding::VolumeAccelState::update s1 100.0))
     ((s3 :trading::encoding::VolumeAccelState)
      (:trading::encoding::VolumeAccelState::update s2 100.0))
     ((s4 :trading::encoding::VolumeAccelState)
      (:trading::encoding::VolumeAccelState::update s3 100.0))
     ((s5 :trading::encoding::VolumeAccelState)
      (:trading::encoding::VolumeAccelState::update s4 100.0)))
    (:wat::test::assert-eq
      (:trading::encoding::VolumeAccelState::value s5)
      1.0)))

;; Test 8 — volume spike → ratio > 1.
(:deftest :trading::test::encoding::indicator-bank::test-volume-accel-spike
  (:wat::core::let*
    (((s0 :trading::encoding::VolumeAccelState)
      (:trading::encoding::VolumeAccelState::fresh 5))
     ((s1 :trading::encoding::VolumeAccelState) (:trading::encoding::VolumeAccelState::update s0 100.0))
     ((s2 :trading::encoding::VolumeAccelState) (:trading::encoding::VolumeAccelState::update s1 100.0))
     ((s3 :trading::encoding::VolumeAccelState) (:trading::encoding::VolumeAccelState::update s2 100.0))
     ((s4 :trading::encoding::VolumeAccelState) (:trading::encoding::VolumeAccelState::update s3 100.0))
     ((s5 :trading::encoding::VolumeAccelState) (:trading::encoding::VolumeAccelState::update s4 200.0))  ;; spike
     ((ratio :f64) (:trading::encoding::VolumeAccelState::value s5)))
    ;; SMA(5) of {100,100,100,100,200} = 120; ratio = 200/120 ≈ 1.67.
    (:wat::test::assert-eq (:wat::core::> ratio 1.5) true)))
