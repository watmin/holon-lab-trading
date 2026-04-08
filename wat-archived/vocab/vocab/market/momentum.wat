;; momentum.wat — CCI zones
;;
;; Depends on: candle
;; Domain: market (MarketLens :momentum)
;;
;; Commodity Channel Index: how far is the typical price from its
;; moving average, in units of mean deviation? Unbounded.
;; Positive = above average. Negative = below. Magnitude = extremity.

(require primitives)
(require enums)       ; ThoughtAST constructors
(require candle)

;; CCI — pre-computed on Candle. Unbounded but typically [-300, 300].
;; Normalized by dividing by 200 and clamping to [-1, 1].
;; Linear-encoded with scale 1.0 — the sign carries direction,
;; the magnitude carries extremity.
;;
;; Also emit MACD histogram — a momentum oscillator.
;; Signed, proportional to price. Normalized by close.

(define (encode-momentum-facts [candle : Candle])
  : Vec<ThoughtAST>
  (let* ((cci-norm (clamp (/ (:cci candle) 200.0) -1.0 1.0))
         (macd-hist-norm (/ (:macd-hist candle) (max (:close candle) 1.0))))
    (list
      (Linear "cci" cci-norm 1.0)
      (Linear "macd-hist" macd-hist-norm 0.01)
      (Linear "rsi" (/ (:rsi candle) 100.0) 1.0))))
