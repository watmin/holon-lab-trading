;; ── vocab/market/oscillators.wat ─────────────────────────────────
;;
;; Oscillator positions as scalars. Pure function: candle in, ASTs out.
;; atoms: rsi, cci, mfi, williams-r, roc-1, roc-3, roc-6, roc-12
;; Depends on: candle.

(require candle)

(define (encode-oscillator-facts [c : Candle])
  : Vec<ThoughtAST>
  (list
    ;; RSI: [0, 1] — Wilder's formula. Naturally bounded.
    '(Linear "rsi" (:rsi c) 1.0)

    ;; CCI: unbounded but typically [-300, 300]. Normalize to [-1, 1]
    ;; by dividing by 300 and clamping. Linear with scale 300.
    '(Linear "cci" (/ (:cci c) 300.0) 1.0)

    ;; MFI: [0, 1] — money flow index. Same range as RSI.
    '(Linear "mfi" (/ (:mfi c) 100.0) 1.0)

    ;; Williams %R: [-1, 0] in raw form. Normalize to [0, 1].
    ;; Raw williams-r is [-100, 0], candle stores it as-is.
    '(Linear "williams-r" (/ (+ (:williams-r c) 100.0) 100.0) 1.0)

    ;; Rate of change: unbounded ratio. Log-encoded.
    '(Log "roc-1" (+ 1.0 (:roc-1 c)))
    '(Log "roc-3" (+ 1.0 (:roc-3 c)))
    '(Log "roc-6" (+ 1.0 (:roc-6 c)))
    '(Log "roc-12" (+ 1.0 (:roc-12 c)))))
