;; wat-tests/encoding/indicator-bank/regime.wat — Lab arc 026 slice 10.
;;
;; Eight indicators; tests gate-and-direction for each. Statistical
;; correctness validated by archive-shaped inputs producing expected
;; range/sign behaviors.

(:wat::test::make-deftest :deftest
  ((:wat::load-file! "wat/encoding/indicator-bank/regime.wat")

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


;; ─── KAMA Efficiency Ratio ────────────────────────────────────────

;; Test 1 — pure trend → ER = 1.
(:deftest :trading::test::encoding::indicator-bank::test-kama-er-pure-trend
  (:wat::core::let*
    (((closes :Vec<f64>)
      (:wat::core::vec :f64 100.0 110.0 120.0 130.0 140.0)))
    (:wat::test::assert-eq
      (:trading::encoding::compute-kama-er closes)
      1.0)))

;; Test 2 — chop → ER < 0.5 (oscillation eats efficiency).
(:deftest :trading::test::encoding::indicator-bank::test-kama-er-chop-low
  (:wat::core::let*
    (((closes :Vec<f64>)
      (:wat::core::vec :f64 100.0 110.0 100.0 110.0 100.0 110.0))
     ((er :f64) (:trading::encoding::compute-kama-er closes)))
    (:wat::test::assert-eq (:wat::core::< er 0.5) true)))


;; ─── Choppiness ──────────────────────────────────────────────────

;; Test 3 — degenerate range → 50.
(:deftest :trading::test::encoding::indicator-bank::test-chop-degenerate
  (:wat::core::let*
    (((hi :trading::encoding::RingBuffer)
      (:test::ring-from-vec (:wat::core::vec :f64 100.0 100.0 100.0) 14))
     ((lo :trading::encoding::RingBuffer)
      (:test::ring-from-vec (:wat::core::vec :f64 100.0 100.0 100.0) 14)))
    (:wat::test::assert-eq
      (:trading::encoding::compute-choppiness 0.0 hi lo)
      50.0)))

;; Test 4 — finite atr_sum + range → finite result, well-defined.
(:deftest :trading::test::encoding::indicator-bank::test-chop-finite
  (:wat::core::let*
    (((hi :trading::encoding::RingBuffer)
      (:test::ring-from-vec (:wat::core::vec :f64 110.0 115.0 112.0) 14))
     ((lo :trading::encoding::RingBuffer)
      (:test::ring-from-vec (:wat::core::vec :f64 100.0 105.0 102.0) 14))
     ((c :f64) (:trading::encoding::compute-choppiness 50.0 hi lo)))
    ;; Just confirm it runs and produces a value (not 50.0 fallback).
    (:wat::test::assert-eq (:wat::core::not= c 50.0) true)))


;; ─── DFA Alpha ───────────────────────────────────────────────────

;; Test 5 — short input → 0.5 fallback.
(:deftest :trading::test::encoding::indicator-bank::test-dfa-short-half
  (:wat::core::let*
    (((closes :Vec<f64>) (:wat::core::vec :f64 1.0 2.0 3.0)))
    (:wat::test::assert-eq
      (:trading::encoding::compute-dfa-alpha closes)
      0.5)))

;; Test 6 — flat input → DFA = 0.5 (fluctuations zero → fallback).
(:deftest :trading::test::encoding::indicator-bank::test-dfa-flat-half
  (:wat::core::let*
    (((closes :Vec<f64>)
      (:wat::core::vec :f64 100.0 100.0 100.0 100.0 100.0 100.0 100.0 100.0
                            100.0 100.0 100.0 100.0 100.0 100.0 100.0 100.0
                            100.0 100.0 100.0 100.0)))
    (:wat::test::assert-eq
      (:trading::encoding::compute-dfa-alpha closes)
      0.5)))


;; ─── Variance Ratio ──────────────────────────────────────────────

;; Test 7 — short input → 1.0 fallback.
(:deftest :trading::test::encoding::indicator-bank::test-vr-short-one
  (:wat::core::let*
    (((closes :Vec<f64>) (:wat::core::vec :f64 1.0 2.0 3.0)))
    (:wat::test::assert-eq
      (:trading::encoding::compute-variance-ratio closes)
      1.0)))

;; Test 8 — flat input → 1.0 (var-1=0 → fallback).
(:deftest :trading::test::encoding::indicator-bank::test-vr-flat-one
  (:wat::core::let*
    (((closes :Vec<f64>)
      (:wat::core::vec :f64 100.0 100.0 100.0 100.0 100.0 100.0 100.0 100.0
                            100.0 100.0 100.0 100.0)))
    (:wat::test::assert-eq
      (:trading::encoding::compute-variance-ratio closes)
      1.0)))


;; ─── Entropy Bin + Rate ──────────────────────────────────────────

;; Test 9 — entropy bin: a return below -0.005 → -2.0; above 0.005 → +2.0.
(:deftest :trading::test::encoding::indicator-bank::test-entropy-bin-extremes
  (:wat::core::let*
    (((u1 :())
      (:wat::test::assert-eq
        (:trading::encoding::compute-entropy-bin -0.01) -2.0)))
    (:wat::test::assert-eq
      (:trading::encoding::compute-entropy-bin 0.01) 2.0)))

;; Test 10 — entropy rate: all-zero bin (no movement) → low entropy
;; (single-bucket distribution; all probability on 0). entropy = -1*ln(1) = 0.
(:deftest :trading::test::encoding::indicator-bank::test-entropy-rate-flat-low
  (:wat::core::let*
    (((vals :Vec<f64>) (:wat::core::vec :f64 0.0 0.0 0.0 0.0 0.0 0.0 0.0)))
    (:wat::test::assert-eq
      (:trading::encoding::compute-entropy-rate vals)
      0.0)))

;; Test 11 — entropy rate: all 5 bins evenly populated → max entropy ≈ ln(5).
(:deftest :trading::test::encoding::indicator-bank::test-entropy-rate-uniform-high
  (:wat::core::let*
    (((vals :Vec<f64>)
      (:wat::core::vec :f64 -2.0 -1.0 0.0 1.0 2.0 -2.0 -1.0 0.0 1.0 2.0))
     ((e :f64) (:trading::encoding::compute-entropy-rate vals)))
    ;; ln(5) ≈ 1.609. Very close — within numeric noise.
    (:wat::test::assert-eq (:wat::core::> e 1.5) true)))


;; ─── Aroon ───────────────────────────────────────────────────────

;; Test 12 — aroon-up: max at last index → 100.
(:deftest :trading::test::encoding::indicator-bank::test-aroon-up-recent-high
  (:wat::core::let*
    (((highs :Vec<f64>)
      (:wat::core::vec :f64 100.0 105.0 110.0 115.0 120.0)))
    (:wat::test::assert-eq
      (:trading::encoding::compute-aroon-up highs)
      100.0)))

;; Test 13 — aroon-down: min at first index → 0.
(:deftest :trading::test::encoding::indicator-bank::test-aroon-down-stale-low
  (:wat::core::let*
    (((lows :Vec<f64>)
      (:wat::core::vec :f64 90.0 95.0 100.0 105.0 110.0)))
    (:wat::test::assert-eq
      (:trading::encoding::compute-aroon-down lows)
      0.0)))

;; Test 14 — empty input → 50 fallback.
(:deftest :trading::test::encoding::indicator-bank::test-aroon-empty
  (:wat::core::let*
    (((empty :Vec<f64>) (:wat::core::vec :f64)))
    (:wat::test::assert-eq
      (:trading::encoding::compute-aroon-up empty)
      50.0)))


;; ─── Fractal Dimension ───────────────────────────────────────────

;; Test 15 — short input → 1.5 fallback.
(:deftest :trading::test::encoding::indicator-bank::test-fractal-short-default
  (:wat::core::let*
    (((closes :Vec<f64>) (:wat::core::vec :f64 1.0 2.0 3.0 4.0 5.0)))
    (:wat::test::assert-eq
      (:trading::encoding::compute-fractal-dim closes)
      1.5)))

;; Test 16 — fractal-dim clamped to [1, 2].
(:deftest :trading::test::encoding::indicator-bank::test-fractal-bounded
  (:wat::core::let*
    (;; A noisy series.
     ((closes :Vec<f64>)
      (:wat::core::vec :f64
        100.0 105.0 95.0 110.0 90.0 115.0 85.0 120.0 80.0 125.0
        75.0 130.0 70.0 135.0 65.0 140.0))
     ((d :f64) (:trading::encoding::compute-fractal-dim closes))
     ((bounded? :bool)
      (:wat::core::and
        (:wat::core::>= d 1.0)
        (:wat::core::<= d 2.0))))
    (:wat::test::assert-eq bounded? true)))
