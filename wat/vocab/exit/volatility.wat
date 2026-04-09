;; exit/volatility.wat — ATR regime, volatility ratios, squeeze state
;;
;; Depends on: candle (reads: atr, atr-r, atr-roc-6, atr-roc-12,
;;                            bb-width, squeeze, kelt-upper, kelt-lower)
;; Exit domain. Lens: :volatility, :generalist.
;;
;; Warmup guard on Keltner values — skip when kelt-upper = 0.
;; rune:sever(overlap) for exit-bb-width — regime.wat has regime-bb-width.
;; Exit prefix on all atoms.

(require primitives)

(define (encode-exit-volatility-facts [candle : Candle]) : Vec<ThoughtAST>
  (let ((base-facts
          (list
            ;; ATR relative to price — unbounded positive ratio
            (Log "exit-atr-r" (:atr-r candle))

            ;; ATR rate of change — how is volatility changing?
            (Linear "exit-atr-roc-6"  (:atr-roc-6 candle)  0.5)
            (Linear "exit-atr-roc-12" (:atr-roc-12 candle) 0.5)

            ;; Bollinger width — unbounded positive
            ;; rune:sever(overlap) — regime.wat has regime-bb-width, this is exit-bb-width
            (Log "exit-bb-width" (:bb-width candle))

            ;; Squeeze ratio — bb-width / kelt-width, continuous
            (Log "exit-squeeze" (:squeeze candle)))))

    ;; Warmup guard: Keltner values are zero before the indicator bank warms up
    (if (> (:kelt-upper candle) 0.0)
      (let ((kelt-width (- (:kelt-upper candle) (:kelt-lower candle)))
            (close (:close candle)))
        (append base-facts
          (list
            ;; Keltner width relative to price
            (Log "exit-kelt-width" (/ kelt-width close)))))
      base-facts)))
