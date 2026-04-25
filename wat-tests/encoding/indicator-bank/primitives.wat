;; wat-tests/encoding/indicator-bank/primitives.wat — Lab arc 026 slice 1.
;;
;; Tests RingBuffer + EmaState + SmaState against
;; wat/encoding/indicator-bank/primitives.wat.

(:wat::test::make-deftest :deftest
  ((:wat::load-file! "wat/encoding/indicator-bank/primitives.wat")
   ;; Tail-recursive feeder for convergence tests.
   (:wat::core::define
     (:test::ema-feed
       (s :trading::encoding::EmaState)
       (x :f64)
       (n :i64)
       -> :trading::encoding::EmaState)
     (:wat::core::if (:wat::core::<= n 0)
                     -> :trading::encoding::EmaState
       s
       (:test::ema-feed
         (:trading::encoding::EmaState::update s x)
         x
         (:wat::core::- n 1))))
   (:wat::core::define
     (:test::sma-feed
       (s :trading::encoding::SmaState)
       (x :f64)
       (n :i64)
       -> :trading::encoding::SmaState)
     (:wat::core::if (:wat::core::<= n 0)
                     -> :trading::encoding::SmaState
       s
       (:test::sma-feed
         (:trading::encoding::SmaState::update s x)
         x
         (:wat::core::- n 1))))))


;; ─── RingBuffer ───────────────────────────────────────────────────

;; Test 1 — push under capacity.
(:deftest :trading::test::encoding::indicator-bank::test-ring-push-under-capacity
  (:wat::core::let*
    (((b0 :trading::encoding::RingBuffer)
      (:trading::encoding::RingBuffer::fresh 5))
     ((b1 :trading::encoding::RingBuffer)
      (:trading::encoding::RingBuffer::push b0 1.0))
     ((b2 :trading::encoding::RingBuffer)
      (:trading::encoding::RingBuffer::push b1 2.0))
     ((b3 :trading::encoding::RingBuffer)
      (:trading::encoding::RingBuffer::push b2 3.0)))
    (:wat::test::assert-eq
      (:trading::encoding::RingBuffer::len b3)
      3)))

;; Test 2 — push past capacity evicts oldest.
(:deftest :trading::test::encoding::indicator-bank::test-ring-push-past-capacity
  (:wat::core::let*
    (((b0 :trading::encoding::RingBuffer)
      (:trading::encoding::RingBuffer::fresh 2))
     ((b1 :trading::encoding::RingBuffer) (:trading::encoding::RingBuffer::push b0 1.0))
     ((b2 :trading::encoding::RingBuffer) (:trading::encoding::RingBuffer::push b1 2.0))
     ((b3 :trading::encoding::RingBuffer) (:trading::encoding::RingBuffer::push b2 3.0))
     ;; After: values should be [2.0, 3.0]; len 2.
     ((len :i64) (:trading::encoding::RingBuffer::len b3))
     ;; Most recent (i=0) is 3.0; one prior (i=1) is 2.0.
     ((most :f64)
      (:wat::core::match (:trading::encoding::RingBuffer::get b3 0) -> :f64
        ((Some v) v) (:None -1.0)))
     ((prior :f64)
      (:wat::core::match (:trading::encoding::RingBuffer::get b3 1) -> :f64
        ((Some v) v) (:None -1.0))))
    (:wat::core::let*
      (((u1 :()) (:wat::test::assert-eq len 2))
       ((u2 :()) (:wat::test::assert-eq most 3.0)))
      (:wat::test::assert-eq prior 2.0))))

;; Test 3 — get-at-offset out-of-range returns :None.
(:deftest :trading::test::encoding::indicator-bank::test-ring-get-out-of-range
  (:wat::core::let*
    (((b0 :trading::encoding::RingBuffer)
      (:trading::encoding::RingBuffer::fresh 5))
     ((b1 :trading::encoding::RingBuffer)
      (:trading::encoding::RingBuffer::push b0 7.0))
     ((g :Option<f64>)
      (:trading::encoding::RingBuffer::get b1 5))
     ((is-none? :bool)
      (:wat::core::match g -> :bool
        ((Some _) false)
        (:None true))))
    (:wat::test::assert-eq is-none? true)))

;; Test 4 — mean over a known input.
(:deftest :trading::test::encoding::indicator-bank::test-ring-mean
  (:wat::core::let*
    (((b0 :trading::encoding::RingBuffer)
      (:trading::encoding::RingBuffer::fresh 4))
     ((b4 :trading::encoding::RingBuffer)
      (:trading::encoding::RingBuffer::push
        (:trading::encoding::RingBuffer::push
          (:trading::encoding::RingBuffer::push
            (:trading::encoding::RingBuffer::push b0 1.0)
            2.0)
          3.0)
        4.0)))
    ;; (1+2+3+4)/4 = 2.5.
    (:wat::test::assert-eq
      (:trading::encoding::RingBuffer::mean b4)
      2.5)))


