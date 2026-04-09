;; vocab/market/price-action.wat — range-ratio, gaps, consecutive runs
;; Depends on: candle
;; MarketLens :structure uses this.

(require primitives)
(require candle)

;; Price action facts — raw bar structure and sequences.
(define (encode-price-action-facts [c : Candle])
  : Vec<ThoughtAST>
  (list
    ;; Range ratio — current range / prev range. < 1 = compression, > 1 = expansion.
    (Log "range-ratio" (max 0.001 (:range-ratio c)))
    ;; Gap — signed. (open - prev-close) / prev-close.
    (Linear "gap" (:gap c) 0.05)
    ;; Consecutive runs — how many candles in a row in the same direction.
    ;; Emit whichever direction is active.
    (Linear "consecutive-up" (:consecutive-up c) 20.0)
    (Linear "consecutive-down" (:consecutive-down c) 20.0)
    ;; Range positions at multiple timeframes
    (Linear "range-pos-12" (:range-pos-12 c) 1.0)
    (Linear "range-pos-24" (:range-pos-24 c) 1.0)))
