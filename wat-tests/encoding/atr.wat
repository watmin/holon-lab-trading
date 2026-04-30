;; wat-tests/encoding/atr.wat — Lab arc 025 slice 1 tests.
;;
;; Tests :trading::encoding::AtrState (::fresh, ::update, ::ready?,
;; value accessor) against its source at wat/encoding/atr.wat.

(:wat::test::make-deftest :deftest
  ((:wat::load-file! "wat/encoding/atr.wat")
   (:wat::core::define
     (:test::repeat-update
       (s :trading::encoding::AtrState)
       (h :wat::core::f64) (l :wat::core::f64) (c :wat::core::f64)
       (n :wat::core::i64)
       -> :trading::encoding::AtrState)
     (:wat::core::if (:wat::core::<= n 0)
                     -> :trading::encoding::AtrState
       s
       (:test::repeat-update
         (:trading::encoding::AtrState::update s h l c)
         h l c
         (:wat::core::- n 1))))))

;; ─── ::fresh ───────────────────────────────────────────────────────

(:deftest :trading::test::encoding::atr::test-fresh-has-zero-count
  (:wat::core::let*
    (((s :trading::encoding::AtrState)
      (:trading::encoding::AtrState::fresh 14)))
    ;; Post-arc-026 refactor: count moved to inner WilderState.
    (:wat::test::assert-eq
      (:trading::encoding::WilderState/count
        (:trading::encoding::AtrState/wilder s))
      0)))

(:deftest :trading::test::encoding::atr::test-fresh-not-ready
  (:wat::core::let*
    (((s :trading::encoding::AtrState)
      (:trading::encoding::AtrState::fresh 14)))
    (:wat::test::assert-eq
      (:trading::encoding::AtrState::ready? s)
      false)))

;; ─── True-range formula ───────────────────────────────────────────

;; First update has started=false → TR = high - low (no prev-close).
(:deftest :trading::test::encoding::atr::test-first-update-tr-is-range
  (:wat::core::let*
    (((s0 :trading::encoding::AtrState)
      (:trading::encoding::AtrState::fresh 1))
     ;; period=1 means one update completes warmup; value = TR.
     ((s1 :trading::encoding::AtrState)
      (:trading::encoding::AtrState::update s0 110.0 100.0 105.0)))
    (:wat::test::assert-eq
      (:trading::encoding::AtrState::value s1)
      10.0)))

;; Subsequent update with high-prev_close > range → TR = |high-prev_close|.
(:deftest :trading::test::encoding::atr::test-tr-uses-prev-close-on-gap-up
  (:wat::core::let*
    (((s0 :trading::encoding::AtrState)
      (:trading::encoding::AtrState::fresh 1))
     ;; First candle: TR = 10, prev_close set to 105.
     ((s1 :trading::encoding::AtrState)
      (:trading::encoding::AtrState::update s0 110.0 100.0 105.0))
     ;; Second candle gaps up: high=120, low=115, prev_close=105.
     ;; TR = max(5, |120-105|, |115-105|) = 15. Wilder EMA at p=1:
     ;; new_value = 15/1 + 10*(1-1)/1 = 15.
     ((s2 :trading::encoding::AtrState)
      (:trading::encoding::AtrState::update s1 120.0 115.0 118.0)))
    (:wat::test::assert-eq
      (:trading::encoding::AtrState::value s2)
      15.0)))

;; ─── Ready gate ────────────────────────────────────────────────────

(:deftest :trading::test::encoding::atr::test-ready-after-period-updates
  (:wat::core::let*
    (((s0 :trading::encoding::AtrState)
      (:trading::encoding::AtrState::fresh 14))
     ;; Push 13 updates → not ready. Push 14th → ready.
     ((s13 :trading::encoding::AtrState)
      (:test::repeat-update s0 110.0 100.0 105.0 13))
     ((not-ready :wat::core::bool)
      (:trading::encoding::AtrState::ready? s13))
     ((s14 :trading::encoding::AtrState)
      (:trading::encoding::AtrState::update s13 110.0 100.0 105.0))
     ((ready :wat::core::bool)
      (:trading::encoding::AtrState::ready? s14)))
    (:wat::core::let*
      (((u1 :())
        (:wat::test::assert-eq not-ready false)))
      (:wat::test::assert-eq ready true))))

;; ─── Wilder convergence ────────────────────────────────────────────

;; Constant TR for 50 candles → ATR converges to that TR value. With
;; high-low = 10 every candle and started=true after first, TR is 10
;; throughout. Wilder warmup averages first 14 → 10. Subsequent EMA:
;; value = 10/14 + 10·13/14 = 10. Stays at 10.
(:deftest :trading::test::encoding::atr::test-converges-to-constant-tr
  (:wat::core::let*
    (((s0 :trading::encoding::AtrState)
      (:trading::encoding::AtrState::fresh 14))
     ;; Same close each candle → TR = high-low for the first, then
     ;; max(10, 0, 0) = 10 for subsequent (close == prev_close).
     ((s50 :trading::encoding::AtrState)
      (:test::repeat-update s0 110.0 100.0 105.0 50)))
    (:wat::test::assert-eq
      (:trading::encoding::AtrState::value s50)
      10.0)))
