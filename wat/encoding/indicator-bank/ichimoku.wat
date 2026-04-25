;; wat/encoding/indicator-bank/ichimoku.wat — Ichimoku Cloud.
;;
;; Lab arc 026 slice 8 (2026-04-25). Direct port of
;; archived/pre-wat-native/src/domain/indicator_bank.rs:694-747 +
;; lines 1773-1781 (cloud computation) + 1709 (tk-cross-delta).
;;
;; Six RingBuffers (high/low at periods 9, 26, 52). Tenkan = (high_9
;; max + low_9 min) / 2; kijun = (high_26 + low_26) / 2; senkou_a =
;; (tenkan + kijun) / 2; senkou_b = (high_52 + low_52) / 2; cloud_top
;; = max(senkou_a, senkou_b); cloud_bottom = min.
;;
;; tk_cross_delta tracked across ticks: stores prev_tenkan and
;; prev_kijun on the state, computes (tenkan - kijun) -
;; (prev_tenkan - prev_kijun) per tick (matches archive's
;; prev_tk_spread maintenance).
;;
;; Auto-generated accessors per field. Explicit:
;;   :trading::encoding::IchimokuState::fresh -> IchimokuState
;;   :trading::encoding::IchimokuState::update state high low -> IchimokuState
;;   :trading::encoding::IchimokuState::tenkan       state -> :f64
;;   :trading::encoding::IchimokuState::kijun        state -> :f64
;;   :trading::encoding::IchimokuState::senkou-a     state -> :f64
;;   :trading::encoding::IchimokuState::senkou-b     state -> :f64
;;   :trading::encoding::IchimokuState::cloud-top    state -> :f64
;;   :trading::encoding::IchimokuState::cloud-bottom state -> :f64
;;   :trading::encoding::IchimokuState::tk-cross-delta state -> :f64
;;   :trading::encoding::IchimokuState::ready?       state -> :bool

(:wat::load-file! "primitives.wat")


(:wat::core::struct :trading::encoding::IchimokuState
  (high-9       :trading::encoding::RingBuffer)
  (low-9        :trading::encoding::RingBuffer)
  (high-26      :trading::encoding::RingBuffer)
  (low-26       :trading::encoding::RingBuffer)
  (high-52      :trading::encoding::RingBuffer)
  (low-52       :trading::encoding::RingBuffer)
  (prev-tenkan  :f64)
  (prev-kijun   :f64))


(:wat::core::define
  (:trading::encoding::IchimokuState::fresh
    -> :trading::encoding::IchimokuState)
  (:trading::encoding::IchimokuState/new
    (:trading::encoding::RingBuffer::fresh 9)
    (:trading::encoding::RingBuffer::fresh 9)
    (:trading::encoding::RingBuffer::fresh 26)
    (:trading::encoding::RingBuffer::fresh 26)
    (:trading::encoding::RingBuffer::fresh 52)
    (:trading::encoding::RingBuffer::fresh 52)
    0.0
    0.0))


;; Internal — compute (max + min) / 2 over a high/low pair. The :None
;; arms are unreachable in practice (caller checks `ready?` for the
;; relevant period); sentinel 0.0 satisfies the type checker.
(:wat::core::define
  (:trading::encoding::ichimoku::midpoint
    (high-buf :trading::encoding::RingBuffer)
    (low-buf :trading::encoding::RingBuffer)
    -> :f64)
  (:wat::core::let*
    (((highest :f64)
      (:wat::core::match
        (:trading::encoding::RingBuffer::max high-buf) -> :f64
        ((Some v) v) (:None 0.0)))
     ((lowest :f64)
      (:wat::core::match
        (:trading::encoding::RingBuffer::min low-buf) -> :f64
        ((Some v) v) (:None 0.0))))
    (:wat::core::/ (:wat::core::+ highest lowest) 2.0)))


(:wat::core::define
  (:trading::encoding::IchimokuState::tenkan
    (state :trading::encoding::IchimokuState)
    -> :f64)
  (:trading::encoding::ichimoku::midpoint
    (:trading::encoding::IchimokuState/high-9 state)
    (:trading::encoding::IchimokuState/low-9 state)))


