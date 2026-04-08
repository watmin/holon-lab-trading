;; vocab/market/fibonacci.wat — retracement level detection.
;;
;; Depends on: Candle, ThoughtAST.
;;
;; Pure: candle in, ASTs out. No state.
;; Range position at multiple lookback periods — where close sits
;; within the recent high-low range. This IS the Fibonacci signal:
;; 0.382, 0.500, 0.618 are just points on the [0, 1] position.
;; The reckoner learns which positions matter.

(require primitives)
(require candle)
(require enums)     ; ThoughtAST

;; ── encode-fibonacci-facts ──────────────────────────────────────────────

(define (encode-fibonacci-facts [c : Candle])
  : Vec<ThoughtAST>
  (list
    ;; Range positions at different lookbacks — [0, 1]
    ;; 0.0 = at the low, 1.0 = at the high. The discriminant learns
    ;; which positions predict direction.
    (Linear "range-pos-12" (:range-pos-12 c) 1.0)
    (Linear "range-pos-24" (:range-pos-24 c) 1.0)
    (Linear "range-pos-48" (:range-pos-48 c) 1.0)))
