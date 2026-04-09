;; vocab/exit/structure.wat — trend consistency, ADX strength
;; Depends on: candle
;; ExitLens :structure selects this module.

(require primitives)
(require candle)

;; Structure facts for exit observers.
;; "How far will price run?" depends on trend strength and consistency.
;; Strong trends: wider take-profit, tighter trailing stop.
;; Choppy markets: tighter everything.
(define (encode-exit-structure-facts [c : Candle])
  : Vec<ThoughtAST>
  (list
    ;; ADX — trend strength [0, 1]. Higher = stronger trend.
    (Linear "exit-adx" (/ (:adx c) 100.0) 1.0)

    ;; DI spread — signed. +DI minus -DI. Direction of the trend.
    (Linear "exit-di-spread"
      (/ (- (:plus-di c) (:minus-di c)) 100.0)
      1.0)

    ;; Trend consistency at multiple windows
    (Linear "exit-trend-consistency-6" (:trend-consistency-6 c) 1.0)
    (Linear "exit-trend-consistency-12" (:trend-consistency-12 c) 1.0)
    (Linear "exit-trend-consistency-24" (:trend-consistency-24 c) 1.0)

    ;; Hurst — trending vs mean-reverting. Affects how far to let trades run.
    (Linear "exit-hurst" (:hurst c) 1.0)

    ;; KAMA efficiency ratio — how clean is the trend?
    (Linear "exit-kama-er" (:kama-er c) 1.0)))
