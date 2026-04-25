;; wat/encoding/indicator-bank/trend.wat — MACD + DMI/ADX.
;;
;; Lab arc 026 slice 3 (2026-04-25). Direct port of
;; archived/pre-wat-native/src/domain/indicator_bank.rs:391-434 (MACD)
;; / 436-535 (DMI/ADX).
;;
;; SMA20/50/200 are not separate types per BACKLOG — they're three
;; SmaState instances at different periods, held on the IndicatorBank
;; struct (slice 12). The SmaState mechanics are exercised by slice
;; 1's tests; slice 12's integration test cross-checks each SMA's
;; output against SmaState::value.
;;
;; MACD composes three EmaState instances (fast=12, slow=26,
;; signal=9). DMI composes four WilderState instances (plus_dm,
;; minus_dm, tr, adx) plus prev-high/low/close.
;;
;; Auto-generated accessors per field. Explicit:
;;   :trading::encoding::MacdState::fresh fast slow signal -> MacdState
;;   :trading::encoding::MacdState::update state close -> MacdState
;;   :trading::encoding::MacdState::macd-value state -> :f64
;;   :trading::encoding::MacdState::signal-value state -> :f64
;;   :trading::encoding::MacdState::hist-value state -> :f64
;;   :trading::encoding::MacdState::ready? state -> :bool
;;
;;   :trading::encoding::DmiState::fresh period -> DmiState
;;   :trading::encoding::DmiState::update state high low close -> DmiState
;;   :trading::encoding::DmiState::plus-di state -> :f64
;;   :trading::encoding::DmiState::minus-di state -> :f64
;;   :trading::encoding::DmiState::adx state -> :f64
;;   :trading::encoding::DmiState::ready? state -> :bool

(:wat::load-file! "primitives.wat")


;; ─── MACD ────────────────────────────────────────────────────────

(:wat::core::struct :trading::encoding::MacdState
  (fast-ema   :trading::encoding::EmaState)
  (slow-ema   :trading::encoding::EmaState)
  (signal-ema :trading::encoding::EmaState))


(:wat::core::define
  (:trading::encoding::MacdState::fresh
    (fast :i64)
    (slow :i64)
    (signal :i64)
    -> :trading::encoding::MacdState)
  (:trading::encoding::MacdState/new
    (:trading::encoding::EmaState::fresh fast)
    (:trading::encoding::EmaState::fresh slow)
    (:trading::encoding::EmaState::fresh signal)))


(:wat::core::define
  (:trading::encoding::MacdState::update
    (state :trading::encoding::MacdState)
    (close :f64)
    -> :trading::encoding::MacdState)
  (:wat::core::let*
    (((new-fast :trading::encoding::EmaState)
      (:trading::encoding::EmaState::update
        (:trading::encoding::MacdState/fast-ema state)
        close))
     ((new-slow :trading::encoding::EmaState)
      (:trading::encoding::EmaState::update
        (:trading::encoding::MacdState/slow-ema state)
        close))
     ((both-ready? :bool)
      (:wat::core::and
        (:trading::encoding::EmaState::ready? new-fast)
        (:trading::encoding::EmaState::ready? new-slow)))
     ((macd-val :f64)
      (:wat::core::-
        (:trading::encoding::EmaState/value new-fast)
        (:trading::encoding::EmaState/value new-slow)))
     ((new-signal :trading::encoding::EmaState)
      (:wat::core::if both-ready? -> :trading::encoding::EmaState
        (:trading::encoding::EmaState::update
          (:trading::encoding::MacdState/signal-ema state)
          macd-val)
        (:trading::encoding::MacdState/signal-ema state))))
    (:trading::encoding::MacdState/new new-fast new-slow new-signal)))


(:wat::core::define
  (:trading::encoding::MacdState::macd-value
    (state :trading::encoding::MacdState)
    -> :f64)
  (:wat::core::-
    (:trading::encoding::EmaState/value
      (:trading::encoding::MacdState/fast-ema state))
    (:trading::encoding::EmaState/value
      (:trading::encoding::MacdState/slow-ema state))))


