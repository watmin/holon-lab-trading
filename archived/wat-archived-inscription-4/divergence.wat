;; divergence.wat — RSI divergence via PELT structural peaks
;;
;; Depends on: candle (reads: rsi-divergence-bull, rsi-divergence-bear)
;; Market domain. Lens: :narrative, :generalist.
;;
;; Bullish divergence: price makes lower low, RSI makes higher low.
;; Bearish divergence: price makes higher high, RSI makes lower high.
;; Both magnitudes are unbounded positive (how far price and RSI disagree).

(require primitives)

(define (encode-divergence-facts [candle : Candle]) : Vec<ThoughtAST>
  (list
    ;; Bullish divergence magnitude — unbounded positive
    (Log "rsi-div-bull" (:rsi-divergence-bull candle))

    ;; Bearish divergence magnitude — unbounded positive
    (Log "rsi-div-bear" (:rsi-divergence-bear candle))))