;; ─── EmaState ─────────────────────────────────────────────────────

;; Test 5 — convergence on constant input.
;; Feed 100.0 for 50 candles at period=10 → EMA value → 100.0.
(:deftest :trading::test::encoding::indicator-bank::test-ema-convergence
  (:wat::core::let*
    (((s0 :trading::encoding::EmaState)
      (:trading::encoding::EmaState::fresh 10))
     ((s50 :trading::encoding::EmaState)
      (:test::ema-feed s0 100.0 50)))
    (:wat::test::assert-eq
      (:trading::encoding::EmaState/value s50)
      100.0)))

;; Test 6 — alpha = 2/(period+1).
(:deftest :trading::test::encoding::indicator-bank::test-ema-alpha
  (:wat::core::let*
    (((s :trading::encoding::EmaState)
      (:trading::encoding::EmaState::fresh 10)))
    ;; 2 / 11 ≈ 0.18181818181818182
    (:wat::test::assert-eq
      (:trading::encoding::EmaState/alpha s)
      (:wat::core::/ 2.0 11.0))))

;; Test 7 — ready? gate.
(:deftest :trading::test::encoding::indicator-bank::test-ema-ready-gate
  (:wat::core::let*
    (((s0 :trading::encoding::EmaState)
      (:trading::encoding::EmaState::fresh 5))
     ((s4 :trading::encoding::EmaState) (:test::ema-feed s0 50.0 4))
     ((not-yet? :bool) (:trading::encoding::EmaState::ready? s4))
     ((s5 :trading::encoding::EmaState)
      (:trading::encoding::EmaState::update s4 50.0))
     ((ready? :bool) (:trading::encoding::EmaState::ready? s5)))
    (:wat::core::let*
      (((u1 :()) (:wat::test::assert-eq not-yet? false)))
      (:wat::test::assert-eq ready? true))))


;; ─── SmaState ─────────────────────────────────────────────────────

;; Test 8 — value matches RingBuffer mean over a full window.
;; Feed 1, 2, 3, 4, 5 at period=5 → SMA = 3.0.
(:deftest :trading::test::encoding::indicator-bank::test-sma-equals-mean
  (:wat::core::let*
    (((s0 :trading::encoding::SmaState)
      (:trading::encoding::SmaState::fresh 5))
     ((s1 :trading::encoding::SmaState) (:trading::encoding::SmaState::update s0 1.0))
     ((s2 :trading::encoding::SmaState) (:trading::encoding::SmaState::update s1 2.0))
     ((s3 :trading::encoding::SmaState) (:trading::encoding::SmaState::update s2 3.0))
     ((s4 :trading::encoding::SmaState) (:trading::encoding::SmaState::update s3 4.0))
     ((s5 :trading::encoding::SmaState) (:trading::encoding::SmaState::update s4 5.0)))
    (:wat::test::assert-eq
      (:trading::encoding::SmaState::value s5)
      3.0)))

;; Test 9 — ready? gate.
(:deftest :trading::test::encoding::indicator-bank::test-sma-ready-gate
  (:wat::core::let*
    (((s0 :trading::encoding::SmaState)
      (:trading::encoding::SmaState::fresh 4))
     ((s3 :trading::encoding::SmaState) (:test::sma-feed s0 7.0 3))
     ((not-yet? :bool) (:trading::encoding::SmaState::ready? s3))
     ((s4 :trading::encoding::SmaState)
      (:trading::encoding::SmaState::update s3 7.0))
     ((ready? :bool) (:trading::encoding::SmaState::ready? s4)))
    (:wat::core::let*
      (((u1 :()) (:wat::test::assert-eq not-yet? false)))
      (:wat::test::assert-eq ready? true))))

;; Test 10 — rolling sum stays correct after eviction.
;; Period 3. Feed 1, 2, 3, 4, 5. After 5 pushes: window is [3,4,5];
;; SMA = 4.0.
(:deftest :trading::test::encoding::indicator-bank::test-sma-rolling-sum-after-eviction
  (:wat::core::let*
    (((s0 :trading::encoding::SmaState)
      (:trading::encoding::SmaState::fresh 3))
     ((s1 :trading::encoding::SmaState) (:trading::encoding::SmaState::update s0 1.0))
     ((s2 :trading::encoding::SmaState) (:trading::encoding::SmaState::update s1 2.0))
     ((s3 :trading::encoding::SmaState) (:trading::encoding::SmaState::update s2 3.0))
     ((s4 :trading::encoding::SmaState) (:trading::encoding::SmaState::update s3 4.0))
     ((s5 :trading::encoding::SmaState) (:trading::encoding::SmaState::update s4 5.0)))
    (:wat::test::assert-eq
      (:trading::encoding::SmaState::value s5)
      4.0)))