(:wat::core::define
  (:trading::encoding::MacdState::signal-value
    (state :trading::encoding::MacdState)
    -> :f64)
  (:trading::encoding::EmaState/value
    (:trading::encoding::MacdState/signal-ema state)))


(:wat::core::define
  (:trading::encoding::MacdState::hist-value
    (state :trading::encoding::MacdState)
    -> :f64)
  (:wat::core::-
    (:trading::encoding::MacdState::macd-value state)
    (:trading::encoding::MacdState::signal-value state)))


(:wat::core::define
  (:trading::encoding::MacdState::ready?
    (state :trading::encoding::MacdState)
    -> :bool)
  (:wat::core::and
    (:trading::encoding::EmaState::ready?
      (:trading::encoding::MacdState/slow-ema state))
    (:trading::encoding::EmaState::ready?
      (:trading::encoding::MacdState/signal-ema state))))


;; ─── DMI / ADX ───────────────────────────────────────────────────

(:wat::core::struct :trading::encoding::DmiState
  (plus-smoother  :trading::encoding::WilderState)
  (minus-smoother :trading::encoding::WilderState)
  (tr-smoother    :trading::encoding::WilderState)
  (adx-smoother   :trading::encoding::WilderState)
  (prev-high      :f64)
  (prev-low       :f64)
  (prev-close     :f64)
  (started        :bool))


(:wat::core::define
  (:trading::encoding::DmiState::fresh
    (period :i64)
    -> :trading::encoding::DmiState)
  (:trading::encoding::DmiState/new
    (:trading::encoding::WilderState::fresh period)
    (:trading::encoding::WilderState::fresh period)
    (:trading::encoding::WilderState::fresh period)
    (:trading::encoding::WilderState::fresh period)
    0.0
    0.0
    0.0
    false))


