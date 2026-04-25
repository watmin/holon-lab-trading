;; wat/encoding/indicator-bank/volatility.wat — Bollinger + Keltner +
;; squeeze + ATR-ratio.
;;
;; Lab arc 026 slice 4 (2026-04-25). Direct port of the volatility
;; computations in archived/pre-wat-native/src/domain/indicator_bank.rs
;; (bb_width / bb_pos / kelt_width / kelt_pos / squeeze / atr_ratio
;; sites at lines 1670-1760).
;;
;; Bollinger composes SmaState + RollingStddev (the latter shipped
;; alongside this slice in primitives.wat). Keltner wraps an EmaState;
;; bands derive from EMA + ATR at compute time (ATR passed in, not
;; stored — matches IndicatorBank's atr-once policy). Squeeze and
;; atr-ratio are pure scalar computes.
;;
;; Substrate uplift carried alongside: `:wat::std::math::sqrt`
;; (wat-rs commit c750fe2). Same shape as ln/exp/sin/cos.
;;
;; Auto-generated accessors per field. Explicit:
;;   :trading::encoding::BollingerState::fresh period -> BollingerState
;;   :trading::encoding::BollingerState::update state close -> BollingerState
;;   :trading::encoding::BollingerState::upper state -> :f64
;;   :trading::encoding::BollingerState::lower state -> :f64
;;   :trading::encoding::BollingerState::width state -> :f64
;;   :trading::encoding::BollingerState::pos   state close -> :f64
;;   :trading::encoding::BollingerState::ready? state -> :bool
;;
;;   :trading::encoding::KeltnerState::fresh period -> KeltnerState
;;   :trading::encoding::KeltnerState::update state close -> KeltnerState
;;   :trading::encoding::KeltnerState::upper state atr -> :f64
;;   :trading::encoding::KeltnerState::lower state atr -> :f64
;;   :trading::encoding::KeltnerState::pos   state atr close -> :f64
;;   :trading::encoding::KeltnerState::ready? state -> :bool
;;
;;   :trading::encoding::compute-squeeze   bb-width kelt-width -> :f64
;;   :trading::encoding::compute-atr-ratio atr close -> :f64

(:wat::load-file! "primitives.wat")


;; ─── Bollinger Bands ──────────────────────────────────────────────

(:wat::core::struct :trading::encoding::BollingerState
  (sma    :trading::encoding::SmaState)
  (stddev :trading::encoding::RollingStddev))


(:wat::core::define
  (:trading::encoding::BollingerState::fresh
    (period :i64)
    -> :trading::encoding::BollingerState)
  (:trading::encoding::BollingerState/new
    (:trading::encoding::SmaState::fresh period)
    (:trading::encoding::RollingStddev::fresh period)))


(:wat::core::define
  (:trading::encoding::BollingerState::update
    (state :trading::encoding::BollingerState)
    (close :f64)
    -> :trading::encoding::BollingerState)
  (:trading::encoding::BollingerState/new
    (:trading::encoding::SmaState::update
      (:trading::encoding::BollingerState/sma state)
      close)
    (:trading::encoding::RollingStddev::update
      (:trading::encoding::BollingerState/stddev state)
      close)))


;; Upper band: SMA + 2·stddev. Lower: SMA - 2·stddev.
(:wat::core::define
  (:trading::encoding::BollingerState::upper
    (state :trading::encoding::BollingerState)
    -> :f64)
  (:wat::core::+
    (:trading::encoding::SmaState::value
      (:trading::encoding::BollingerState/sma state))
    (:wat::core::* 2.0
      (:trading::encoding::RollingStddev::value
        (:trading::encoding::BollingerState/stddev state)))))


(:wat::core::define
  (:trading::encoding::BollingerState::lower
    (state :trading::encoding::BollingerState)
    -> :f64)
  (:wat::core::-
    (:trading::encoding::SmaState::value
      (:trading::encoding::BollingerState/sma state))
    (:wat::core::* 2.0
      (:trading::encoding::RollingStddev::value
        (:trading::encoding::BollingerState/stddev state)))))


;; bb-width: (upper - lower) / sma. Returns 0 if sma is 0.
(:wat::core::define
  (:trading::encoding::BollingerState::width
    (state :trading::encoding::BollingerState)
    -> :f64)
  (:wat::core::let*
    (((sma :f64)
      (:trading::encoding::SmaState::value
        (:trading::encoding::BollingerState/sma state)))
     ((upper :f64) (:trading::encoding::BollingerState::upper state))
     ((lower :f64) (:trading::encoding::BollingerState::lower state)))
    (:wat::core::if (:wat::core::= sma 0.0) -> :f64
      0.0
      (:wat::core::/ (:wat::core::- upper lower) sma))))


;; bb-pos: (close - lower) / (upper - lower). Returns 0.5 if band is degenerate.
(:wat::core::define
  (:trading::encoding::BollingerState::pos
    (state :trading::encoding::BollingerState)
    (close :f64)
    -> :f64)
  (:wat::core::let*
    (((upper :f64) (:trading::encoding::BollingerState::upper state))
     ((lower :f64) (:trading::encoding::BollingerState::lower state))
     ((range :f64) (:wat::core::- upper lower)))
    (:wat::core::if (:wat::core::= range 0.0) -> :f64
      0.5
      (:wat::core::/ (:wat::core::- close lower) range))))


(:wat::core::define
  (:trading::encoding::BollingerState::ready?
    (state :trading::encoding::BollingerState)
    -> :bool)
  (:trading::encoding::SmaState::ready?
    (:trading::encoding::BollingerState/sma state)))


;; ─── Keltner Channels ─────────────────────────────────────────────

(:wat::core::struct :trading::encoding::KeltnerState
  (ema :trading::encoding::EmaState))


(:wat::core::define
  (:trading::encoding::KeltnerState::fresh
    (period :i64)
    -> :trading::encoding::KeltnerState)
  (:trading::encoding::KeltnerState/new
    (:trading::encoding::EmaState::fresh period)))


(:wat::core::define
  (:trading::encoding::KeltnerState::update
    (state :trading::encoding::KeltnerState)
    (close :f64)
    -> :trading::encoding::KeltnerState)
  (:trading::encoding::KeltnerState/new
    (:trading::encoding::EmaState::update
      (:trading::encoding::KeltnerState/ema state)
      close)))


;; Keltner bands: EMA ± 2·ATR. ATR passed in (computed once on the
;; bank by AtrState; no duplication).
(:wat::core::define
  (:trading::encoding::KeltnerState::upper
    (state :trading::encoding::KeltnerState)
    (atr :f64)
    -> :f64)
  (:wat::core::+
    (:trading::encoding::EmaState/value
      (:trading::encoding::KeltnerState/ema state))
    (:wat::core::* 2.0 atr)))


(:wat::core::define
  (:trading::encoding::KeltnerState::lower
    (state :trading::encoding::KeltnerState)
    (atr :f64)
    -> :f64)
  (:wat::core::-
    (:trading::encoding::EmaState/value
      (:trading::encoding::KeltnerState/ema state))
    (:wat::core::* 2.0 atr)))


(:wat::core::define
  (:trading::encoding::KeltnerState::pos
    (state :trading::encoding::KeltnerState)
    (atr :f64)
    (close :f64)
    -> :f64)
  (:wat::core::let*
    (((upper :f64) (:trading::encoding::KeltnerState::upper state atr))
     ((lower :f64) (:trading::encoding::KeltnerState::lower state atr))
     ((range :f64) (:wat::core::- upper lower)))
    (:wat::core::if (:wat::core::= range 0.0) -> :f64
      0.5
      (:wat::core::/ (:wat::core::- close lower) range))))


(:wat::core::define
  (:trading::encoding::KeltnerState::ready?
    (state :trading::encoding::KeltnerState)
    -> :bool)
  (:trading::encoding::EmaState::ready?
    (:trading::encoding::KeltnerState/ema state)))


;; ─── Squeeze + ATR-ratio (pure computes) ──────────────────────────

;; squeeze: bb-width / kelt-width. < 1 means BB inside Keltner →
;; volatility compressed; classic squeeze setup.
(:wat::core::define
  (:trading::encoding::compute-squeeze
    (bb-width :f64)
    (kelt-width :f64)
    -> :f64)
  (:wat::core::if (:wat::core::= kelt-width 0.0) -> :f64
    0.0
    (:wat::core::/ bb-width kelt-width)))


;; atr-ratio: atr / close — ATR as a fraction of price.
(:wat::core::define
  (:trading::encoding::compute-atr-ratio
    (atr :f64)
    (close :f64)
    -> :f64)
  (:wat::core::if (:wat::core::= close 0.0) -> :f64
    0.0
    (:wat::core::/ atr close)))
