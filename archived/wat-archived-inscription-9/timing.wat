;; vocab/exit/timing.wat — momentum state, reversal signals
;; Depends on: candle
;; ExitLens :timing uses this module.

(require primitives)
(require candle)

(define (encode-exit-timing-facts [c : Candle])
  : Vec<ThoughtAST>
  (list
    ;; RSI — potential reversal zone
    (Linear "rsi" (:rsi c) 1.0)
    ;; Stochastic K-D spread — momentum cross signal
    (Linear "stoch-kd-spread" (- (:stoch-k c) (:stoch-d c)) 1.0)
    ;; Stochastic cross delta — is momentum shifting?
    (Linear "stoch-cross-delta" (:stoch-cross-delta c) 1.0)
    ;; MACD histogram — momentum direction
    (Linear "macd-hist" (:macd-hist c) 0.01)
    ;; Williams %R — overbought/oversold
    (Linear "williams-r" (:williams-r c) 1.0)
    ;; Multi-ROC — momentum at different horizons
    (Linear "roc-1" (:roc-1 c) 0.1)
    (Linear "roc-6" (:roc-6 c) 0.1)))
