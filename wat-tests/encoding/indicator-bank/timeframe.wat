;; wat-tests/encoding/indicator-bank/timeframe.wat — Lab arc 026 slice 7.

(:wat::test::make-deftest :deftest
  ((:wat::load-file! "wat/encoding/indicator-bank/timeframe.wat")

   (:wat::core::define
     (:test::ring-from-vec
       (vs :Vec<f64>)
       (cap :wat::core::i64)
       -> :trading::encoding::RingBuffer)
     (:wat::core::foldl vs
       (:trading::encoding::RingBuffer::fresh cap)
       (:wat::core::lambda
         ((b :trading::encoding::RingBuffer) (x :wat::core::f64)
          -> :trading::encoding::RingBuffer)
         (:trading::encoding::RingBuffer::push b x))))))


;; ─── tf-ret ──────────────────────────────────────────────────────

;; Test 1 — short buffer (<2) → 0.
(:deftest :trading::test::encoding::indicator-bank::test-tf-ret-short-zero
  (:wat::core::let*
    (((buf :trading::encoding::RingBuffer)
      (:test::ring-from-vec (:wat::core::vec :wat::core::f64 100.0) 10)))
    (:wat::test::assert-eq
      (:trading::encoding::compute-tf-ret buf)
      0.0)))

;; Test 2 — known input: oldest=100, newest=110 → +0.10.
(:deftest :trading::test::encoding::indicator-bank::test-tf-ret-rising
  (:wat::core::let*
    (((buf :trading::encoding::RingBuffer)
      (:test::ring-from-vec
        (:wat::core::vec :wat::core::f64 100.0 105.0 110.0)
        10)))
    (:wat::test::assert-eq
      (:trading::encoding::compute-tf-ret buf)
      0.1)))

;; Test 3 — falling: oldest=100, newest=90 → -0.10.
(:deftest :trading::test::encoding::indicator-bank::test-tf-ret-falling
  (:wat::core::let*
    (((buf :trading::encoding::RingBuffer)
      (:test::ring-from-vec
        (:wat::core::vec :wat::core::f64 100.0 95.0 90.0)
        10)))
    (:wat::test::assert-eq
      (:trading::encoding::compute-tf-ret buf)
      -0.1)))


;; ─── tf-body ─────────────────────────────────────────────────────

;; Test 4 — full body: open=100, close=110, high=110, low=100 → 1.0.
(:deftest :trading::test::encoding::indicator-bank::test-tf-body-full
  (:wat::core::let*
    (((buf :trading::encoding::RingBuffer)
      (:test::ring-from-vec
        (:wat::core::vec :wat::core::f64 100.0 110.0)   ;; oldest=100, newest=110
        10)))
    (:wat::test::assert-eq
      (:trading::encoding::compute-tf-body buf)
      1.0)))

;; Test 5 — degenerate (high==low) → 0.
(:deftest :trading::test::encoding::indicator-bank::test-tf-body-degenerate
  (:wat::core::let*
    (((buf :trading::encoding::RingBuffer)
      (:test::ring-from-vec
        (:wat::core::vec :wat::core::f64 100.0 100.0)
        10)))
    (:wat::test::assert-eq
      (:trading::encoding::compute-tf-body buf)
      0.0)))


;; ─── tf-agreement ────────────────────────────────────────────────

;; Test 6 — all three timeframes agree on direction (all rising) → +1.
;; ret-5m positive, ret-1h positive (rising buf), ret-4h positive
;; (rising buf). All s1=s4=s5=+1; sum of products = 3; /3 = 1.
(:deftest :trading::test::encoding::indicator-bank::test-tf-agreement-all-up
  (:wat::core::let*
    (((tf-1h :trading::encoding::RingBuffer)
      (:test::ring-from-vec (:wat::core::vec :wat::core::f64 100.0 105.0) 12))
     ((tf-4h :trading::encoding::RingBuffer)
      (:test::ring-from-vec (:wat::core::vec :wat::core::f64 100.0 105.0) 48))
     ((agg :wat::core::f64)
      (:trading::encoding::compute-tf-agreement 100.0 105.0 tf-1h tf-4h)))
    (:wat::test::assert-eq agg 1.0)))

;; Test 7 — total disagreement: 5m up, 1h+4h down. s5=+1, s1=s4=-1.
;; products: (+1·-1) + (+1·-1) + (-1·-1) = -1 -1 +1 = -1; /3 = -1/3.
(:deftest :trading::test::encoding::indicator-bank::test-tf-agreement-mixed
  (:wat::core::let*
    (((tf-1h :trading::encoding::RingBuffer)
      (:test::ring-from-vec (:wat::core::vec :wat::core::f64 105.0 100.0) 12))
     ((tf-4h :trading::encoding::RingBuffer)
      (:test::ring-from-vec (:wat::core::vec :wat::core::f64 105.0 100.0) 48))
     ((agg :wat::core::f64)
      (:trading::encoding::compute-tf-agreement 100.0 105.0 tf-1h tf-4h)))
    (:wat::test::assert-eq agg (:wat::core::/ -1.0 3.0))))


;; ─── signum ──────────────────────────────────────────────────────

;; Test 8 — signum at the three boundaries.
(:deftest :trading::test::encoding::indicator-bank::test-signum-three-cases
  (:wat::core::let*
    (((u1 :())
      (:wat::test::assert-eq (:trading::encoding::signum 1.5) 1.0))
     ((u2 :())
      (:wat::test::assert-eq (:trading::encoding::signum -2.0) -1.0)))
    (:wat::test::assert-eq (:trading::encoding::signum 0.0) 0.0)))
