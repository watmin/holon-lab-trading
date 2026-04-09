;; vocab/market/divergence.wat — RSI divergence via PELT structural peaks.
;;
;; Depends on: Candle, ThoughtAST.
;;
;; Pure: candle in, ASTs out. No state.
;; Bullish divergence: price lower, RSI higher.
;; Bearish divergence: price higher, RSI lower.
;; Both magnitudes are pre-computed on the Candle by the IndicatorBank.

(require primitives)
(require candle)
(require enums)     ; ThoughtAST

;; ── encode-divergence-facts ─────────────────────────────────────────────

(define (encode-divergence-facts [c : Candle])
  : Vec<ThoughtAST>
  ;; Conditional — emit only when divergence is present.
  ;; Both are magnitudes >= 0. Zero means no divergence detected.
  (let ((facts (list)))
    (when (> (:rsi-divergence-bull c) 0.0)
      (push! facts (Linear "rsi-divergence-bull" (:rsi-divergence-bull c) 1.0)))
    (when (> (:rsi-divergence-bear c) 0.0)
      (push! facts (Linear "rsi-divergence-bear" (:rsi-divergence-bear c) 1.0)))
    facts))
