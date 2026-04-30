;; wat-tests/encoding/indicator-bank/ichimoku.wat — Lab arc 026 slice 8.

(:wat::test::make-deftest :deftest
  ((:wat::load-file! "wat/encoding/indicator-bank/ichimoku.wat")

   (:wat::core::define
     (:test::ichi-feed
       (s :trading::encoding::IchimokuState)
       (h :wat::core::f64) (l :wat::core::f64)
       (n :wat::core::i64)
       -> :trading::encoding::IchimokuState)
     (:wat::core::if (:wat::core::<= n 0)
                     -> :trading::encoding::IchimokuState
       s
       (:test::ichi-feed
         (:trading::encoding::IchimokuState::update s h l)
         h l
         (:wat::core::- n 1))))))


;; ─── Construction ────────────────────────────────────────────────

;; Test 1 — fresh: not ready (52-period buffer empty).
(:deftest :trading::test::encoding::indicator-bank::test-ichi-fresh-not-ready
  (:wat::core::let*
    (((s :trading::encoding::IchimokuState)
      (:trading::encoding::IchimokuState::fresh)))
    (:wat::test::assert-eq
      (:trading::encoding::IchimokuState::ready? s)
      false)))


;; ─── Tenkan / Kijun ──────────────────────────────────────────────

;; Test 2 — flat input → tenkan == kijun (both equal close-mid).
(:deftest :trading::test::encoding::indicator-bank::test-ichi-flat-tenkan-equals-kijun
  (:wat::core::let*
    (((s0 :trading::encoding::IchimokuState)
      (:trading::encoding::IchimokuState::fresh))
     ;; 30 candles to fill the 26-period buffer.
     ((s30 :trading::encoding::IchimokuState)
      (:test::ichi-feed s0 110.0 100.0 30))
     ((tenkan :wat::core::f64) (:trading::encoding::IchimokuState::tenkan s30))
     ((kijun :wat::core::f64) (:trading::encoding::IchimokuState::kijun s30)))
    ;; Tenkan = (110+100)/2 = 105; kijun likewise.
    (:wat::core::let*
      (((u1 :()) (:wat::test::assert-eq tenkan 105.0)))
      (:wat::test::assert-eq kijun 105.0))))

;; Test 3 — known input: high=120, low=100. Tenkan = 110.
(:deftest :trading::test::encoding::indicator-bank::test-ichi-tenkan-formula
  (:wat::core::let*
    (((s0 :trading::encoding::IchimokuState)
      (:trading::encoding::IchimokuState::fresh))
     ((s10 :trading::encoding::IchimokuState)
      (:test::ichi-feed s0 120.0 100.0 10)))
    (:wat::test::assert-eq
      (:trading::encoding::IchimokuState::tenkan s10)
      110.0)))


;; ─── Cloud ───────────────────────────────────────────────────────

;; Test 4 — flat input: senkou_a == senkou_b → cloud-top == cloud-bottom.
(:deftest :trading::test::encoding::indicator-bank::test-ichi-flat-cloud-degenerate
  (:wat::core::let*
    (((s0 :trading::encoding::IchimokuState)
      (:trading::encoding::IchimokuState::fresh))
     ((s60 :trading::encoding::IchimokuState)
      (:test::ichi-feed s0 110.0 100.0 60))
     ((top :wat::core::f64) (:trading::encoding::IchimokuState::cloud-top s60))
     ((bot :wat::core::f64) (:trading::encoding::IchimokuState::cloud-bottom s60)))
    (:wat::test::assert-eq top bot)))

;; Test 5 — cloud ordering: cloud-top >= cloud-bottom always.
(:deftest :trading::test::encoding::indicator-bank::test-ichi-cloud-top-not-below-bottom
  (:wat::core::let*
    (((s0 :trading::encoding::IchimokuState)
      (:trading::encoding::IchimokuState::fresh))
     ;; Mixed input — varying highs/lows over 60 candles.
     ((s1 :trading::encoding::IchimokuState) (:trading::encoding::IchimokuState::update s0 120.0 100.0))
     ((s2 :trading::encoding::IchimokuState) (:trading::encoding::IchimokuState::update s1 130.0 110.0))
     ((s3 :trading::encoding::IchimokuState) (:trading::encoding::IchimokuState::update s2 125.0 105.0))
     ((s60 :trading::encoding::IchimokuState)
      (:test::ichi-feed s3 128.0 108.0 57))
     ((top :wat::core::f64) (:trading::encoding::IchimokuState::cloud-top s60))
     ((bot :wat::core::f64) (:trading::encoding::IchimokuState::cloud-bottom s60)))
    (:wat::test::assert-eq (:wat::core::>= top bot) true)))


;; ─── tk-cross-delta ──────────────────────────────────────────────

;; Test 6 — flat input → tk-cross-delta = 0 (tenkan-kijun spread
;; doesn't change tick to tick).
(:deftest :trading::test::encoding::indicator-bank::test-ichi-flat-tk-delta-zero
  (:wat::core::let*
    (((s0 :trading::encoding::IchimokuState)
      (:trading::encoding::IchimokuState::fresh))
     ((s30 :trading::encoding::IchimokuState)
      (:test::ichi-feed s0 110.0 100.0 30))
     ((delta :wat::core::f64) (:trading::encoding::IchimokuState::tk-cross-delta s30)))
    (:wat::test::assert-eq delta 0.0)))


;; ─── Ready gate ──────────────────────────────────────────────────

;; Test 7 — ready? true at exactly 52 candles.
(:deftest :trading::test::encoding::indicator-bank::test-ichi-ready-at-52
  (:wat::core::let*
    (((s0 :trading::encoding::IchimokuState)
      (:trading::encoding::IchimokuState::fresh))
     ((s51 :trading::encoding::IchimokuState)
      (:test::ichi-feed s0 110.0 100.0 51))
     ((not-yet? :wat::core::bool) (:trading::encoding::IchimokuState::ready? s51))
     ((s52 :trading::encoding::IchimokuState)
      (:trading::encoding::IchimokuState::update s51 110.0 100.0))
     ((ready? :wat::core::bool) (:trading::encoding::IchimokuState::ready? s52)))
    (:wat::core::let*
      (((u1 :()) (:wat::test::assert-eq not-yet? false)))
      (:wat::test::assert-eq ready? true))))


;; ─── senkou-a / senkou-b ─────────────────────────────────────────

;; Test 8 — senkou-a = (tenkan + kijun) / 2; flat → equal to tenkan/kijun.
(:deftest :trading::test::encoding::indicator-bank::test-ichi-senkou-a-formula
  (:wat::core::let*
    (((s0 :trading::encoding::IchimokuState)
      (:trading::encoding::IchimokuState::fresh))
     ((s30 :trading::encoding::IchimokuState)
      (:test::ichi-feed s0 110.0 100.0 30))
     ((sa :wat::core::f64) (:trading::encoding::IchimokuState::senkou-a s30)))
    (:wat::test::assert-eq sa 105.0)))
