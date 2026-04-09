;; vocab/exit/structure.wat — trend consistency, ADX strength
;; Depends on: candle
;; ExitLens :structure selects this module.

(require primitives)
(require candle)

(define (encode-exit-structure-facts [c : Candle])
  : Vec<ThoughtAST>
  (list
    ;; Trend consistency at multiple horizons — [0, 1]
    (Linear "exit-trend-6" (:trend-consistency-6 c) 1.0)
    (Linear "exit-trend-12" (:trend-consistency-12 c) 1.0)
    (Linear "exit-trend-24" (:trend-consistency-24 c) 1.0)

    ;; ADX strength — [0, 100] normalized
    (Linear "exit-adx" (/ (:adx c) 100.0) 1.0)

    ;; Hurst — trending vs mean-reverting
    (Linear "exit-hurst" (:hurst c) 1.0)

    ;; Choppiness — [0, 100] normalized
    (Linear "exit-choppiness" (/ (:choppiness c) 100.0) 1.0)))
