;; wat-tests/encoding/indicator-bank/divergence.wat — Lab arc 026 slice 11.

(:wat::test::make-deftest :deftest
  ((:wat::load-file! "wat/encoding/indicator-bank/divergence.wat")))


;; ─── detect-divergence ────────────────────────────────────────────

;; Test 1 — under-5 input → (0.0, 0.0) tuple.
(:deftest :trading::test::encoding::indicator-bank::test-divergence-short-zero
  (:wat::core::let*
    (((prices :Vec<f64>) (:wat::core::vec :f64 100.0 101.0))
     ((rsis :Vec<f64>) (:wat::core::vec :f64 50.0 51.0))
     ((d :(f64,f64))
      (:trading::encoding::detect-divergence prices rsis))
     ((bull :f64) (:wat::core::first d))
     ((bear :f64) (:wat::core::second d)))
    (:wat::core::let*
      (((u1 :()) (:wat::test::assert-eq bull 0.0)))
      (:wat::test::assert-eq bear 0.0))))

;; Test 2 — bull divergence: price lower-low + RSI higher-low.
(:deftest :trading::test::encoding::indicator-bank::test-divergence-bull-detected
  (:wat::core::let*
    (((prices :Vec<f64>)
      ;; First half lows ~100; second half makes lower low ~95.
      (:wat::core::vec :f64 100.0 102.0 100.0 98.0 95.0 96.0))
     ((rsis :Vec<f64>)
      ;; First half lows ~30; second half makes higher low ~35.
      (:wat::core::vec :f64 30.0 35.0 32.0 35.0 38.0 40.0))
     ((d :(f64,f64))
      (:trading::encoding::detect-divergence prices rsis))
     ((bull :f64) (:wat::core::first d)))
    (:wat::test::assert-eq (:wat::core::> bull 0.0) true)))

;; Test 3 — flat input → (0.0, 0.0).
(:deftest :trading::test::encoding::indicator-bank::test-divergence-flat-zero
  (:wat::core::let*
    (((prices :Vec<f64>)
      (:wat::core::vec :f64 100.0 100.0 100.0 100.0 100.0 100.0))
     ((rsis :Vec<f64>)
      (:wat::core::vec :f64 50.0 50.0 50.0 50.0 50.0 50.0))
     ((d :(f64,f64))
      (:trading::encoding::detect-divergence prices rsis))
     ((bull :f64) (:wat::core::first d))
     ((bear :f64) (:wat::core::second d)))
    (:wat::core::let*
      (((u1 :()) (:wat::test::assert-eq bull 0.0)))
      (:wat::test::assert-eq bear 0.0))))


;; ─── stoch-cross-delta ────────────────────────────────────────────

;; Test 4 — stoch-cross-delta: simple subtraction.
(:deftest :trading::test::encoding::indicator-bank::test-stoch-cross-delta
  (:wat::test::assert-eq
    (:trading::encoding::compute-stoch-cross-delta 5.0 3.0)
    2.0))
