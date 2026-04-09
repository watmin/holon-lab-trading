;; vocab/market/oscillators.wat — Williams %R, RSI, CCI, MFI, multi-ROC
;; Depends on: candle.wat
;; Domain: market — direction signal
;; Lens: :momentum

(require primitives)
(require candle)

(define (encode-oscillator-facts [c : Candle])
  : Vec<ThoughtAST>
  (let ((rsi-norm (/ (:rsi c) 100.0))
        (williams-norm (/ (+ (:williams-r c) 100.0) 200.0))
        (cci-norm (/ (:cci c) 400.0))
        (mfi-norm (/ (:mfi c) 100.0)))
    (list
      ;; RSI — [0, 100] normalized to [0, 1]
      (Linear "rsi" rsi-norm 1.0)

      ;; Williams %R — [-100, 0] normalized to [0, 1]
      (Linear "williams-r" williams-norm 1.0)

      ;; CCI — unbounded, normalized by typical range
      (Linear "cci" cci-norm 1.0)

      ;; MFI — [0, 100] normalized to [0, 1]
      (Linear "mfi" mfi-norm 1.0)

      ;; Multi-period rate of change — signed, unbounded → log
      (Log "roc-1" (+ 1.0 (:roc-1 c)))
      (Log "roc-3" (+ 1.0 (:roc-3 c)))
      (Log "roc-6" (+ 1.0 (:roc-6 c)))
      (Log "roc-12" (+ 1.0 (:roc-12 c))))))
