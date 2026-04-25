;; wat-tests/encoding/indicator-bank/volatility.wat — Lab arc 026 slice 4.
;;
;; Tests Bollinger + Keltner + squeeze + atr-ratio. RollingStddev's
;; mechanics are exercised through Bollinger (since it's the load-
;; bearing consumer); a couple of standalone stddev tests verify the
;; carry-along.

(:wat::test::make-deftest :deftest
  ((:wat::load-file! "wat/encoding/indicator-bank/volatility.wat")

   (:wat::core::define
     (:test::stddev-feed
       (s :trading::encoding::RollingStddev)
       (x :f64)
       (n :i64)
       -> :trading::encoding::RollingStddev)
     (:wat::core::if (:wat::core::<= n 0)
                     -> :trading::encoding::RollingStddev
       s
       (:test::stddev-feed
         (:trading::encoding::RollingStddev::update s x)
         x
         (:wat::core::- n 1))))

   (:wat::core::define
     (:test::bb-feed
       (s :trading::encoding::BollingerState)
       (x :f64)
       (n :i64)
       -> :trading::encoding::BollingerState)
     (:wat::core::if (:wat::core::<= n 0)
                     -> :trading::encoding::BollingerState
       s
       (:test::bb-feed
         (:trading::encoding::BollingerState::update s x)
         x
         (:wat::core::- n 1))))

   (:wat::core::define
     (:test::kelt-feed
       (s :trading::encoding::KeltnerState)
       (x :f64)
       (n :i64)
       -> :trading::encoding::KeltnerState)
     (:wat::core::if (:wat::core::<= n 0)
                     -> :trading::encoding::KeltnerState
       s
       (:test::kelt-feed
         (:trading::encoding::KeltnerState::update s x)
         x
         (:wat::core::- n 1))))))


;; ─── RollingStddev ─────────────────────────────────────────────────

;; Test 1 — flat input → stddev 0.
(:deftest :trading::test::encoding::indicator-bank::test-stddev-flat-zero
  (:wat::core::let*
    (((s0 :trading::encoding::RollingStddev)
      (:trading::encoding::RollingStddev::fresh 5))
     ((s5 :trading::encoding::RollingStddev)
      (:test::stddev-feed s0 100.0 5)))
    (:wat::test::assert-eq
      (:trading::encoding::RollingStddev::value s5)
      0.0)))

;; Test 2 — known input. {1, 2, 3, 4, 5}: mean=3, var=2, stddev=sqrt(2).
(:deftest :trading::test::encoding::indicator-bank::test-stddev-known-input
  (:wat::core::let*
    (((s0 :trading::encoding::RollingStddev)
      (:trading::encoding::RollingStddev::fresh 5))
     ((s1 :trading::encoding::RollingStddev) (:trading::encoding::RollingStddev::update s0 1.0))
     ((s2 :trading::encoding::RollingStddev) (:trading::encoding::RollingStddev::update s1 2.0))
     ((s3 :trading::encoding::RollingStddev) (:trading::encoding::RollingStddev::update s2 3.0))
     ((s4 :trading::encoding::RollingStddev) (:trading::encoding::RollingStddev::update s3 4.0))
     ((s5 :trading::encoding::RollingStddev) (:trading::encoding::RollingStddev::update s4 5.0))
     ((sd :f64) (:trading::encoding::RollingStddev::value s5)))
    (:wat::test::assert-eq sd (:wat::std::math::sqrt 2.0))))


;; ─── Bollinger Bands ──────────────────────────────────────────────

;; Test 3 — fresh: not ready.
(:deftest :trading::test::encoding::indicator-bank::test-bollinger-fresh-not-ready
  (:wat::core::let*
    (((s :trading::encoding::BollingerState)
      (:trading::encoding::BollingerState::fresh 20)))
    (:wat::test::assert-eq
      (:trading::encoding::BollingerState::ready? s)
      false)))

;; Test 4 — flat input → width 0 (stddev=0 → bands collapse to SMA).
(:deftest :trading::test::encoding::indicator-bank::test-bollinger-flat-width-zero
  (:wat::core::let*
    (((s0 :trading::encoding::BollingerState)
      (:trading::encoding::BollingerState::fresh 5))
     ((s5 :trading::encoding::BollingerState)
      (:test::bb-feed s0 100.0 5)))
    (:wat::test::assert-eq
      (:trading::encoding::BollingerState::width s5)
      0.0)))

