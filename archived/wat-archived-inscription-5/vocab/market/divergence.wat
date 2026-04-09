;; vocab/market/divergence.wat — RSI divergence via PELT structural peaks
;; Depends on: candle
;; MarketLens :narrative selects this module.

(require primitives)
(require candle)

;; Divergence facts — when price and oscillator disagree.
;; Bullish: price makes lower low, RSI makes higher low — hidden strength.
;; Bearish: price makes higher high, RSI makes lower high — hidden weakness.
;; Magnitude = absolute difference in slopes. 0.0 = no divergence.
(define (encode-divergence-facts [c : Candle])
  : Vec<ThoughtAST>
  (list
    ;; Bullish divergence magnitude — 0.0 when absent
    (Linear "divergence-bull" (:rsi-divergence-bull c) 1.0)

    ;; Bearish divergence magnitude — 0.0 when absent
    (Linear "divergence-bear" (:rsi-divergence-bear c) 1.0)

    ;; Divergence spread — bullish minus bearish. Signed.
    ;; Positive = bullish pressure dominates.
    (Linear "divergence-spread"
      (- (:rsi-divergence-bull c) (:rsi-divergence-bear c))
      1.0)))
