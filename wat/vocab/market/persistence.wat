;; vocab/market/persistence.wat — Hurst, autocorrelation, ADX
;; Depends on: candle.wat
;; Domain: market — direction signal
;; Lens: :regime

(require primitives)
(require candle)

(define (encode-persistence-facts [c : Candle])
  : Vec<ThoughtAST>
  (let ((hurst (:hurst c))
        (autocorr (:autocorrelation c))
        (adx-norm (/ (:adx c) 100.0)))
    (list
      ;; Hurst exponent — [0, 1]. 0.5 = random walk.
      ;; >0.5 trending, <0.5 mean-reverting
      (Linear "hurst" hurst 1.0)

      ;; Lag-1 autocorrelation — signed, [-1, 1]
      (Linear "autocorrelation" autocorr 1.0)

      ;; ADX — trend strength [0, 100], normalized
      (Linear "adx" adx-norm 1.0))))
