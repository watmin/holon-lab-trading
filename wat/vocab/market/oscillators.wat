;; vocab/market/oscillators.wat — Williams %R, RSI, CCI, MFI, multi-ROC
;; Depends on: candle
;; MarketLens :momentum selects this module.

(require primitives)
(require candle)

(define (encode-oscillator-facts [c : Candle])
  : Vec<ThoughtAST>
  (list
    ;; RSI — [0, 100] normalized to [0, 1]
    (Linear "rsi" (/ (:rsi c) 100.0) 1.0)

    ;; Williams %R — [-100, 0] normalized to [-1, 0]
    (Linear "williams-r" (/ (:williams-r c) 100.0) 1.0)

    ;; CCI — unbounded, but typically [-200, 200], normalize by 200
    (Linear "cci" (/ (:cci c) 200.0) 1.0)

    ;; MFI — [0, 100] normalized to [0, 1]
    (Linear "mfi" (/ (:mfi c) 100.0) 1.0)

    ;; Multi-ROC — rates of change at different periods
    ;; Signed, unbounded — use linear with scale capturing typical range
    (Linear "roc-1" (:roc-1 c) 0.05)
    (Linear "roc-3" (:roc-3 c) 0.05)
    (Linear "roc-6" (:roc-6 c) 0.1)
    (Linear "roc-12" (:roc-12 c) 0.1)))