;; Test 5 — pos at center on flat input → 0.5 (degenerate band fallback).
(:deftest :trading::test::encoding::indicator-bank::test-bollinger-flat-pos-is-half
  (:wat::core::let*
    (((s0 :trading::encoding::BollingerState)
      (:trading::encoding::BollingerState::fresh 5))
     ((s5 :trading::encoding::BollingerState)
      (:test::bb-feed s0 100.0 5)))
    (:wat::test::assert-eq
      (:trading::encoding::BollingerState::pos s5 100.0)
      0.5)))

;; Test 6 — upper > lower under varying input.
(:deftest :trading::test::encoding::indicator-bank::test-bollinger-upper-above-lower
  (:wat::core::let*
    (((s0 :trading::encoding::BollingerState)
      (:trading::encoding::BollingerState::fresh 5))
     ((s1 :trading::encoding::BollingerState) (:trading::encoding::BollingerState::update s0 100.0))
     ((s2 :trading::encoding::BollingerState) (:trading::encoding::BollingerState::update s1 105.0))
     ((s3 :trading::encoding::BollingerState) (:trading::encoding::BollingerState::update s2 95.0))
     ((s4 :trading::encoding::BollingerState) (:trading::encoding::BollingerState::update s3 110.0))
     ((s5 :trading::encoding::BollingerState) (:trading::encoding::BollingerState::update s4 90.0))
     ((upper :f64) (:trading::encoding::BollingerState::upper s5))
     ((lower :f64) (:trading::encoding::BollingerState::lower s5)))
    (:wat::test::assert-eq (:wat::core::> upper lower) true)))


;; ─── Keltner Channels ──────────────────────────────────────────────

;; Test 7 — fresh: not ready.
(:deftest :trading::test::encoding::indicator-bank::test-keltner-fresh-not-ready
  (:wat::core::let*
    (((s :trading::encoding::KeltnerState)
      (:trading::encoding::KeltnerState::fresh 20)))
    (:wat::test::assert-eq
      (:trading::encoding::KeltnerState::ready? s)
      false)))

;; Test 8 — bands centered at EMA ± 2·ATR. With known close=100, atr=5:
;;   upper = 100 + 10 = 110
;;   lower = 100 - 10 = 90
(:deftest :trading::test::encoding::indicator-bank::test-keltner-band-formula
  (:wat::core::let*
    (((s0 :trading::encoding::KeltnerState)
      (:trading::encoding::KeltnerState::fresh 5))
     ((s5 :trading::encoding::KeltnerState)
      (:test::kelt-feed s0 100.0 5))
     ((upper :f64) (:trading::encoding::KeltnerState::upper s5 5.0))
     ((lower :f64) (:trading::encoding::KeltnerState::lower s5 5.0)))
    (:wat::core::let*
      (((u1 :()) (:wat::test::assert-eq upper 110.0)))
      (:wat::test::assert-eq lower 90.0))))

;; Test 9 — pos at midpoint of band → 0.5.
(:deftest :trading::test::encoding::indicator-bank::test-keltner-pos-at-midpoint
  (:wat::core::let*
    (((s0 :trading::encoding::KeltnerState)
      (:trading::encoding::KeltnerState::fresh 5))
     ((s5 :trading::encoding::KeltnerState)
      (:test::kelt-feed s0 100.0 5))
     ((pos :f64) (:trading::encoding::KeltnerState::pos s5 5.0 100.0)))
    (:wat::test::assert-eq pos 0.5)))


;; ─── Squeeze + ATR-ratio ──────────────────────────────────────────

;; Test 10 — squeeze ratio direct.
(:deftest :trading::test::encoding::indicator-bank::test-squeeze-bb-half-of-keltner
  (:wat::test::assert-eq
    (:trading::encoding::compute-squeeze 0.04 0.08)
    0.5))

;; Test 11 — squeeze with zero kelt-width → 0 (defensive).
(:deftest :trading::test::encoding::indicator-bank::test-squeeze-degenerate
  (:wat::test::assert-eq
    (:trading::encoding::compute-squeeze 0.04 0.0)
    0.0))

;; Test 12 — atr-ratio.
(:deftest :trading::test::encoding::indicator-bank::test-atr-ratio
  (:wat::test::assert-eq
    (:trading::encoding::compute-atr-ratio 5.0 100.0)
    0.05))
