;; vocab/exit/structure.wat — trend consistency, ADX strength.
;;
;; Depends on: Candle, ThoughtAST.
;;
;; Pure: candle in, ASTs out. No state.
;; Exit vocab — structural conditions that affect stop distances.
;; Strong trends warrant wider stops. Choppy markets warrant tighter ones.

(require primitives)
(require candle)
(require enums)     ; ThoughtAST

;; ── encode-exit-structure-facts ─────────────────────────────────────────

(define (encode-exit-structure-facts [c : Candle])
  : Vec<ThoughtAST>
  (list
    ;; Trend consistency at multiple scales — [-1, 1]
    ;; Positive = consistently up, negative = consistently down
    (Linear "exit-trend-6" (:trend-consistency-6 c) 1.0)
    (Linear "exit-trend-12" (:trend-consistency-12 c) 1.0)
    (Linear "exit-trend-24" (:trend-consistency-24 c) 1.0)

    ;; ADX — trend strength [0, 1]. Strong trend = wider stops.
    (Linear "exit-adx" (/ (:adx c) 100.0) 1.0)

    ;; Hurst — persistent vs mean-reverting affects stop distances
    (Linear "exit-hurst" (:hurst c) 1.0)))
