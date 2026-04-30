;; wat/encoding/indicator-bank/volume.wat — OBV + volume-accel.
;;
;; Lab arc 026 slice 5 (2026-04-25). Direct port of
;; archived/pre-wat-native/src/domain/indicator_bank.rs:356-389 (OBV)
;; / 1508-1522 (step_obv) / 1213-1239 + linreg_slope helper for OBV
;; slope / 1822-1828 (volume_accel).
;;
;; OBV: cumulative on-balance volume. Adds volume on up-close, subtracts
;; on down-close, no change on flat. Slope over a history RingBuffer
;; gives the trend signal vocab modules consume.
;;
;; volume-accel: current volume / SMA(20) of volume. Ratio > 1 means
;; "this candle's volume above its 20-period average." Defensive
;; fallback to 1.0 on degenerate sma.
;;
;; Auto-generated accessors per field. Explicit:
;;   :trading::encoding::ObvState::fresh history-len -> ObvState
;;   :trading::encoding::ObvState::update state close volume -> ObvState
;;   :trading::encoding::ObvState::value state -> :wat::core::f64
;;   :trading::encoding::ObvState::slope state -> :wat::core::f64
;;
;;   :trading::encoding::VolumeAccelState::fresh period -> VolumeAccelState
;;   :trading::encoding::VolumeAccelState::update state volume -> VolumeAccelState
;;   :trading::encoding::VolumeAccelState::value state -> :wat::core::f64
;;
;;   :trading::encoding::compute-linreg-slope :Vec<f64> -> :wat::core::f64
;;     (free function; pure linear-regression slope over indices 0..n)

(:wat::load-file! "primitives.wat")


