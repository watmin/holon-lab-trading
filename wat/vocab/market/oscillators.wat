;; vocab/market/oscillators.wat — Williams %R, RSI, CCI, MFI, multi-ROC
;; Depends on: candle
;; MarketLens :momentum uses this module.

(require primitives)
(require candle)

(define (encode-oscillator-facts [c : Candle])
  : Vec<ThoughtAST>
  (list
    ;; RSI — [0, 1] from Wilder's formula
    (Linear "rsi" (:rsi c) 1.0)
    ;; Williams %R — [0, 1] normalized
    (Linear "williams-r" (:williams-r c) 1.0)
    ;; CCI — unbounded, use log for magnitude
    (Log "cci-magnitude" (+ 1.0 (abs (:cci c))))
    ;; CCI direction as linear
    (Linear "cci-direction" (signum (:cci c)) 1.0)
    ;; MFI — [0, 1]
    (Linear "mfi" (:mfi c) 1.0)
    ;; Multi-ROC — rate of change at different horizons
    (Linear "roc-1" (:roc-1 c) 0.1)
    (Linear "roc-3" (:roc-3 c) 0.1)
    (Linear "roc-6" (:roc-6 c) 0.1)
    (Linear "roc-12" (:roc-12 c) 0.1)))
