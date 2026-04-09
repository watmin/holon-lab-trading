;; vocab/market/persistence.wat — Hurst, autocorrelation, ADX
;; Depends on: candle
;; MarketLens :regime selects this module.

(require primitives)
(require candle)

(define (encode-persistence-facts [c : Candle])
  : Vec<ThoughtAST>
  (list
    ;; Hurst exponent — [0, 1], 0.5 = random walk
    (Linear "hurst" (:hurst c) 1.0)

    ;; Autocorrelation — [-1, 1] lag-1
    (Linear "autocorrelation" (:autocorrelation c) 1.0)

    ;; ADX — [0, 100] normalized to [0, 1], trend strength
    (Linear "adx" (/ (:adx c) 100.0) 1.0)))
