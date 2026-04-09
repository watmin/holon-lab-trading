;; exit/structure.wat — trend consistency and ADX strength for exit conditions
;;
;; Depends on: candle (reads: trend-consistency-6, trend-consistency-12,
;;                            trend-consistency-24, adx)
;; Exit domain. Lens: :structure, :generalist.
;;
;; Exit prefix on all atoms.

(require primitives)

(define (encode-exit-structure-facts [candle : Candle]) : Vec<ThoughtAST>
  (list
    ;; Trend consistency — [-1, 1]. Positive = consistent uptrend.
    (Linear "exit-trend-consistency-6"  (:trend-consistency-6 candle)  1.0)
    (Linear "exit-trend-consistency-12" (:trend-consistency-12 candle) 1.0)
    (Linear "exit-trend-consistency-24" (:trend-consistency-24 candle) 1.0)

    ;; ADX — [0, 100]. Trend strength for exit sizing.
    (Linear "exit-adx" (:adx candle) 100.0)))
