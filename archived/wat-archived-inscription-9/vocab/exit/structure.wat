;; vocab/exit/structure.wat — trend consistency, ADX strength
;; Depends on: candle
;; ExitLens :structure uses this module.

(require primitives)
(require candle)

(define (encode-exit-structure-facts [c : Candle])
  : Vec<ThoughtAST>
  (list
    ;; Trend consistency at multiple horizons
    (Linear "trend-consistency-6" (:trend-consistency-6 c) 1.0)
    (Linear "trend-consistency-12" (:trend-consistency-12 c) 1.0)
    (Linear "trend-consistency-24" (:trend-consistency-24 c) 1.0)
    ;; ADX — trend strength
    (Linear "adx" (/ (:adx c) 100.0) 1.0)
    ;; DI spread — directional conviction
    (Linear "di-spread" (- (:plus-di c) (:minus-di c)) 100.0)
    ;; Hurst — trending vs mean-reverting
    (Linear "hurst" (:hurst c) 1.0)))
