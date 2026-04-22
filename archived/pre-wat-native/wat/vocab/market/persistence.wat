;; ── vocab/market/persistence.wat ─────────────────────────────────
;;
;; Memory in the series. Pure function: candle in, ASTs out.
;; atoms: hurst, autocorrelation, adx
;; Depends on: candle.

(require candle)

(define (encode-persistence-facts [c : Candle])
  : Vec<ThoughtAST>
  (list
    ;; Hurst exponent: [0, 1]. 0.5 = random walk. >0.5 = trending. <0.5 = mean-reverting.
    '(Linear "hurst" (:hurst c) 1.0)

    ;; Autocorrelation: [-1, 1]. Signed. How much the series remembers itself.
    '(Linear "autocorrelation" (:autocorrelation c) 1.0)

    ;; ADX: [0, 100]. Trend strength (direction-agnostic). Normalize to [0, 1].
    '(Linear "adx" (/ (:adx c) 100.0) 1.0)))
