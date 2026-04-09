;; vocab/exit/volatility.wat — ATR regime, ATR ratio, squeeze state
;; Depends on: candle
;; ExitLens :volatility uses this.

(require primitives)
(require candle)

;; Volatility facts — conditions that affect distance selection.
;; Exit observers compose these with the market thought.
(define (encode-exit-volatility-facts [c : Candle])
  : Vec<ThoughtAST>
  (list
    ;; ATR ratio — volatility relative to price. Log: ratios compress.
    (Log "atr-ratio" (max 0.001 (:atr-r c)))
    ;; ATR rate of change — how volatility is changing
    (Linear "atr-roc-6" (:atr-roc-6 c) 1.0)
    (Linear "atr-roc-12" (:atr-roc-12 c) 1.0)
    ;; Squeeze — BB width / Keltner width. Low = compressed volatility.
    (Log "squeeze" (max 0.001 (:squeeze c)))
    ;; Bollinger width — raw volatility measure
    (Log "bb-width" (max 0.001 (:bb-width c)))
    ;; ATR absolute — the raw measure
    (Log "atr" (max 0.001 (:atr c)))))
