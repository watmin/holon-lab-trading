;; vocab/exit/timing.wat — momentum state, reversal signals
;; Depends on: candle
;; ExitLens :timing uses this.

(require primitives)
(require candle)

;; Timing facts — momentum and reversal context for distance selection.
;; Exhaustion signals → tighter take-profit. Strong momentum → wider trail.
(define (encode-exit-timing-facts [c : Candle])
  : Vec<ThoughtAST>
  (let ((rsi-normalized (/ (:rsi c) 100.0)))
    (list
      ;; RSI — momentum state for timing
      (Linear "exit-rsi" rsi-normalized 1.0)
      ;; Stochastic %K — where in the recent range
      (Linear "exit-stoch-k" (/ (:stoch-k c) 100.0) 1.0)
      ;; MACD histogram — momentum acceleration
      (Linear "exit-macd-hist" (:macd-hist c) 100.0)
      ;; ROC at multiple timeframes — speed of price change
      (Linear "exit-roc-1" (:roc-1 c) 0.1)
      (Linear "exit-roc-6" (:roc-6 c) 0.1)
      ;; Stochastic cross delta — rate of momentum change
      (Linear "exit-stoch-cross-delta" (:stoch-cross-delta c) 1.0)
      ;; Range position — where in the recent range, relevant for timing
      (Linear "exit-range-pos-12" (:range-pos-12 c) 1.0))))
