;; wat/encoding/indicator-bank/rate.wat — ROC + range-pos.
;;
;; Lab arc 026 slice 6 (2026-04-25). Direct port of
;; archived/pre-wat-native/src/domain/indicator_bank.rs:1132-1155.
;;
;; Pure compute functions — no state structs of their own. The
;; IndicatorBank holds RingBuffers at the relevant periods (closes
;; for ROC; high/low pairs at periods 12/24/48 for range-pos) and
;; calls these functions per tick.
;;
;; ROC at period N: (close - close[N-ago]) / close[N-ago]. Returns
;; 0 on under-(N+1) buffer (can't look back N steps).
;;
;; range-pos: where close sits in the high/low envelope, in [0, 1]
;; with 0.5 fallback for degenerate (zero-range) windows.
;;
;; Explicit:
;;   :trading::encoding::compute-roc       buf n -> :wat::core::f64
;;   :trading::encoding::compute-range-pos high-buf low-buf close -> :wat::core::f64

(:wat::load-file! "primitives.wat")


;; ROC — rate of change at period n. Newest = get(0), past = get(n).
(:wat::core::define
  (:trading::encoding::compute-roc
    (buf :trading::encoding::RingBuffer)
    (n :wat::core::i64)
    -> :wat::core::f64)
  (:wat::core::let*
    (((len :wat::core::i64) (:trading::encoding::RingBuffer::len buf)))
    (:wat::core::if (:wat::core::< len (:wat::core::+ n 1)) -> :wat::core::f64
      0.0
      (:wat::core::let*
        (((current :wat::core::f64)
          (:wat::core::match
            (:trading::encoding::RingBuffer::get buf 0) -> :wat::core::f64
            ((Some v) v)
            (:None 0.0)))
         ((past :wat::core::f64)
          (:wat::core::match
            (:trading::encoding::RingBuffer::get buf n) -> :wat::core::f64
            ((Some v) v)
            (:None 0.0))))
        (:wat::core::if (:wat::core::= past 0.0) -> :wat::core::f64
          0.0
          (:wat::core::/ (:wat::core::- current past) past))))))


;; Range-pos — (close - lowest) / (highest - lowest). 0.5 on degenerate
;; (zero-range) windows. The :None arms below are unreachable in
;; practice (caller's IndicatorBank only calls when buffers have data),
;; but max/min of empty Option<f64> defends them anyway.
(:wat::core::define
  (:trading::encoding::compute-range-pos
    (high-buf :trading::encoding::RingBuffer)
    (low-buf :trading::encoding::RingBuffer)
    (close :wat::core::f64)
    -> :wat::core::f64)
  (:wat::core::let*
    (((highest :wat::core::f64)
      (:wat::core::match
        (:trading::encoding::RingBuffer::max high-buf) -> :wat::core::f64
        ((Some v) v)
        (:None 0.0)))
     ((lowest :wat::core::f64)
      (:wat::core::match
        (:trading::encoding::RingBuffer::min low-buf) -> :wat::core::f64
        ((Some v) v)
        (:None 0.0)))
     ((range :wat::core::f64) (:wat::core::- highest lowest)))
    (:wat::core::if (:wat::core::= range 0.0) -> :wat::core::f64
      0.5
      (:wat::core::/ (:wat::core::- close lowest) range))))
