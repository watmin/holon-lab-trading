;; wat-tests/encoding/indicator-bank/bank.wat — Lab arc 026 slice 12.
;;
;; Tests IndicatorBank::fresh + ::tick. Cross-checks Candle field
;; values against the underlying state machines to confirm the
;; orchestration is faithful.

(:wat::test::make-deftest :deftest
  ((:wat::load-file! "wat/encoding/indicator-bank/bank.wat")

   ;; Fresh Ohlcv builder for tests.
   (:wat::core::define
     (:test::ohlcv
       (open :f64) (high :f64) (low :f64) (close :f64) (volume :f64)
       -> :trading::types::Ohlcv)
     (:trading::types::Ohlcv/new
       (:trading::types::Asset/new "BTC")
       (:trading::types::Asset/new "USDC")
       "2024-01-01T00:00:00Z"
       open high low close volume))

   ;; Tail-recursive feeder: tick `n` times with the same Ohlcv.
   (:wat::core::define
     (:test::feed
       (bank :trading::encoding::IndicatorBank)
       (oh :trading::types::Ohlcv)
       (n :i64)
       -> :trading::encoding::IndicatorBank)
     (:wat::core::if (:wat::core::<= n 0)
                     -> :trading::encoding::IndicatorBank
       bank
       (:test::feed
         (:wat::core::first
           (:trading::encoding::IndicatorBank::tick bank oh))
         oh
         (:wat::core::- n 1))))))


;; ─── Construction ────────────────────────────────────────────────

;; Test 1 — fresh bank: count = 0.
(:deftest :trading::test::encoding::indicator-bank::test-bank-fresh-count-zero
  (:wat::core::let*
    (((bank :trading::encoding::IndicatorBank)
      (:trading::encoding::IndicatorBank::fresh)))
    (:wat::test::assert-eq
      (:trading::encoding::IndicatorBank/count bank)
      0)))


;; ─── First tick — cross-check Candle fields ──────────────────────

