;; vocab/market/stochastic.wat — %K/%D values and crosses.
;;
;; Depends on: Candle, ThoughtAST.
;;
;; Pure: candle in, ASTs out. No state. No zones.
;; Stochastic %K and %D as continuous scalars.
;; Cross delta is the signed change of (%K - %D) from previous candle.

(require primitives)
(require candle)
(require enums)     ; ThoughtAST

;; ── encode-stochastic-facts ─────────────────────────────────────────────

(define (encode-stochastic-facts [c : Candle])
  : Vec<ThoughtAST>
  (list
    ;; %K — [0, 100] normalized to [0, 1]
    (Linear "stoch-k" (/ (:stoch-k c) 100.0) 1.0)

    ;; %D — [0, 100] normalized to [0, 1]
    (Linear "stoch-d" (/ (:stoch-d c) 100.0) 1.0)

    ;; K-D spread — signed, %K - %D indicates momentum direction
    (Linear "stoch-kd-spread" (/ (- (:stoch-k c) (:stoch-d c)) 100.0) 1.0)

    ;; Cross delta — signed change of (%K - %D) from prev candle
    (Linear "stoch-cross-delta" (:stoch-cross-delta c) 0.01)))
