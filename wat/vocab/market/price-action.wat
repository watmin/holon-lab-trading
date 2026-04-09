;; vocab/market/price-action.wat — range-ratio, gaps, consecutive runs
;; Depends on: candle
;; MarketLens :structure selects this module.

(require primitives)
(require candle)

(define (encode-price-action-facts [c : Candle])
  : Vec<ThoughtAST>
  (list
    ;; Range ratio — current range / prev range. Compression vs expansion.
    ;; Always positive — log compresses naturally
    (Log "range-ratio" (max (:range-ratio c) 0.001))

    ;; Gap — (open - prev close) / prev close. Signed.
    (Linear "gap" (:gap c) 0.02)

    ;; Consecutive runs — how many bullish/bearish closes in a row
    ;; Positive = up streak, zero = no streak
    (Linear "consecutive-up" (:consecutive-up c) 10.0)
    (Linear "consecutive-down" (:consecutive-down c) 10.0)

    ;; Range positions at different horizons
    (Linear "range-pos-12" (:range-pos-12 c) 1.0)
    (Linear "range-pos-24" (:range-pos-24 c) 1.0)))
