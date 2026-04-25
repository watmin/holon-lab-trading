;; wat-tests/encoding/indicator-bank/persistence.wat — Lab arc 026 slice 9.
;;
;; Statistical-estimator slice; tests cover Hurst (random-walk-ish vs
;; trending), autocorrelation (lag-1 sanity), and VwapState (running
;; weighted-mean distance).

(:wat::test::make-deftest :deftest
  ((:wat::load-file! "wat/encoding/indicator-bank/persistence.wat")))


;; ─── Hurst ───────────────────────────────────────────────────────

;; Test 1 — short input → 0.5 (under 8 closes).
(:deftest :trading::test::encoding::indicator-bank::test-hurst-short-is-half
  (:wat::core::let*
    (((closes :Vec<f64>)
      (:wat::core::vec :f64 100.0 101.0 102.0 103.0)))
    (:wat::test::assert-eq
      (:trading::encoding::compute-hurst closes)
      0.5)))

;; Test 2 — flat input → 0.5 (returns all 0 → s=0 → 0.5 fallback).
(:deftest :trading::test::encoding::indicator-bank::test-hurst-flat-is-half
  (:wat::core::let*
    (((closes :Vec<f64>)
      (:wat::core::vec :f64 100.0 100.0 100.0 100.0 100.0 100.0 100.0 100.0 100.0 100.0)))
    (:wat::test::assert-eq
      (:trading::encoding::compute-hurst closes)
      0.5)))

;; Test 3 — strong monotonic uptrend → Hurst > 0.5 (persistent).
(:deftest :trading::test::encoding::indicator-bank::test-hurst-trending-above-half
  (:wat::core::let*
    (((closes :Vec<f64>)
      (:wat::core::vec :f64 100.0 102.0 104.0 106.0 108.0 110.0 112.0 114.0 116.0 118.0 120.0 122.0))
     ((h :f64) (:trading::encoding::compute-hurst closes)))
    (:wat::test::assert-eq (:wat::core::> h 0.5) true)))


;; ─── Autocorrelation ─────────────────────────────────────────────

;; Test 4 — short input → 0.
(:deftest :trading::test::encoding::indicator-bank::test-autocorr-short-zero
  (:wat::core::let*
    (((xs :Vec<f64>)
      (:wat::core::vec :f64 1.0 2.0)))
    (:wat::test::assert-eq
      (:trading::encoding::compute-autocorrelation-lag1 xs)
      0.0)))

;; Test 5 — flat input → 0 (variance=0).
(:deftest :trading::test::encoding::indicator-bank::test-autocorr-flat-zero
  (:wat::core::let*
    (((xs :Vec<f64>)
      (:wat::core::vec :f64 5.0 5.0 5.0 5.0 5.0)))
    (:wat::test::assert-eq
      (:trading::encoding::compute-autocorrelation-lag1 xs)
      0.0)))

;; Test 6 — strong positive autocorrelation: monotonic series.
(:deftest :trading::test::encoding::indicator-bank::test-autocorr-monotonic-positive
  (:wat::core::let*
    (((xs :Vec<f64>)
      (:wat::core::vec :f64 1.0 2.0 3.0 4.0 5.0 6.0 7.0 8.0 9.0 10.0))
     ((ac :f64) (:trading::encoding::compute-autocorrelation-lag1 xs)))
    (:wat::test::assert-eq (:wat::core::> ac 0.0) true)))

;; Test 7 — alternating sequence → strongly negative autocorrelation.
(:deftest :trading::test::encoding::indicator-bank::test-autocorr-alternating-negative
  (:wat::core::let*
    (((xs :Vec<f64>)
      (:wat::core::vec :f64 1.0 -1.0 1.0 -1.0 1.0 -1.0 1.0 -1.0))
     ((ac :f64) (:trading::encoding::compute-autocorrelation-lag1 xs)))
    (:wat::test::assert-eq (:wat::core::< ac 0.0) true)))


;; ─── VWAP distance ───────────────────────────────────────────────

;; Test 8 — fresh: distance is 0 (cum_vol=0 fallback).
(:deftest :trading::test::encoding::indicator-bank::test-vwap-fresh-zero
  (:wat::core::let*
    (((s :trading::encoding::VwapState)
      (:trading::encoding::VwapState::fresh)))
    (:wat::test::assert-eq
      (:trading::encoding::VwapState::distance s 100.0)
      0.0)))

;; Test 9 — single observation: VWAP equals close → distance = 0.
(:deftest :trading::test::encoding::indicator-bank::test-vwap-single-obs-zero
  (:wat::core::let*
    (((s0 :trading::encoding::VwapState)
      (:trading::encoding::VwapState::fresh))
     ((s1 :trading::encoding::VwapState)
      (:trading::encoding::VwapState::update s0 100.0 50.0)))
    (:wat::test::assert-eq
      (:trading::encoding::VwapState::distance s1 100.0)
      0.0)))

;; Test 10 — close above VWAP → positive distance.
(:deftest :trading::test::encoding::indicator-bank::test-vwap-close-above
  (:wat::core::let*
    (((s0 :trading::encoding::VwapState)
      (:trading::encoding::VwapState::fresh))
     ((s1 :trading::encoding::VwapState)
      (:trading::encoding::VwapState::update s0 100.0 50.0))
     ((s2 :trading::encoding::VwapState)
      (:trading::encoding::VwapState::update s1 100.0 50.0))
     ;; cum_pv = 100·50 + 100·50 = 10000; cum_vol = 100; vwap = 100.
     ;; close = 110 → (110 - 100) / 110 ≈ 0.0909.
     ((d :f64) (:trading::encoding::VwapState::distance s2 110.0)))
    (:wat::test::assert-eq (:wat::core::> d 0.0) true)))
