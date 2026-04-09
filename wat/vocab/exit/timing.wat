;; vocab/exit/timing.wat — momentum state, reversal signals
;; Depends on: candle.wat
;; Domain: exit — distance signal
;; Lens: :timing

(require primitives)
(require candle)

(define (encode-exit-timing-facts [c : Candle])
  : Vec<ThoughtAST>
  (let ((rsi-norm (/ (:rsi c) 100.0))
        (stoch-k-norm (/ (:stoch-k c) 100.0))
        (macd-hist (:macd-hist c))
        (close (:close c))
        (roc-1 (:roc-1 c))
        (roc-3 (:roc-3 c))
        (consec-up (:consecutive-up c))
        (consec-down (:consecutive-down c)))
    (list
      ;; RSI for exit timing — extreme values signal reversal risk
      (Linear "exit-rsi" rsi-norm 1.0)

      ;; Stochastic for exit timing
      (Linear "exit-stoch-k" stoch-k-norm 1.0)

      ;; MACD histogram — momentum direction and magnitude
      (Linear "exit-macd-hist" (/ macd-hist (max close 1.0)) 0.01)

      ;; Short-term momentum — is the move exhausting?
      (Linear "exit-roc-1" roc-1 0.05)
      (Linear "exit-roc-3" roc-3 0.1)

      ;; Consecutive runs — extended runs signal reversal risk
      (Linear "exit-consec-up" (min consec-up 10.0) 10.0)
      (Linear "exit-consec-down" (min consec-down 10.0) 10.0))))
