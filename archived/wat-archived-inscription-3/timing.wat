;; vocab/exit/timing.wat — momentum state, reversal signals.
;;
;; Depends on: Candle, ThoughtAST.
;;
;; Pure: candle in, ASTs out. No state.
;; Exit vocab — timing conditions that affect when to exit.
;; Momentum exhaustion, reversal signals, volume dynamics.

(require primitives)
(require candle)
(require enums)     ; ThoughtAST

;; ── encode-exit-timing-facts ────────────────────────────────────────────

(define (encode-exit-timing-facts [c : Candle])
  : Vec<ThoughtAST>
  (list
    ;; RSI — momentum state affects exit timing
    (Linear "exit-rsi" (:rsi c) 1.0)

    ;; MACD histogram — momentum direction and acceleration
    (Linear "exit-macd-hist" (:macd-hist c) 0.01)

    ;; ROC at multiple periods — signed momentum
    (Linear "exit-roc-1" (:roc-1 c) 0.1)
    (Linear "exit-roc-6" (:roc-6 c) 0.1)

    ;; Volume acceleration — surges often precede reversals
    (Log "exit-volume-accel" (:volume-accel c))

    ;; Stochastic cross delta — momentum change
    (Linear "exit-stoch-cross" (:stoch-cross-delta c) 0.01)))
