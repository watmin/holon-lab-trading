;; vocab/market/persistence.wat — Hurst, autocorrelation, ADX
;; Depends on: candle
;; MarketLens :regime uses this module.

(require primitives)
(require candle)

(define (encode-persistence-facts [c : Candle])
  : Vec<ThoughtAST>
  (list
    ;; Hurst exponent — >0.5 trending, <0.5 mean-reverting
    (Linear "hurst" (:hurst c) 1.0)
    ;; Autocorrelation — lag-1, signed
    (Linear "autocorrelation" (:autocorrelation c) 1.0)
    ;; ADX — trend strength [0, 100] normalized
    (Linear "adx" (/ (:adx c) 100.0) 1.0)))
