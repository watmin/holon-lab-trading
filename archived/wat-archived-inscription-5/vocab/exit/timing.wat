;; vocab/exit/timing.wat — momentum state, reversal signals
;; Depends on: candle
;; ExitLens :timing selects this module.

(require primitives)
(require candle)

;; Timing facts for exit observers.
;; "When should we exit?" depends on momentum exhaustion and reversal signals.
;; RSI extremes, stochastic crosses, MACD histogram direction — all tell
;; the exit observer whether the move is accelerating or decelerating.
(define (encode-exit-timing-facts [c : Candle])
  : Vec<ThoughtAST>
  (list
    ;; RSI — momentum state [0, 1]
    (Linear "exit-rsi" (/ (:rsi c) 100.0) 1.0)

    ;; Stochastic %K — where in the recent range [0, 1]
    (Linear "exit-stoch-k" (/ (:stoch-k c) 100.0) 1.0)

    ;; Stochastic cross delta — momentum of momentum
    (Linear "exit-stoch-cross-delta" (:stoch-cross-delta c) 0.1)

    ;; MACD histogram — direction and magnitude of momentum
    (Linear "exit-macd-hist" (:macd-hist c) 0.01)

    ;; ROC-1 — immediate momentum. Signed.
    (Linear "exit-roc-1" (:roc-1 c) 0.1)

    ;; ROC-6 — medium-term momentum. Signed.
    (Linear "exit-roc-6" (:roc-6 c) 0.1)

    ;; Williams %R — reversal indicator [-1, 0]
    (Linear "exit-williams-r" (/ (:williams-r c) 100.0) 1.0)))
