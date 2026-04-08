;; timing.wat — momentum state, reversal signals
;;
;; Depends on: candle
;; Domain: exit (ExitLens :timing)
;;
;; When to tighten stops. Momentum exhaustion and reversal signals
;; affect optimal exit timing. Not direction — urgency.

(require primitives)
(require enums)       ; ThoughtAST constructors
(require candle)

;; RSI — pre-computed on Candle. Range [0, 100]. Normalized to [0, 1].
;; Extreme RSI suggests reversal pressure. The exit observer learns
;; whether extreme RSI means "tighten the trail."
;;
;; MACD histogram — signed momentum. When momentum is fading
;; (histogram shrinking toward zero), exits may need to tighten.
;; Normalized by close.
;;
;; Stochastic %K — pre-computed. Range [0, 100]. Normalized to [0, 1].
;; Extreme stochastic suggests overextension.
;;
;; ROC-1 — most recent per-candle rate of change. Signed.
;; Sharp moves in either direction affect exit urgency.

(define (encode-exit-timing-facts [candle : Candle])
  : Vec<ThoughtAST>
  (list
    (Linear "exit-rsi" (/ (:rsi candle) 100.0) 1.0)
    (Linear "exit-macd-hist"
      (/ (:macd-hist candle) (max (:close candle) 1.0)) 0.01)
    (Linear "exit-stoch-k" (/ (:stoch-k candle) 100.0) 1.0)
    (Linear "exit-roc-1" (:roc-1 candle) 0.1)))
