;; wat-tests/encoding/indicator-bank/oscillators.wat — Lab arc 026 slice 2.
;;
;; Tests the five oscillators: RSI, Stochastic, CCI, MFI, Williams %R.
;; Each gets construction / update / convergence / ready-gate / range
;; tests; budget per BACKLOG was 18 tests.

(:wat::test::make-deftest :deftest
  ((:wat::load-file! "wat/encoding/indicator-bank/oscillators.wat")

   (:wat::core::define
     (:test::rsi-feed
       (s :trading::encoding::RsiState)
       (x :f64)
       (n :i64)
       -> :trading::encoding::RsiState)
     (:wat::core::if (:wat::core::<= n 0)
                     -> :trading::encoding::RsiState
       s
       (:test::rsi-feed
         (:trading::encoding::RsiState::update s x)
         x
         (:wat::core::- n 1))))

   (:wat::core::define
     (:test::stoch-feed
       (s :trading::encoding::StochState)
       (h :f64) (l :f64) (c :f64)
       (n :i64)
       -> :trading::encoding::StochState)
     (:wat::core::if (:wat::core::<= n 0)
                     -> :trading::encoding::StochState
       s
       (:test::stoch-feed
         (:trading::encoding::StochState::update s h l c)
         h l c
         (:wat::core::- n 1))))

   (:wat::core::define
     (:test::cci-feed
       (s :trading::encoding::CciState)
       (h :f64) (l :f64) (c :f64)
       (n :i64)
       -> :trading::encoding::CciState)
     (:wat::core::if (:wat::core::<= n 0)
                     -> :trading::encoding::CciState
       s
       (:test::cci-feed
         (:trading::encoding::CciState::update s h l c)
         h l c
         (:wat::core::- n 1))))))


;; ─── RSI ─────────────────────────────────────────────────────────

;; Test 1 — fresh: not ready, gain/loss smoothers empty.
(:deftest :trading::test::encoding::indicator-bank::test-rsi-fresh-not-ready
  (:wat::core::let*
    (((s :trading::encoding::RsiState)
      (:trading::encoding::RsiState::fresh 14)))
    (:wat::test::assert-eq
      (:trading::encoding::RsiState::ready? s)
      false)))