;; ─── linreg-slope — pure linear-regression slope ──────────────────
;;
;; Treats indices 0..n as x, the values as y. Returns slope. Returns
;; 0 for n < 2 (can't fit a line) or for degenerate denominators
;; (constant x-distribution — never happens for sequential indices).
;;
;; Two passes over the Vec: one for y-mean, one for the cross-products.
(:wat::core::define
  (:trading::encoding::compute-linreg-slope
    (ys :Vec<f64>)
    -> :wat::core::f64)
  (:wat::core::let*
    (((n :wat::core::i64) (:wat::core::length ys)))
    (:wat::core::if (:wat::core::< n 2) -> :wat::core::f64
      0.0
      (:wat::core::let*
        (((nf :wat::core::f64) (:wat::core::i64::to-f64 n))
         ((x-mean :wat::core::f64) (:wat::core::/ (:wat::core::- nf 1.0) 2.0))
         ((y-sum :wat::core::f64)
          (:wat::core::foldl ys 0.0
            (:wat::core::lambda ((acc :wat::core::f64) (y :wat::core::f64) -> :wat::core::f64)
              (:wat::core::+ acc y))))
         ((y-mean :wat::core::f64) (:wat::core::/ y-sum nf))
         ;; Single foldl over (i, y) pairs: build i alongside y by
         ;; index-mapping. Cleanest expression in wat is to enumerate.
         ((indexed :Vec<(i64,f64)>)
          (:wat::core::map
            (:wat::core::range 0 n)
            (:wat::core::lambda ((i :wat::core::i64) -> :(i64,f64))
              (:wat::core::tuple
                i
                (:wat::core::match (:wat::core::get ys i) -> :wat::core::f64
                  ((Some v) v)
                  (:None 0.0))))))
         ((num+den :(f64,f64))
          (:wat::core::foldl indexed
            (:wat::core::tuple 0.0 0.0)
            (:wat::core::lambda
              ((acc :(f64,f64)) (pair :(i64,f64))
               -> :(f64,f64))
              (:wat::core::let*
                (((num :wat::core::f64) (:wat::core::first acc))
                 ((den :wat::core::f64) (:wat::core::second acc))
                 ((i :wat::core::i64) (:wat::core::first pair))
                 ((y :wat::core::f64) (:wat::core::second pair))
                 ((dx :wat::core::f64) (:wat::core::- (:wat::core::i64::to-f64 i) x-mean)))
                (:wat::core::tuple
                  (:wat::core::+ num (:wat::core::* dx (:wat::core::- y y-mean)))
                  (:wat::core::+ den (:wat::core::* dx dx)))))))
         ((num :wat::core::f64) (:wat::core::first num+den))
         ((den :wat::core::f64) (:wat::core::second num+den)))
        (:wat::core::if (:wat::core::= den 0.0) -> :wat::core::f64
          0.0
          (:wat::core::/ num den))))))


;; ─── ObvState — cumulative on-balance volume + history ────────────

(:wat::core::struct :trading::encoding::ObvState
  (obv        :wat::core::f64)
  (prev-close :wat::core::f64)
  (history    :trading::encoding::RingBuffer)
  (started    :wat::core::bool))


(:wat::core::define
  (:trading::encoding::ObvState::fresh
    (history-len :wat::core::i64)
    -> :trading::encoding::ObvState)
  (:trading::encoding::ObvState/new
    0.0
    0.0
    (:trading::encoding::RingBuffer::fresh history-len)
    false))


(:wat::core::define
  (:trading::encoding::ObvState::update
    (state :trading::encoding::ObvState)
    (close :wat::core::f64)
    (volume :wat::core::f64)
    -> :trading::encoding::ObvState)
  (:wat::core::let*
    (((started :wat::core::bool) (:trading::encoding::ObvState/started state))
     ((prev-close :wat::core::f64) (:trading::encoding::ObvState/prev-close state))
     ((old-obv :wat::core::f64) (:trading::encoding::ObvState/obv state))
     ((new-obv :wat::core::f64)
      (:wat::core::if started -> :wat::core::f64
        (:wat::core::if (:wat::core::> close prev-close) -> :wat::core::f64
          (:wat::core::+ old-obv volume)
          (:wat::core::if (:wat::core::< close prev-close) -> :wat::core::f64
            (:wat::core::- old-obv volume)
            old-obv))
        old-obv))
     ((new-history :trading::encoding::RingBuffer)
      (:trading::encoding::RingBuffer::push
        (:trading::encoding::ObvState/history state)
        new-obv)))
    (:trading::encoding::ObvState/new new-obv close new-history true)))


(:wat::core::define
  (:trading::encoding::ObvState::value
    (state :trading::encoding::ObvState)
    -> :wat::core::f64)
  (:trading::encoding::ObvState/obv state))


;; OBV slope over the history. Returns 0 for under-3-point histories
;; (matches archive's `obv_slope_12`).
(:wat::core::define
  (:trading::encoding::ObvState::slope
    (state :trading::encoding::ObvState)
    -> :wat::core::f64)
  (:trading::encoding::compute-linreg-slope
    (:trading::encoding::RingBuffer/values
      (:trading::encoding::ObvState/history state))))


;; ─── VolumeAccelState — current volume / SMA20 of volume ──────────

(:wat::core::struct :trading::encoding::VolumeAccelState
  (volume-sma  :trading::encoding::SmaState)
  (last-volume :wat::core::f64))


(:wat::core::define
  (:trading::encoding::VolumeAccelState::fresh
    (period :wat::core::i64)
    -> :trading::encoding::VolumeAccelState)
  (:trading::encoding::VolumeAccelState/new
    (:trading::encoding::SmaState::fresh period)
    0.0))


(:wat::core::define
  (:trading::encoding::VolumeAccelState::update
    (state :trading::encoding::VolumeAccelState)
    (volume :wat::core::f64)
    -> :trading::encoding::VolumeAccelState)
  (:trading::encoding::VolumeAccelState/new
    (:trading::encoding::SmaState::update
      (:trading::encoding::VolumeAccelState/volume-sma state)
      volume)
    volume))


;; volume_accel: last_volume / sma_value. Defensive fallback to 1.0
;; when sma is 0 (matches archive).
(:wat::core::define
  (:trading::encoding::VolumeAccelState::value
    (state :trading::encoding::VolumeAccelState)
    -> :wat::core::f64)
  (:wat::core::let*
    (((sma :wat::core::f64)
      (:trading::encoding::SmaState::value
        (:trading::encoding::VolumeAccelState/volume-sma state)))
     ((vol :wat::core::f64) (:trading::encoding::VolumeAccelState/last-volume state)))
    (:wat::core::if (:wat::core::= sma 0.0) -> :wat::core::f64
      1.0
      (:wat::core::/ vol sma))))
