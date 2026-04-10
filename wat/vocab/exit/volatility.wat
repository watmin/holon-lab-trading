;; ── vocab/exit/volatility.wat ────────────────────────────────────
;;
;; ATR regime, ATR ratio, squeeze state. Exit observers use these
;; to estimate optimal distances. Pure function: candle in, ASTs out.
;; atoms: atr-ratio, atr-r, atr-roc-6, atr-roc-12, squeeze, bb-width
;; Depends on: candle.

(require candle)

(define (encode-exit-volatility-facts [c : Candle])
  : Vec<ThoughtAST>
  (list
    ;; ATR ratio: ATR / close. Unbounded positive. Log-encoded.
    '(Log "atr-ratio" (max 0.001 (:atr-r c)))

    ;; ATR raw: absolute average true range. Log-encoded.
    '(Log "atr-r" (max 0.001 (:atr c)))

    ;; ATR rate of change (6 period): signed. How fast volatility changes.
    '(Linear "atr-roc-6" (:atr-roc-6 c) 1.0)

    ;; ATR rate of change (12 period): signed. Longer-term vol trend.
    '(Linear "atr-roc-12" (:atr-roc-12 c) 1.0)

    ;; Squeeze: [0, 1] — Bollinger inside Keltner = compression.
    '(Linear "squeeze" (:squeeze c) 1.0)

    ;; Bollinger width: unbounded positive. Log-encoded.
    '(Log "bb-width" (max 0.001 (:bb-width c)))))
