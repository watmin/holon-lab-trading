;; vocab/market/persistence.wat — Hurst, autocorrelation, ADX
;; Depends on: candle
;; MarketLens :regime uses this.

(require primitives)
(require candle)

;; Persistence facts — how the market remembers its own past.
(define (encode-persistence-facts [c : Candle])
  : Vec<ThoughtAST>
  (let ((adx-normalized (/ (:adx c) 100.0)))
    (list
      ;; Hurst exponent — >0.5 trending, <0.5 mean-reverting, 0.5 random
      (Linear "hurst" (:hurst c) 1.0)
      ;; Autocorrelation — lag-1, signed. [-1, 1].
      (Linear "autocorrelation" (:autocorrelation c) 1.0)
      ;; ADX — trend strength [0, 100], normalized
      (Linear "adx" adx-normalized 1.0))))
