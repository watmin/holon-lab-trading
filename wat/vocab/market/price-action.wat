;; vocab/market/price-action.wat — range-ratio, gaps, consecutive runs
;; Depends on: candle
;; MarketLens :structure uses this module.

(require primitives)
(require candle)

(define (encode-price-action-facts [c : Candle])
  : Vec<ThoughtAST>
  (list
    ;; Range ratio: current range / prev range
    ;; < 1 = compression, > 1 = expansion
    (Log "range-ratio" (max 0.001 (:range-ratio c)))
    ;; Gap: signed — (open - prev close) / prev close
    (Linear "gap" (:gap c) 0.05)
    ;; Consecutive runs — how many in a row
    (Linear "consecutive-up" (:consecutive-up c) 10.0)
    (Linear "consecutive-down" (:consecutive-down c) 10.0)))
