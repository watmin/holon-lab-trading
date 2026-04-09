;; vocab/market/oscillators.wat — Williams %R, RSI, CCI, MFI, multi-ROC
;; Depends on: candle
;; MarketLens :momentum uses this.

(require primitives)
(require candle)

;; Oscillator facts — each value is a signed scalar, not a zone.
;; The reckoner learns where the boundaries are.
(define (encode-oscillator-facts [c : Candle])
  : Vec<ThoughtAST>
  (let ((rsi-normalized (/ (:rsi c) 100.0))
        (williams-normalized (/ (+ (:williams-r c) 100.0) 100.0))
        (cci-scale 200.0)
        (mfi-normalized (/ (:mfi c) 100.0)))
    (list
      ;; RSI — [0, 1] after normalization from [0, 100]
      (Linear "rsi" rsi-normalized 1.0)
      ;; Williams %R — normalized to [0, 1] from [-100, 0]
      (Linear "williams-r" williams-normalized 1.0)
      ;; CCI — unbounded, use scale
      (Linear "cci" (:cci c) cci-scale)
      ;; MFI — [0, 1] after normalization from [0, 100]
      (Linear "mfi" mfi-normalized 1.0)
      ;; Multi-ROC — rate of change at different lookbacks
      ;; Unbounded signed values. Scale 0.1 = 10% as full range.
      (Linear "roc-1" (:roc-1 c) 0.1)
      (Linear "roc-3" (:roc-3 c) 0.1)
      (Linear "roc-6" (:roc-6 c) 0.1)
      (Linear "roc-12" (:roc-12 c) 0.1))))
