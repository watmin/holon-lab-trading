;; wat/encoding/indicator-bank/price-action.wat — Per-candle
;; price-shape indicators.
;;
;; Lab arc 026 slice 11 (2026-04-25). Direct port of archive's
;; step_price_action (line 1615-1625) + range_ratio / gap inline at
;; the IndicatorBank's per-tick computation (line 1832-1842).
;;
;;   range-ratio: high / low
;;   gap:         (open - prev_close) / prev_close
;;   ConsecutiveState: counts of consecutive up/down candles
;;
;; Auto-generated accessors per field. Explicit:
;;   :trading::encoding::compute-range-ratio :wat::core::f64 :wat::core::f64 -> :wat::core::f64
;;   :trading::encoding::compute-gap         :wat::core::f64 :wat::core::f64 -> :wat::core::f64
;;
;;   :trading::encoding::ConsecutiveState::fresh -> ConsecutiveState
;;   :trading::encoding::ConsecutiveState::update state close -> ConsecutiveState
;;   :trading::encoding::ConsecutiveState::up   state -> :wat::core::i64
;;   :trading::encoding::ConsecutiveState::down state -> :wat::core::i64

(:wat::load-file! "primitives.wat")


;; ─── range-ratio ──────────────────────────────────────────────────

(:wat::core::define
  (:trading::encoding::compute-range-ratio
    (high :wat::core::f64)
    (low :wat::core::f64)
    -> :wat::core::f64)
  (:wat::core::if (:wat::core::= low 0.0) -> :wat::core::f64
    1.0
    (:wat::core::/ high low)))


;; ─── gap ──────────────────────────────────────────────────────────

(:wat::core::define
  (:trading::encoding::compute-gap
    (open :wat::core::f64)
    (prev-close :wat::core::f64)
    -> :wat::core::f64)
  (:wat::core::if (:wat::core::= prev-close 0.0) -> :wat::core::f64
    0.0
    (:wat::core::/ (:wat::core::- open prev-close) prev-close)))


;; ─── Consecutive up/down counters ─────────────────────────────────

(:wat::core::struct :trading::encoding::ConsecutiveState
  (up-count   :wat::core::i64)
  (down-count :wat::core::i64)
  (prev-close :wat::core::f64)
  (started    :wat::core::bool))


(:wat::core::define
  (:trading::encoding::ConsecutiveState::fresh
    -> :trading::encoding::ConsecutiveState)
  (:trading::encoding::ConsecutiveState/new 0 0 0.0 false))


(:wat::core::define
  (:trading::encoding::ConsecutiveState::update
    (state :trading::encoding::ConsecutiveState)
    (close :wat::core::f64)
    -> :trading::encoding::ConsecutiveState)
  (:wat::core::let*
    (((started :wat::core::bool) (:trading::encoding::ConsecutiveState/started state))
     ((prev-close :wat::core::f64) (:trading::encoding::ConsecutiveState/prev-close state))
     ((old-up :wat::core::i64) (:trading::encoding::ConsecutiveState/up-count state))
     ((old-down :wat::core::i64) (:trading::encoding::ConsecutiveState/down-count state))
     ((new-up :wat::core::i64)
      (:wat::core::if (:wat::core::and started (:wat::core::> close prev-close))
                      -> :wat::core::i64
        (:wat::core::+ old-up 1)
        (:wat::core::if (:wat::core::and started (:wat::core::< close prev-close))
                        -> :wat::core::i64
          0
          old-up)))
     ((new-down :wat::core::i64)
      (:wat::core::if (:wat::core::and started (:wat::core::< close prev-close))
                      -> :wat::core::i64
        (:wat::core::+ old-down 1)
        (:wat::core::if (:wat::core::and started (:wat::core::> close prev-close))
                        -> :wat::core::i64
          0
          old-down))))
    (:trading::encoding::ConsecutiveState/new new-up new-down close true)))


(:wat::core::define
  (:trading::encoding::ConsecutiveState::up
    (state :trading::encoding::ConsecutiveState)
    -> :wat::core::i64)
  (:trading::encoding::ConsecutiveState/up-count state))


(:wat::core::define
  (:trading::encoding::ConsecutiveState::down
    (state :trading::encoding::ConsecutiveState)
    -> :wat::core::i64)
  (:trading::encoding::ConsecutiveState/down-count state))
