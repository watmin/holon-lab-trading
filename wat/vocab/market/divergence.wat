;; vocab/market/divergence.wat — RSI divergence via PELT structural peaks
;; Depends on: candle
;; MarketLens :narrative uses this.

(require primitives)
(require candle)

;; Divergence facts — when price and indicators disagree.
;; Bullish: price lower low, RSI higher low — magnitude of RSI difference.
;; Bearish: price higher high, RSI lower high — magnitude of RSI difference.
(define (encode-divergence-facts [c : Candle])
  : Vec<ThoughtAST>
  (let ((facts '()))
    ;; Bullish divergence — emit only when present
    (when (> (:rsi-divergence-bull c) 0.0)
      (set! facts (append facts
        (list (Linear "rsi-divergence-bull" (:rsi-divergence-bull c) 1.0)))))
    ;; Bearish divergence — emit only when present
    (when (> (:rsi-divergence-bear c) 0.0)
      (set! facts (append facts
        (list (Linear "rsi-divergence-bear" (:rsi-divergence-bear c) 1.0)))))
    facts))