(:wat::core::define
  (:trading::encoding::DmiState::update
    (state :trading::encoding::DmiState)
    (high :f64)
    (low :f64)
    (close :f64)
    -> :trading::encoding::DmiState)
  (:wat::core::let*
    (((started :bool) (:trading::encoding::DmiState/started state))
     ((prev-high :f64) (:trading::encoding::DmiState/prev-high state))
     ((prev-low :f64) (:trading::encoding::DmiState/prev-low state))
     ((prev-close :f64) (:trading::encoding::DmiState/prev-close state))
     ((plus-sm :trading::encoding::WilderState)
      (:trading::encoding::DmiState/plus-smoother state))
     ((minus-sm :trading::encoding::WilderState)
      (:trading::encoding::DmiState/minus-smoother state))
     ((tr-sm :trading::encoding::WilderState)
      (:trading::encoding::DmiState/tr-smoother state))
     ((adx-sm :trading::encoding::WilderState)
      (:trading::encoding::DmiState/adx-smoother state))
     ;; First-call branch: no prev — skip the smoother updates.
     ((up-move :f64)
      (:wat::core::if started -> :f64
        (:wat::core::- high prev-high)
        0.0))
     ((down-move :f64)
      (:wat::core::if started -> :f64
        (:wat::core::- prev-low low)
        0.0))
     ((plus-dm :f64)
      (:wat::core::if (:wat::core::and
                        (:wat::core::> up-move down-move)
                        (:wat::core::> up-move 0.0)) -> :f64
        up-move
        0.0))
     ((minus-dm :f64)
      (:wat::core::if (:wat::core::and
                        (:wat::core::> down-move up-move)
                        (:wat::core::> down-move 0.0)) -> :f64
        down-move
        0.0))
     ((tr :f64)
      (:wat::core::if started -> :f64
        (:wat::core::let*
          (((hl :f64) (:wat::core::- high low))
           ((hc :f64) (:wat::core::f64::abs (:wat::core::- high prev-close)))
           ((lc :f64) (:wat::core::f64::abs (:wat::core::- low prev-close))))
          (:wat::core::f64::max (:wat::core::f64::max hl hc) lc))
        0.0))
     ((new-plus-sm :trading::encoding::WilderState)
      (:wat::core::if started -> :trading::encoding::WilderState
        (:trading::encoding::WilderState::update plus-sm plus-dm)
        plus-sm))
     ((new-minus-sm :trading::encoding::WilderState)
      (:wat::core::if started -> :trading::encoding::WilderState
        (:trading::encoding::WilderState::update minus-sm minus-dm)
        minus-sm))
     ((new-tr-sm :trading::encoding::WilderState)
      (:wat::core::if started -> :trading::encoding::WilderState
        (:trading::encoding::WilderState::update tr-sm tr)
        tr-sm))
     ;; ADX update: only after tr-smoother is ready and DI sum is non-zero.
     ((tr-ready? :bool) (:trading::encoding::WilderState::ready? new-tr-sm))
     ((smoothed-tr :f64) (:trading::encoding::WilderState/value new-tr-sm))
     ((tr-positive? :bool)
      (:wat::core::and tr-ready? (:wat::core::> smoothed-tr 0.0)))
     ((plus-di-current :f64)
      (:wat::core::if tr-positive? -> :f64
        (:wat::core::/
          (:wat::core::* 100.0 (:trading::encoding::WilderState/value new-plus-sm))
          smoothed-tr)
        0.0))
     ((minus-di-current :f64)
      (:wat::core::if tr-positive? -> :f64
        (:wat::core::/
          (:wat::core::* 100.0 (:trading::encoding::WilderState/value new-minus-sm))
          smoothed-tr)
        0.0))
     ((di-sum :f64) (:wat::core::+ plus-di-current minus-di-current))
     ((dx :f64)
      (:wat::core::if (:wat::core::and tr-positive? (:wat::core::> di-sum 0.0)) -> :f64
        (:wat::core::/
          (:wat::core::* 100.0 (:wat::core::f64::abs (:wat::core::- plus-di-current minus-di-current)))
          di-sum)
        0.0))
     ((dx-firing? :bool)
      (:wat::core::and tr-positive? (:wat::core::> di-sum 0.0)))
     ((new-adx-sm :trading::encoding::WilderState)
      (:wat::core::if dx-firing? -> :trading::encoding::WilderState
        (:trading::encoding::WilderState::update adx-sm dx)
        adx-sm)))
    (:trading::encoding::DmiState/new
      new-plus-sm new-minus-sm new-tr-sm new-adx-sm
      high low close true)))


(:wat::core::define
  (:trading::encoding::DmiState::plus-di
    (state :trading::encoding::DmiState)
    -> :f64)
  (:wat::core::let*
    (((tr :f64)
      (:trading::encoding::WilderState/value
        (:trading::encoding::DmiState/tr-smoother state))))
    (:wat::core::if (:wat::core::= tr 0.0) -> :f64
      0.0
      (:wat::core::/
        (:wat::core::* 100.0
          (:trading::encoding::WilderState/value
            (:trading::encoding::DmiState/plus-smoother state)))
        tr))))


(:wat::core::define
  (:trading::encoding::DmiState::minus-di
    (state :trading::encoding::DmiState)
    -> :f64)
  (:wat::core::let*
    (((tr :f64)
      (:trading::encoding::WilderState/value
        (:trading::encoding::DmiState/tr-smoother state))))
    (:wat::core::if (:wat::core::= tr 0.0) -> :f64
      0.0
      (:wat::core::/
        (:wat::core::* 100.0
          (:trading::encoding::WilderState/value
            (:trading::encoding::DmiState/minus-smoother state)))
        tr))))


(:wat::core::define
  (:trading::encoding::DmiState::adx
    (state :trading::encoding::DmiState)
    -> :f64)
  (:trading::encoding::WilderState/value
    (:trading::encoding::DmiState/adx-smoother state)))


(:wat::core::define
  (:trading::encoding::DmiState::ready?
    (state :trading::encoding::DmiState)
    -> :bool)
  (:trading::encoding::WilderState::ready?
    (:trading::encoding::DmiState/adx-smoother state)))