;; Test 2 — flat input → RSI is 100 (no losses; archive's avg_loss=0 → 100.0).
(:deftest :trading::test::encoding::indicator-bank::test-rsi-flat-is-100
  (:wat::core::let*
    (((s0 :trading::encoding::RsiState)
      (:trading::encoding::RsiState::fresh 14))
     ((s50 :trading::encoding::RsiState)
      (:test::rsi-feed s0 100.0 50)))
    (:wat::test::assert-eq
      (:trading::encoding::RsiState::value s50)
      100.0)))

;; Test 3 — RSI in valid range [0, 100] on alternating up/down.
(:deftest :trading::test::encoding::indicator-bank::test-rsi-range-bounded
  (:wat::core::let*
    (((s0 :trading::encoding::RsiState)
      (:trading::encoding::RsiState::fresh 14))
     ;; Inject 30 alternating moves.
     ((s1 :trading::encoding::RsiState) (:trading::encoding::RsiState::update s0 100.0))
     ((s2 :trading::encoding::RsiState) (:trading::encoding::RsiState::update s1 110.0))
     ((s3 :trading::encoding::RsiState) (:trading::encoding::RsiState::update s2 100.0))
     ((s4 :trading::encoding::RsiState) (:trading::encoding::RsiState::update s3 110.0))
     ((s5 :trading::encoding::RsiState) (:trading::encoding::RsiState::update s4 100.0))
     ((s6 :trading::encoding::RsiState) (:trading::encoding::RsiState::update s5 110.0))
     ((s7 :trading::encoding::RsiState) (:trading::encoding::RsiState::update s6 100.0))
     ((s8 :trading::encoding::RsiState) (:trading::encoding::RsiState::update s7 110.0))
     ((s9 :trading::encoding::RsiState) (:trading::encoding::RsiState::update s8 100.0))
     ((s10 :trading::encoding::RsiState) (:trading::encoding::RsiState::update s9 110.0))
     ((s11 :trading::encoding::RsiState) (:trading::encoding::RsiState::update s10 100.0))
     ((s12 :trading::encoding::RsiState) (:trading::encoding::RsiState::update s11 110.0))
     ((s13 :trading::encoding::RsiState) (:trading::encoding::RsiState::update s12 100.0))
     ((s14 :trading::encoding::RsiState) (:trading::encoding::RsiState::update s13 110.0))
     ((s15 :trading::encoding::RsiState) (:trading::encoding::RsiState::update s14 100.0))
     ((v :f64) (:trading::encoding::RsiState::value s15))
     ((in-range? :bool)
      (:wat::core::and (:wat::core::>= v 0.0) (:wat::core::<= v 100.0))))
    (:wat::test::assert-eq in-range? true)))

;; Test 4 — RSI ready? after enough updates.
(:deftest :trading::test::encoding::indicator-bank::test-rsi-ready-after-warmup
  (:wat::core::let*
    (((s0 :trading::encoding::RsiState)
      (:trading::encoding::RsiState::fresh 14))
     ;; First update has started=false, no smoother increment.
     ;; So we need 14 increments AFTER the first → 15 updates total.
     ((s14 :trading::encoding::RsiState)
      (:test::rsi-feed s0 100.0 14))
     ((not-yet? :bool) (:trading::encoding::RsiState::ready? s14))
     ((s15 :trading::encoding::RsiState)
      (:trading::encoding::RsiState::update s14 100.0))
     ((ready? :bool) (:trading::encoding::RsiState::ready? s15)))
    (:wat::core::let*
      (((u1 :()) (:wat::test::assert-eq not-yet? false)))
      (:wat::test::assert-eq ready? true))))


;; ─── Stochastic ──────────────────────────────────────────────────

;; Test 5 — fresh: k = 50.0 (no observations).
(:deftest :trading::test::encoding::indicator-bank::test-stoch-fresh-k-is-50
  (:wat::core::let*
    (((s :trading::encoding::StochState)
      (:trading::encoding::StochState::fresh 14 3)))
    (:wat::test::assert-eq
      (:trading::encoding::StochState::k s)
      50.0)))

;; Test 6 — close at high → %K → 100.
(:deftest :trading::test::encoding::indicator-bank::test-stoch-close-at-high
  (:wat::core::let*
    (((s0 :trading::encoding::StochState)
      (:trading::encoding::StochState::fresh 5 3))
     ;; 5 candles with close at high in the last candle.
     ((s1 :trading::encoding::StochState) (:trading::encoding::StochState::update s0 110.0 100.0 105.0))
     ((s2 :trading::encoding::StochState) (:trading::encoding::StochState::update s1 110.0 100.0 105.0))
     ((s3 :trading::encoding::StochState) (:trading::encoding::StochState::update s2 110.0 100.0 105.0))
     ((s4 :trading::encoding::StochState) (:trading::encoding::StochState::update s3 110.0 100.0 105.0))
     ((s5 :trading::encoding::StochState) (:trading::encoding::StochState::update s4 110.0 100.0 110.0))
     ((k :f64) (:trading::encoding::StochState::k s5)))
    ;; close=110, lowest=100, range=10 → k=100·(10/10)=100.0
    (:wat::test::assert-eq k 100.0)))

;; Test 7 — close at low → %K → 0.
(:deftest :trading::test::encoding::indicator-bank::test-stoch-close-at-low
  (:wat::core::let*
    (((s0 :trading::encoding::StochState)
      (:trading::encoding::StochState::fresh 5 3))
     ((s5 :trading::encoding::StochState)
      (:test::stoch-feed s0 110.0 100.0 100.0 5))
     ((k :f64) (:trading::encoding::StochState::k s5)))
    ;; close=100, lowest=100, range=10 → k=0.0
    (:wat::test::assert-eq k 0.0)))

;; Test 8 — ready? after k-buf fills.
;; k-period=5: high/low full at 5. From candle 5 onward, each candle
;; pushes one %K into k-buf. d-period=3: k-buf full at candle 7.
(:deftest :trading::test::encoding::indicator-bank::test-stoch-ready-gate
  (:wat::core::let*
    (((s0 :trading::encoding::StochState)
      (:trading::encoding::StochState::fresh 5 3))
     ((s6 :trading::encoding::StochState)
      (:test::stoch-feed s0 110.0 100.0 105.0 6))
     ((not-yet? :bool) (:trading::encoding::StochState::ready? s6))
     ((s7 :trading::encoding::StochState)
      (:trading::encoding::StochState::update s6 110.0 100.0 105.0))
     ((ready? :bool) (:trading::encoding::StochState::ready? s7)))
    (:wat::core::let*
      (((u1 :()) (:wat::test::assert-eq not-yet? false)))
      (:wat::test::assert-eq ready? true))))


;; ─── Williams %R ─────────────────────────────────────────────────

;; Test 9 — fresh stoch (not full) → -50.
(:deftest :trading::test::encoding::indicator-bank::test-williams-r-fresh-is-neg-50
  (:wat::core::let*
    (((s :trading::encoding::StochState)
      (:trading::encoding::StochState::fresh 5 3)))
    (:wat::test::assert-eq
      (:trading::encoding::compute-williams-r s 105.0)
      -50.0)))

;; Test 10 — close at high → 0; close at low → -100.
(:deftest :trading::test::encoding::indicator-bank::test-williams-r-bounds
  (:wat::core::let*
    (((s0 :trading::encoding::StochState)
      (:trading::encoding::StochState::fresh 5 3))
     ((s5 :trading::encoding::StochState)
      (:test::stoch-feed s0 110.0 100.0 105.0 5))
     ;; close=110 (=highest) → -100·(110-110)/10 = 0
     ((wr-high :f64)
      (:trading::encoding::compute-williams-r s5 110.0))
     ;; close=100 (=lowest) → -100·(110-100)/10 = -100
     ((wr-low :f64)
      (:trading::encoding::compute-williams-r s5 100.0)))
    (:wat::core::let*
      (((u1 :()) (:wat::test::assert-eq wr-high 0.0)))
      (:wat::test::assert-eq wr-low -100.0))))


;; ─── CCI ─────────────────────────────────────────────────────────

;; Test 11 — fresh: not ready, value 0.
(:deftest :trading::test::encoding::indicator-bank::test-cci-fresh-not-ready
  (:wat::core::let*
    (((s :trading::encoding::CciState)
      (:trading::encoding::CciState::fresh 20)))
    (:wat::core::let*
      (((u1 :())
        (:wat::test::assert-eq (:trading::encoding::CciState::ready? s) false)))
      (:wat::test::assert-eq (:trading::encoding::CciState::value s) 0.0))))

;; Test 12 — flat input → CCI is 0 (mean dev = 0).
(:deftest :trading::test::encoding::indicator-bank::test-cci-flat-is-zero
  (:wat::core::let*
    (((s0 :trading::encoding::CciState)
      (:trading::encoding::CciState::fresh 5))
     ((s5 :trading::encoding::CciState)
      (:test::cci-feed s0 110.0 100.0 105.0 5)))
    (:wat::test::assert-eq
      (:trading::encoding::CciState::value s5)
      0.0)))

;; Test 13 — CCI ready? at period.
(:deftest :trading::test::encoding::indicator-bank::test-cci-ready-at-period
  (:wat::core::let*
    (((s0 :trading::encoding::CciState)
      (:trading::encoding::CciState::fresh 5))
     ((s4 :trading::encoding::CciState)
      (:test::cci-feed s0 110.0 100.0 105.0 4))
     ((not-yet? :bool) (:trading::encoding::CciState::ready? s4))
     ((s5 :trading::encoding::CciState)
      (:trading::encoding::CciState::update s4 110.0 100.0 105.0))
     ((ready? :bool) (:trading::encoding::CciState::ready? s5)))
    (:wat::core::let*
      (((u1 :()) (:wat::test::assert-eq not-yet? false)))
      (:wat::test::assert-eq ready? true))))


;; ─── MFI ─────────────────────────────────────────────────────────

;; Test 14 — fresh: not ready.
(:deftest :trading::test::encoding::indicator-bank::test-mfi-fresh-not-ready
  (:wat::core::let*
    (((s :trading::encoding::MfiState)
      (:trading::encoding::MfiState::fresh 14)))
    (:wat::test::assert-eq
      (:trading::encoding::MfiState::ready? s)
      false)))

;; Test 15 — all-rising prices → MFI → 100 (no negative flow).
(:deftest :trading::test::encoding::indicator-bank::test-mfi-all-rising-is-100
  (:wat::core::let*
    (((s0 :trading::encoding::MfiState)
      (:trading::encoding::MfiState::fresh 5))
     ;; Each tp = (h+l+c)/3 increases monotonically.
     ((s1 :trading::encoding::MfiState) (:trading::encoding::MfiState::update s0 10.0 8.0 9.0 100.0))
     ((s2 :trading::encoding::MfiState) (:trading::encoding::MfiState::update s1 11.0 9.0 10.0 100.0))
     ((s3 :trading::encoding::MfiState) (:trading::encoding::MfiState::update s2 12.0 10.0 11.0 100.0))
     ((s4 :trading::encoding::MfiState) (:trading::encoding::MfiState::update s3 13.0 11.0 12.0 100.0))
     ((s5 :trading::encoding::MfiState) (:trading::encoding::MfiState::update s4 14.0 12.0 13.0 100.0))
     ((s6 :trading::encoding::MfiState) (:trading::encoding::MfiState::update s5 15.0 13.0 14.0 100.0)))
    (:wat::test::assert-eq
      (:trading::encoding::MfiState::value s6)
      100.0)))