;; Test 2 — first tick: count goes to 1.
(:deftest :trading::test::encoding::indicator-bank::test-bank-tick-increments-count
  (:wat::core::let*
    (((bank :trading::encoding::IndicatorBank)
      (:trading::encoding::IndicatorBank::fresh))
     ((oh :trading::types::Ohlcv)
      (:test::ohlcv 100.0 110.0 95.0 105.0 50.0))
     ((result :(trading::encoding::IndicatorBank,trading::types::Candle))
      (:trading::encoding::IndicatorBank::tick bank oh))
     ((bank' :trading::encoding::IndicatorBank) (:wat::core::first result)))
    (:wat::test::assert-eq
      (:trading::encoding::IndicatorBank/count bank')
      1)))

;; Test 3 — Candle's ohlcv round-trips.
(:deftest :trading::test::encoding::indicator-bank::test-bank-tick-candle-ohlcv
  (:wat::core::let*
    (((bank :trading::encoding::IndicatorBank)
      (:trading::encoding::IndicatorBank::fresh))
     ((oh :trading::types::Ohlcv)
      (:test::ohlcv 100.0 110.0 95.0 105.0 50.0))
     ((result :(trading::encoding::IndicatorBank,trading::types::Candle))
      (:trading::encoding::IndicatorBank::tick bank oh))
     ((candle :trading::types::Candle) (:wat::core::second result))
     ((cohlcv :trading::types::Ohlcv) (:trading::types::Candle/ohlcv candle)))
    (:wat::test::assert-eq
      (:trading::types::Ohlcv/close cohlcv)
      105.0)))


;; ─── SMA cross-check ─────────────────────────────────────────────

;; Test 4 — after 20 flat-100 candles, candle.trend.sma20 == bank.sma20 value == 100.
(:deftest :trading::test::encoding::indicator-bank::test-bank-cross-check-sma20
  (:wat::core::let*
    (((bank0 :trading::encoding::IndicatorBank)
      (:trading::encoding::IndicatorBank::fresh))
     ((oh :trading::types::Ohlcv)
      (:test::ohlcv 100.0 100.0 100.0 100.0 50.0))
     ((bank20 :trading::encoding::IndicatorBank)
      (:test::feed bank0 oh 20))
     ((sma-from-state :f64)
      (:trading::encoding::SmaState::value
        (:trading::encoding::IndicatorBank/sma20 bank20)))
     ;; Tick once more to also produce a Candle reflecting the same state.
     ((result :(trading::encoding::IndicatorBank,trading::types::Candle))
      (:trading::encoding::IndicatorBank::tick bank20 oh))
     ((candle :trading::types::Candle) (:wat::core::second result))
     ((sma-from-candle :f64)
      (:trading::types::Candle::Trend/sma20
        (:trading::types::Candle/trend candle))))
    (:wat::core::let*
      (((u1 :()) (:wat::test::assert-eq sma-from-state 100.0)))
      (:wat::test::assert-eq sma-from-candle 100.0))))


;; ─── RSI cross-check ─────────────────────────────────────────────

;; Test 5 — after enough flat ticks, RSI value matches Candle field.
(:deftest :trading::test::encoding::indicator-bank::test-bank-cross-check-rsi
  (:wat::core::let*
    (((bank0 :trading::encoding::IndicatorBank)
      (:trading::encoding::IndicatorBank::fresh))
     ((oh :trading::types::Ohlcv)
      (:test::ohlcv 100.0 100.0 100.0 100.0 50.0))
     ((bank20 :trading::encoding::IndicatorBank)
      (:test::feed bank0 oh 20))
     ((rsi-from-state :f64)
      (:trading::encoding::RsiState::value
        (:trading::encoding::IndicatorBank/rsi bank20)))
     ((result :(trading::encoding::IndicatorBank,trading::types::Candle))
      (:trading::encoding::IndicatorBank::tick bank20 oh))
     ((candle :trading::types::Candle) (:wat::core::second result))
     ((rsi-from-candle :f64)
      (:trading::types::Candle::Momentum/rsi
        (:trading::types::Candle/momentum candle))))
    ;; Flat input → RSI = 100 (no losses).
    (:wat::core::let*
      (((u1 :()) (:wat::test::assert-eq rsi-from-state 100.0)))
      (:wat::test::assert-eq rsi-from-candle 100.0))))


;; ─── Phase-label cross-check ─────────────────────────────────────

;; Test 6 — phase-label on fresh tick is Valley (matches PhaseState's
;; first-candle initialization).
(:deftest :trading::test::encoding::indicator-bank::test-bank-cross-check-phase-label
  (:wat::core::let*
    (((bank0 :trading::encoding::IndicatorBank)
      (:trading::encoding::IndicatorBank::fresh))
     ((oh :trading::types::Ohlcv)
      (:test::ohlcv 100.0 110.0 95.0 105.0 50.0))
     ((result :(trading::encoding::IndicatorBank,trading::types::Candle))
      (:trading::encoding::IndicatorBank::tick bank0 oh))
     ((candle :trading::types::Candle) (:wat::core::second result))
     ((label :trading::types::PhaseLabel)
      (:trading::types::Candle::Phase/label
        (:trading::types::Candle/phase candle)))
     ((is-valley? :bool)
      (:wat::core::match label -> :bool
        (:trading::types::PhaseLabel::Valley true)
        (_ false))))
    (:wat::test::assert-eq is-valley? true)))


;; ─── Multi-tick ready gates fire ─────────────────────────────────

;; Test 7 — after 200+ flat ticks, sma200 ready; sma200 value matches.
(:deftest :trading::test::encoding::indicator-bank::test-bank-sma200-ready-after-warmup
  (:wat::core::let*
    (((bank0 :trading::encoding::IndicatorBank)
      (:trading::encoding::IndicatorBank::fresh))
     ((oh :trading::types::Ohlcv)
      (:test::ohlcv 100.0 100.0 100.0 100.0 50.0))
     ((bank200 :trading::encoding::IndicatorBank)
      (:test::feed bank0 oh 200))
     ((ready? :bool)
      (:trading::encoding::SmaState::ready?
        (:trading::encoding::IndicatorBank/sma200 bank200))))
    (:wat::test::assert-eq ready? true)))
