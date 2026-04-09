;; exit/timing.wat — momentum state and reversal signals for exit conditions
;;
;; Depends on: candle (reads: rsi, macd-hist, stoch-k, stoch-d,
;;                            rsi-divergence-bull, rsi-divergence-bear)
;; Exit domain. Lens: :timing, :generalist.
;;
;; Exit prefix on all atoms.

(require primitives)

(define (encode-exit-timing-facts [candle : Candle]) : Vec<ThoughtAST>
  (list
    ;; RSI for exit timing — same indicator, different atom name
    (Linear "exit-rsi" (:rsi candle) 1.0)

    ;; MACD histogram — momentum direction and magnitude
    (Linear "exit-macd-hist" (:macd-hist candle) 0.01)

    ;; Stochastic for exit timing
    (Linear "exit-stoch-k" (:stoch-k candle) 1.0)
    (Linear "exit-stoch-d" (:stoch-d candle) 1.0)

    ;; Divergence signals — potential reversal indicators
    (Log "exit-rsi-div-bull" (:rsi-divergence-bull candle))
    (Log "exit-rsi-div-bear" (:rsi-divergence-bear candle))))
