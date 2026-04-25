;; wat-tests/encoding/indicator-bank/rate.wat — Lab arc 026 slice 6.
;;
;; Tests compute-roc + compute-range-pos. Pure functions; no state.

(:wat::test::make-deftest :deftest
  ((:wat::load-file! "wat/encoding/indicator-bank/rate.wat")

   ;; Helper: build a RingBuffer from an explicit Vec<f64>.
   (:wat::core::define
     (:test::ring-from-vec
       (vs :Vec<f64>)
       (cap :i64)
       -> :trading::encoding::RingBuffer)
     (:wat::core::foldl vs
       (:trading::encoding::RingBuffer::fresh cap)
       (:wat::core::lambda
         ((b :trading::encoding::RingBuffer) (x :f64)
          -> :trading::encoding::RingBuffer)
         (:trading::encoding::RingBuffer::push b x))))))


;; ─── ROC ─────────────────────────────────────────────────────────

;; Test 1 — buffer too short for n=3 → 0.0.
(:deftest :trading::test::encoding::indicator-bank::test-roc-short-buf-zero
  (:wat::core::let*
    (((buf :trading::encoding::RingBuffer)
      (:test::ring-from-vec
        (:wat::core::vec :f64 100.0 101.0)
        10)))
    (:wat::test::assert-eq
      (:trading::encoding::compute-roc buf 3)
      0.0)))

;; Test 2 — known ROC: closes [100, 105, 110] at n=2 → (110 - 100) / 100 = 0.10.
(:deftest :trading::test::encoding::indicator-bank::test-roc-known
  (:wat::core::let*
    (((buf :trading::encoding::RingBuffer)
      (:test::ring-from-vec
        (:wat::core::vec :f64 100.0 105.0 110.0)
        10)))
    (:wat::test::assert-eq
      (:trading::encoding::compute-roc buf 2)
      0.1)))

;; Test 3 — ROC monotonically rising input → positive.
(:deftest :trading::test::encoding::indicator-bank::test-roc-monotonic-positive
  (:wat::core::let*
    (((buf :trading::encoding::RingBuffer)
      (:test::ring-from-vec
        (:wat::core::vec :f64 100.0 101.0 102.0 103.0 104.0 105.0)
        10))
     ((roc :f64) (:trading::encoding::compute-roc buf 5)))
    (:wat::test::assert-eq (:wat::core::> roc 0.0) true)))

;; Test 4 — ROC with past = 0 → 0 (defensive).
(:deftest :trading::test::encoding::indicator-bank::test-roc-past-zero
  (:wat::core::let*
    (((buf :trading::encoding::RingBuffer)
      (:test::ring-from-vec
        (:wat::core::vec :f64 0.0 1.0 2.0 3.0)
        10)))
    (:wat::test::assert-eq
      (:trading::encoding::compute-roc buf 3)
      0.0)))


;; ─── Range-pos ───────────────────────────────────────────────────

;; Test 5 — close at midpoint → 0.5.
(:deftest :trading::test::encoding::indicator-bank::test-range-pos-midpoint
  (:wat::core::let*
    (((hi :trading::encoding::RingBuffer)
      (:test::ring-from-vec
        (:wat::core::vec :f64 110.0 110.0 110.0)
        10))
     ((lo :trading::encoding::RingBuffer)
      (:test::ring-from-vec
        (:wat::core::vec :f64 100.0 100.0 100.0)
        10)))
    (:wat::test::assert-eq
      (:trading::encoding::compute-range-pos hi lo 105.0)
      0.5)))

;; Test 6 — close at high → 1.0.
(:deftest :trading::test::encoding::indicator-bank::test-range-pos-at-high
  (:wat::core::let*
    (((hi :trading::encoding::RingBuffer)
      (:test::ring-from-vec
        (:wat::core::vec :f64 110.0 110.0)
        10))
     ((lo :trading::encoding::RingBuffer)
      (:test::ring-from-vec
        (:wat::core::vec :f64 100.0 100.0)
        10)))
    (:wat::test::assert-eq
      (:trading::encoding::compute-range-pos hi lo 110.0)
      1.0)))

;; Test 7 — close at low → 0.0.
(:deftest :trading::test::encoding::indicator-bank::test-range-pos-at-low
  (:wat::core::let*
    (((hi :trading::encoding::RingBuffer)
      (:test::ring-from-vec
        (:wat::core::vec :f64 110.0 110.0)
        10))
     ((lo :trading::encoding::RingBuffer)
      (:test::ring-from-vec
        (:wat::core::vec :f64 100.0 100.0)
        10)))
    (:wat::test::assert-eq
      (:trading::encoding::compute-range-pos hi lo 100.0)
      0.0)))

;; Test 8 — degenerate (high == low) → 0.5 fallback.
(:deftest :trading::test::encoding::indicator-bank::test-range-pos-degenerate
  (:wat::core::let*
    (((hi :trading::encoding::RingBuffer)
      (:test::ring-from-vec
        (:wat::core::vec :f64 100.0 100.0)
        10))
     ((lo :trading::encoding::RingBuffer)
      (:test::ring-from-vec
        (:wat::core::vec :f64 100.0 100.0)
        10)))
    (:wat::test::assert-eq
      (:trading::encoding::compute-range-pos hi lo 100.0)
      0.5)))
