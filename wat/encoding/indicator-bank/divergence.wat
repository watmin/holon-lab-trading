;; wat/encoding/indicator-bank/divergence.wat — RSI divergence + cross
;; deltas.
;;
;; Lab arc 026 slice 11 (2026-04-25). Direct port of archive's
;; detect_divergence (line 1094-1128) + stoch-cross-delta inline at
;; the IndicatorBank's step.
;;
;; ── detect-divergence ──
;; Splits parallel price + RSI buffers in half; checks for:
;;   bull: price lower-low + RSI higher-low → spread magnitude
;;   bear: price higher-high + RSI lower-high → spread magnitude
;; Returns 0 if not divergent.
;;
;; Signature returns a tuple (bull, bear) — wat-tier idiom for
;; multi-value returns.
;;
;; ── stoch-cross-delta ──
;; Tracked at the IndicatorBank level (prev_stoch_kd) like the
;; Ichimoku tk-cross-delta. The free function takes the current
;; stoch K-D spread and the previous spread, returns the delta.
;; Caller (slice 12) maintains prev-stoch-kd as a bank field.
;;
;; Explicit:
;;   :trading::encoding::detect-divergence
;;     :Vec<f64> :Vec<f64> -> :(f64,f64)
;;   :trading::encoding::compute-stoch-cross-delta
;;     :wat::core::f64 :wat::core::f64 -> :wat::core::f64

(:wat::load-file! "primitives.wat")


;; ─── detect-divergence ────────────────────────────────────────────

(:wat::core::define
  (:trading::encoding::detect-divergence
    (prices :Vec<f64>)
    (rsis :Vec<f64>)
    -> :(f64,f64))
  (:wat::core::let*
    (((p-len :wat::core::i64) (:wat::core::length prices))
     ((r-len :wat::core::i64) (:wat::core::length rsis))
     ((n :wat::core::i64)
      (:wat::core::if (:wat::core::< p-len r-len) -> :wat::core::i64 p-len r-len)))
    (:wat::core::if (:wat::core::< n 5) -> :(f64,f64)
      (:wat::core::tuple 0.0 0.0)
      (:wat::core::let*
        (((half :wat::core::i64) (:wat::core::/ n 2))
         ((first-prices :Vec<f64>) (:wat::core::take prices half))
         ((second-prices :Vec<f64>)
          (:wat::core::take (:wat::core::drop prices half) (:wat::core::- n half)))
         ((first-rsis :Vec<f64>) (:wat::core::take rsis half))
         ((second-rsis :Vec<f64>)
          (:wat::core::take (:wat::core::drop rsis half) (:wat::core::- n half)))
         ;; min/max return Option; n>=5 means each half non-empty.
         ((p-low-1 :wat::core::f64)
          (:wat::core::match (:wat::core::f64::min-of first-prices) -> :wat::core::f64
            ((Some v) v) (:None 0.0)))
         ((p-low-2 :wat::core::f64)
          (:wat::core::match (:wat::core::f64::min-of second-prices) -> :wat::core::f64
            ((Some v) v) (:None 0.0)))
         ((rsi-low-1 :wat::core::f64)
          (:wat::core::match (:wat::core::f64::min-of first-rsis) -> :wat::core::f64
            ((Some v) v) (:None 0.0)))
         ((rsi-low-2 :wat::core::f64)
          (:wat::core::match (:wat::core::f64::min-of second-rsis) -> :wat::core::f64
            ((Some v) v) (:None 0.0)))
         ((p-high-1 :wat::core::f64)
          (:wat::core::match (:wat::core::f64::max-of first-prices) -> :wat::core::f64
            ((Some v) v) (:None 0.0)))
         ((p-high-2 :wat::core::f64)
          (:wat::core::match (:wat::core::f64::max-of second-prices) -> :wat::core::f64
            ((Some v) v) (:None 0.0)))
         ((rsi-high-1 :wat::core::f64)
          (:wat::core::match (:wat::core::f64::max-of first-rsis) -> :wat::core::f64
            ((Some v) v) (:None 0.0)))
         ((rsi-high-2 :wat::core::f64)
          (:wat::core::match (:wat::core::f64::max-of second-rsis) -> :wat::core::f64
            ((Some v) v) (:None 0.0)))
         ;; Bull: price lower low + RSI higher low.
         ((bull :wat::core::f64)
          (:wat::core::if (:wat::core::and
                            (:wat::core::< p-low-2 p-low-1)
                            (:wat::core::> rsi-low-2 rsi-low-1)) -> :wat::core::f64
            (:wat::core::f64::abs
              (:wat::core::-
                (:wat::core::- p-low-2 p-low-1)
                (:wat::core::- rsi-low-2 rsi-low-1)))
            0.0))
         ;; Bear: price higher high + RSI lower high.
         ((bear :wat::core::f64)
          (:wat::core::if (:wat::core::and
                            (:wat::core::> p-high-2 p-high-1)
                            (:wat::core::< rsi-high-2 rsi-high-1)) -> :wat::core::f64
            (:wat::core::f64::abs
              (:wat::core::-
                (:wat::core::- p-high-2 p-high-1)
                (:wat::core::- rsi-high-2 rsi-high-1)))
            0.0)))
        (:wat::core::tuple bull bear)))))


;; ─── stoch-cross-delta ────────────────────────────────────────────
;;
;; current K-D spread minus previous K-D spread. Mirror shape of
;; ichimoku's tk-cross-delta (which captures spread momentum across
;; ticks). Slice 12 maintains prev-stoch-kd on the IndicatorBank.
(:wat::core::define
  (:trading::encoding::compute-stoch-cross-delta
    (current-kd :wat::core::f64)
    (prev-kd :wat::core::f64)
    -> :wat::core::f64)
  (:wat::core::- current-kd prev-kd))
