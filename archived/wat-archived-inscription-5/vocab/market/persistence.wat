;; vocab/market/persistence.wat — Hurst, autocorrelation, ADX
;; Depends on: candle
;; MarketLens :regime selects this module.

(require primitives)
(require candle)

;; Persistence facts — how the market remembers or forgets.
;; Hurst > 0.5 = trending. Hurst < 0.5 = mean-reverting.
;; Autocorrelation: signed. Positive = momentum. Negative = reversal.
;; ADX: trend strength regardless of direction.
(define (encode-persistence-facts [c : Candle])
  : Vec<ThoughtAST>
  (list
    ;; Hurst exponent — [0, 1] in theory, typically [0.3, 0.7]
    (Linear "hurst" (:hurst c) 1.0)

    ;; Autocorrelation — lag-1, signed [-1, 1]
    (Linear "autocorrelation" (:autocorrelation c) 1.0)

    ;; ADX — trend strength [0, 100] → normalize to [0, 1]
    (Linear "adx" (/ (:adx c) 100.0) 1.0)

    ;; Trend consistency at multiple windows — fraction [0, 1]
    (Linear "trend-consistency-6" (:trend-consistency-6 c) 1.0)
    (Linear "trend-consistency-12" (:trend-consistency-12 c) 1.0)
    (Linear "trend-consistency-24" (:trend-consistency-24 c) 1.0)))