(:wat::core::define
  (:trading::encoding::IchimokuState::kijun
    (state :trading::encoding::IchimokuState)
    -> :f64)
  (:trading::encoding::ichimoku::midpoint
    (:trading::encoding::IchimokuState/high-26 state)
    (:trading::encoding::IchimokuState/low-26 state)))


(:wat::core::define
  (:trading::encoding::IchimokuState::senkou-a
    (state :trading::encoding::IchimokuState)
    -> :f64)
  (:wat::core::/
    (:wat::core::+
      (:trading::encoding::IchimokuState::tenkan state)
      (:trading::encoding::IchimokuState::kijun state))
    2.0))


(:wat::core::define
  (:trading::encoding::IchimokuState::senkou-b
    (state :trading::encoding::IchimokuState)
    -> :f64)
  (:trading::encoding::ichimoku::midpoint
    (:trading::encoding::IchimokuState/high-52 state)
    (:trading::encoding::IchimokuState/low-52 state)))


(:wat::core::define
  (:trading::encoding::IchimokuState::cloud-top
    (state :trading::encoding::IchimokuState)
    -> :f64)
  (:wat::core::f64::max
    (:trading::encoding::IchimokuState::senkou-a state)
    (:trading::encoding::IchimokuState::senkou-b state)))


(:wat::core::define
  (:trading::encoding::IchimokuState::cloud-bottom
    (state :trading::encoding::IchimokuState)
    -> :f64)
  (:wat::core::f64::min
    (:trading::encoding::IchimokuState::senkou-a state)
    (:trading::encoding::IchimokuState::senkou-b state)))


;; tk-cross-delta = (tenkan - kijun) - (prev_tenkan - prev_kijun).
;; Captures momentum of the tenkan/kijun spread.
(:wat::core::define
  (:trading::encoding::IchimokuState::tk-cross-delta
    (state :trading::encoding::IchimokuState)
    -> :f64)
  (:wat::core::let*
    (((tenkan :f64) (:trading::encoding::IchimokuState::tenkan state))
     ((kijun :f64) (:trading::encoding::IchimokuState::kijun state))
     ((tk-spread :f64) (:wat::core::- tenkan kijun))
     ((prev-spread :f64)
      (:wat::core::-
        (:trading::encoding::IchimokuState/prev-tenkan state)
        (:trading::encoding::IchimokuState/prev-kijun state))))
    (:wat::core::- tk-spread prev-spread)))


(:wat::core::define
  (:trading::encoding::IchimokuState::update
    (state :trading::encoding::IchimokuState)
    (high :f64)
    (low :f64)
    -> :trading::encoding::IchimokuState)
  (:wat::core::let*
    (;; Capture current tenkan/kijun BEFORE pushing this candle's
     ;; high/low so they become the "prev" for next tick's
     ;; tk-cross-delta.
     ((tenkan :f64) (:trading::encoding::IchimokuState::tenkan state))
     ((kijun :f64) (:trading::encoding::IchimokuState::kijun state)))
    (:trading::encoding::IchimokuState/new
      (:trading::encoding::RingBuffer::push
        (:trading::encoding::IchimokuState/high-9 state) high)
      (:trading::encoding::RingBuffer::push
        (:trading::encoding::IchimokuState/low-9 state) low)
      (:trading::encoding::RingBuffer::push
        (:trading::encoding::IchimokuState/high-26 state) high)
      (:trading::encoding::RingBuffer::push
        (:trading::encoding::IchimokuState/low-26 state) low)
      (:trading::encoding::RingBuffer::push
        (:trading::encoding::IchimokuState/high-52 state) high)
      (:trading::encoding::RingBuffer::push
        (:trading::encoding::IchimokuState/low-52 state) low)
      tenkan
      kijun)))


;; Ready when the slowest period (52) has filled.
(:wat::core::define
  (:trading::encoding::IchimokuState::ready?
    (state :trading::encoding::IchimokuState)
    -> :bool)
  (:trading::encoding::RingBuffer::full?
    (:trading::encoding::IchimokuState/high-52 state)))
