;; vocab/exit/volatility.wat — ATR regime, ATR ratio, squeeze state.
;;
;; Depends on: Candle, ThoughtAST.
;;
;; Pure: candle in, ASTs out. No state.
;; Exit vocab — whether CONDITIONS favor trading. Distance signal.
;; ATR-relative facts for the exit observer's volatility lens.

(require primitives)
(require candle)
(require enums)     ; ThoughtAST

;; ── encode-exit-volatility-facts ────────────────────────────────────────

(define (encode-exit-volatility-facts [c : Candle])
  : Vec<ThoughtAST>
  (list
    ;; ATR ratio — atr / close. How volatile relative to price. Log scale.
    (Log "exit-atr-ratio" (:atr-r c))

    ;; ATR rate of change — is volatility expanding or contracting?
    (Linear "exit-atr-roc-6" (:atr-roc-6 c) 0.1)
    (Linear "exit-atr-roc-12" (:atr-roc-12 c) 0.1)

    ;; Squeeze state — bb-width / kelt-width. Lower = tighter squeeze.
    (Linear "exit-squeeze" (:squeeze c) 2.0)

    ;; Bollinger width — absolute volatility measure
    (Log "exit-bb-width" (:bb-width c))))
