;; timeframe.wat — multi-timeframe structure and agreement
;;
;; Depends on: candle (reads: tf-1h-ret, tf-1h-body, tf-4h-ret, tf-4h-body,
;;                            tf-agreement)
;; Market domain. Lens: :narrative, :generalist.
;;
;; 1h/4h returns, body ratios, and inter-timeframe agreement score.

(require primitives)

(define (encode-timeframe-facts [candle : Candle]) : Vec<ThoughtAST>
  (list
    ;; 1h return — signed
    (Linear "tf-1h-ret"  (:tf-1h-ret candle)  0.1)
    ;; 1h body ratio — [0, 1]
    (Linear "tf-1h-body" (:tf-1h-body candle) 1.0)

    ;; 4h return — signed
    (Linear "tf-4h-ret"  (:tf-4h-ret candle)  0.1)
    ;; 4h body ratio — [0, 1]
    (Linear "tf-4h-body" (:tf-4h-body candle) 1.0)

    ;; Inter-timeframe agreement — 5m/1h/4h direction alignment
    (Linear "tf-agreement" (:tf-agreement candle) 1.0)))
