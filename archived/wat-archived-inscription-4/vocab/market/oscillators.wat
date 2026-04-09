;; oscillators.wat — bounded oscillator facts
;;
;; Depends on: candle (reads: rsi, williams-r, stoch-k, stoch-d, cci, mfi,
;;                            roc-1, roc-3, roc-6, roc-12)
;; Market domain. Lens: :momentum, :generalist.
;;
;; RSI lives here. ROC preserves sign (encode-linear, no signum split).

(require primitives)

(define (encode-oscillator-facts [candle : Candle]) : Vec<ThoughtAST>
  (list
    ;; RSI — [0, 1] naturally bounded
    (Linear "rsi" (:rsi candle) 1.0)

    ;; Williams %R — [-1, 0] naturally bounded
    (Linear "williams-r" (:williams-r candle) 1.0)

    ;; Stochastic — [0, 1]
    (Linear "stoch-k" (:stoch-k candle) 1.0)
    (Linear "stoch-d" (:stoch-d candle) 1.0)

    ;; CCI — unbounded but centered around 0, use linear with wide scale
    (Linear "cci" (:cci candle) 400.0)

    ;; MFI — [0, 1] naturally bounded (like RSI but volume-weighted)
    (Linear "mfi" (:mfi candle) 1.0)

    ;; Rate of change — signed, preserves direction
    (Linear "roc-1"  (:roc-1 candle)  0.1)
    (Linear "roc-3"  (:roc-3 candle)  0.1)
    (Linear "roc-6"  (:roc-6 candle)  0.1)
    (Linear "roc-12" (:roc-12 candle) 0.1)))
