;; vocab/market/oscillators.wat — Williams %R, StochRSI, UltOsc, multi-ROC, RSI.
;;
;; Depends on: Candle, ThoughtAST.
;;
;; Pure: candle in, ASTs out. No state. No zones. Only scalars.
;; RSI lives here — the oscillator family.
;; ROC preserves sign (no signum split).

(require primitives)
(require candle)
(require enums)     ; ThoughtAST

;; ── encode-oscillator-facts ─────────────────────────────────────────────

(define (encode-oscillator-facts [c : Candle])
  : Vec<ThoughtAST>
  (list
    ;; RSI — [0, 1] naturally bounded
    (Linear "rsi" (:rsi c) 1.0)

    ;; Williams %R — [-1, 0] normalized to [-1, 1]
    ;; williams-r is in [-100, 0], normalize to [-1, 1]
    (Linear "williams-r" (/ (:williams-r c) 50.0) 2.0)

    ;; Rate of Change — signed, preserves direction and magnitude
    ;; ROC is already a fraction (e.g. 0.02 = 2%)
    (Linear "roc-1"  (:roc-1 c)  0.1)
    (Linear "roc-3"  (:roc-3 c)  0.1)
    (Linear "roc-6"  (:roc-6 c)  0.1)
    (Linear "roc-12" (:roc-12 c) 0.1)

    ;; MACD histogram — signed, unbounded, use scale for typical range
    (Linear "macd-hist" (:macd-hist c) 0.01)))
