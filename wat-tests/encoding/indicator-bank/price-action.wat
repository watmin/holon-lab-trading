;; wat-tests/encoding/indicator-bank/price-action.wat — Lab arc 026 slice 11.

(:wat::test::make-deftest :deftest
  ((:wat::load-file! "wat/encoding/indicator-bank/price-action.wat")))


;; ─── range-ratio ──────────────────────────────────────────────────

;; Test 1 — high/low for non-zero low.
(:deftest :trading::test::encoding::indicator-bank::test-range-ratio-known
  (:wat::test::assert-eq
    (:trading::encoding::compute-range-ratio 110.0 100.0)
    1.1))

;; Test 2 — defensive zero-low → 1.0.
(:deftest :trading::test::encoding::indicator-bank::test-range-ratio-zero-low
  (:wat::test::assert-eq
    (:trading::encoding::compute-range-ratio 110.0 0.0)
    1.0))


;; ─── gap ──────────────────────────────────────────────────────────

;; Test 3 — known gap.
(:deftest :trading::test::encoding::indicator-bank::test-gap-known
  ;; (105 - 100) / 100 = 0.05.
  (:wat::test::assert-eq
    (:trading::encoding::compute-gap 105.0 100.0)
    0.05))

;; Test 4 — defensive zero prev-close → 0.
(:deftest :trading::test::encoding::indicator-bank::test-gap-zero-prev
  (:wat::test::assert-eq
    (:trading::encoding::compute-gap 105.0 0.0)
    0.0))


;; ─── Consecutive up/down ──────────────────────────────────────────

;; Test 5 — fresh: both counters at 0.
(:deftest :trading::test::encoding::indicator-bank::test-consecutive-fresh-zero
  (:wat::core::let*
    (((s :trading::encoding::ConsecutiveState)
      (:trading::encoding::ConsecutiveState::fresh)))
    (:wat::core::let*
      (((u1 :())
        (:wat::test::assert-eq (:trading::encoding::ConsecutiveState::up s) 0)))
      (:wat::test::assert-eq (:trading::encoding::ConsecutiveState::down s) 0))))

;; Test 6 — three consecutive up candles → up-count = 3, down = 0.
(:deftest :trading::test::encoding::indicator-bank::test-consecutive-three-up
  (:wat::core::let*
    (((s0 :trading::encoding::ConsecutiveState)
      (:trading::encoding::ConsecutiveState::fresh))
     ((s1 :trading::encoding::ConsecutiveState)
      (:trading::encoding::ConsecutiveState::update s0 100.0))
     ((s2 :trading::encoding::ConsecutiveState)
      (:trading::encoding::ConsecutiveState::update s1 105.0))
     ((s3 :trading::encoding::ConsecutiveState)
      (:trading::encoding::ConsecutiveState::update s2 110.0))
     ((s4 :trading::encoding::ConsecutiveState)
      (:trading::encoding::ConsecutiveState::update s3 115.0)))
    (:wat::core::let*
      (((u1 :())
        (:wat::test::assert-eq (:trading::encoding::ConsecutiveState::up s4) 3)))
      (:wat::test::assert-eq (:trading::encoding::ConsecutiveState::down s4) 0))))

;; Test 7 — direction reversal resets the opposite counter.
(:deftest :trading::test::encoding::indicator-bank::test-consecutive-reversal
  (:wat::core::let*
    (((s0 :trading::encoding::ConsecutiveState)
      (:trading::encoding::ConsecutiveState::fresh))
     ((s1 :trading::encoding::ConsecutiveState)
      (:trading::encoding::ConsecutiveState::update s0 100.0))
     ((s2 :trading::encoding::ConsecutiveState)
      (:trading::encoding::ConsecutiveState::update s1 105.0))
     ((s3 :trading::encoding::ConsecutiveState)
      (:trading::encoding::ConsecutiveState::update s2 110.0))
     ;; Reversal — close drops below prev. up resets to 0; down starts at 1.
     ((s4 :trading::encoding::ConsecutiveState)
      (:trading::encoding::ConsecutiveState::update s3 105.0)))
    (:wat::core::let*
      (((u1 :())
        (:wat::test::assert-eq (:trading::encoding::ConsecutiveState::up s4) 0)))
      (:wat::test::assert-eq (:trading::encoding::ConsecutiveState::down s4) 1))))
