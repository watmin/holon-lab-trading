;; ── facts.wat — the enterprise's encoding conventions ────────────────
;;
;; How this enterprise encodes domain knowledge into vectors.
;; These are conventions, not primitives — another application
;; might compose atom + bind differently.

(require core/primitives)

;; Zone: "this indicator is in this state"
(define (fact/zone indicator zone)
  (bind (atom "at") (bind (atom indicator) (atom zone))))

;; Comparison: "A is above/below/crossing B"
(define (fact/comparison predicate a b)
  (bind (atom predicate) (bind (atom a) (atom b))))

;; Scalar: "this indicator has this continuous value"
(define (fact/scalar indicator value scale)
  (bind (atom indicator) (encode-linear value scale)))

;; Bare: "this named condition is present"
(define (fact/bare label)
  (atom label))
