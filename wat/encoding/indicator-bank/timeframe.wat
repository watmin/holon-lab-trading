;; wat/encoding/indicator-bank/timeframe.wat — Multi-timeframe.
;;
;; Lab arc 026 slice 7 (2026-04-25). Direct port of
;; archived/pre-wat-native/src/domain/indicator_bank.rs:1158-1210.
;;
;; Pure compute functions over RingBuffers held by the IndicatorBank
;; (slice 12). 5-minute candles aggregated to 1-hour and 4-hour
;; windows: tf-1h needs a 12-period buffer; tf-4h needs a 48-period
;; buffer.
;;
;; tf-ret: (newest - oldest) / oldest.
;; tf-body: |close - open| / (high - low). Open=oldest, close=newest,
;;          high/low from max/min of the buffer.
;; tf-agreement: pairwise products of signs across (5m, 1h, 4h) returns,
;;               averaged. Range [-1, +1].
;;
;; Explicit:
;;   :trading::encoding::compute-tf-ret  buf -> :f64
;;   :trading::encoding::compute-tf-body buf -> :f64
;;   :trading::encoding::compute-tf-agreement
;;     prev-close close tf-1h-buf tf-4h-buf -> :f64

(:wat::load-file! "primitives.wat")


;; signum helper — returns -1.0, 0.0, or +1.0 based on sign.
(:wat::core::define
  (:trading::encoding::signum
    (x :f64)
    -> :f64)
  (:wat::core::if (:wat::core::> x 0.0) -> :f64
    1.0
    (:wat::core::if (:wat::core::< x 0.0) -> :f64
      -1.0
      0.0)))


;; tf-ret — return over a RingBuffer (newest - oldest) / oldest.
(:wat::core::define
  (:trading::encoding::compute-tf-ret
    (buf :trading::encoding::RingBuffer)
    -> :f64)
  (:wat::core::let*
    (((len :i64) (:trading::encoding::RingBuffer::len buf)))
    (:wat::core::if (:wat::core::< len 2) -> :f64
      0.0
      (:wat::core::let*
        (((newest :f64)
          (:wat::core::match
            (:trading::encoding::RingBuffer::get buf 0) -> :f64
            ((Some v) v) (:None 0.0)))
         ((oldest :f64)
          (:wat::core::match
            (:trading::encoding::RingBuffer::get buf (:wat::core::- len 1)) -> :f64
            ((Some v) v) (:None 0.0))))
        (:wat::core::if (:wat::core::= oldest 0.0) -> :f64
          0.0
          (:wat::core::/ (:wat::core::- newest oldest) oldest))))))


;; tf-body — |close - open| / (high - low).
(:wat::core::define
  (:trading::encoding::compute-tf-body
    (buf :trading::encoding::RingBuffer)
    -> :f64)
  (:wat::core::let*
    (((len :i64) (:trading::encoding::RingBuffer::len buf)))
    (:wat::core::if (:wat::core::< len 2) -> :f64
      0.0
      (:wat::core::let*
        (((open-val :f64)
          (:wat::core::match
            (:trading::encoding::RingBuffer::get buf (:wat::core::- len 1)) -> :f64
            ((Some v) v) (:None 0.0)))
         ((close-val :f64)
          (:wat::core::match
            (:trading::encoding::RingBuffer::get buf 0) -> :f64
            ((Some v) v) (:None 0.0)))
         ((high-val :f64)
          (:wat::core::match
            (:trading::encoding::RingBuffer::max buf) -> :f64
            ((Some v) v) (:None 0.0)))
         ((low-val :f64)
          (:wat::core::match
            (:trading::encoding::RingBuffer::min buf) -> :f64
            ((Some v) v) (:None 0.0)))
         ((range :f64) (:wat::core::- high-val low-val)))
        (:wat::core::if (:wat::core::= range 0.0) -> :f64
          0.0
          (:wat::core::/
            (:wat::core::f64::abs (:wat::core::- close-val open-val))
            range))))))


;; tf-agreement — pairwise sign products across (5m, 1h, 4h) returns,
;; averaged. Range [-1, +1] where +1 means all three timeframes agree
;; on direction; -1 means total disagreement.
(:wat::core::define
  (:trading::encoding::compute-tf-agreement
    (prev-close :f64)
    (close :f64)
    (tf-1h-buf :trading::encoding::RingBuffer)
    (tf-4h-buf :trading::encoding::RingBuffer)
    -> :f64)
  (:wat::core::let*
    (((ret-5m :f64)
      (:wat::core::if (:wat::core::= prev-close 0.0) -> :f64
        0.0
        (:wat::core::/ (:wat::core::- close prev-close) prev-close)))
     ((ret-1h :f64) (:trading::encoding::compute-tf-ret tf-1h-buf))
     ((ret-4h :f64) (:trading::encoding::compute-tf-ret tf-4h-buf))
     ((s5 :f64) (:trading::encoding::signum ret-5m))
     ((s1 :f64) (:trading::encoding::signum ret-1h))
     ((s4 :f64) (:trading::encoding::signum ret-4h)))
    (:wat::core::/
      (:wat::core::+
        (:wat::core::* s5 s1)
        (:wat::core::+
          (:wat::core::* s5 s4)
          (:wat::core::* s1 s4)))
      3.0)))
