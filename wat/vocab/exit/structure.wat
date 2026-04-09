;; vocab/exit/structure.wat — trend consistency, ADX strength
;; Depends on: candle
;; ExitLens :structure uses this.

(require primitives)
(require candle)

;; Structure facts — trend quality for distance selection.
;; Strong trends → tighter stops, weaker trends → wider stops.
(define (encode-exit-structure-facts [c : Candle])
  : Vec<ThoughtAST>
  (let ((adx-normalized (/ (:adx c) 100.0)))
    (list
      ;; ADX — trend strength. [0, 1].
      (Linear "exit-adx" adx-normalized 1.0)
      ;; Trend consistency at multiple timeframes
      (Linear "exit-trend-6" (:trend-consistency-6 c) 1.0)
      (Linear "exit-trend-12" (:trend-consistency-12 c) 1.0)
      (Linear "exit-trend-24" (:trend-consistency-24 c) 1.0)
      ;; DI spread — direction strength for the trend
      (Linear "exit-di-spread" (/ (- (:plus-di c) (:minus-di c)) 100.0) 1.0)
      ;; Hurst — trending vs mean-reverting context for distance
      (Linear "exit-hurst" (:hurst c) 1.0))))
