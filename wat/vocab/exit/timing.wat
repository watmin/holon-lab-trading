;; vocab/exit/timing.wat — momentum state, reversal signals
;; Depends on: candle
;; ExitLens :timing selects this module.

(require primitives)
(require candle)

(define (encode-exit-timing-facts [c : Candle])
  : Vec<ThoughtAST>
  (list
    ;; RSI position — near extremes suggests reversal potential
    (Linear "exit-rsi" (/ (:rsi c) 100.0) 1.0)

    ;; Stochastic position — near extremes
    (Linear "exit-stoch-k" (/ (:stoch-k c) 100.0) 1.0)

    ;; MACD histogram — momentum direction and strength
    (Linear "exit-macd-hist" (:macd-hist c) 0.005)

    ;; ROC — short-term momentum
    (Linear "exit-roc-1" (:roc-1 c) 0.05)
    (Linear "exit-roc-3" (:roc-3 c) 0.05)

    ;; TK cross delta — ichimoku momentum signal
    (Linear "exit-tk-cross-delta" (:tk-cross-delta c) 0.01)

    ;; Stochastic cross delta — reversal signal
    (Linear "exit-stoch-cross-delta" (:stoch-cross-delta c) 0.1)))
