;; ── patterns.wat — the enterprise's derived patterns ─────────────────
;;
;; Compositions of primitives into enterprise-specific concepts.
;; These are this application's design choices, not language primitives.

(require core/primitives)
(require core/structural)

;; Gate: annotates a vector with credibility status.
;; The message always flows. The consumer decides what credibility means.
;; The filter is a thought, not a suppression.
(define (gate opinion-vector expert-atom proven?)
  (let ((status (if proven? (atom "proven") (atom "tentative"))))
    (bundle opinion-vector (bind expert-atom status))))

;; Opinion: project Prediction → Vector (domain-specific, lossy).
;; Extracts direction and magnitude, binds to expert identity.
(define (opinion prediction expert-atom)
  (let ((direction (if (>= (:raw-cosine prediction) 0) (atom "buy") (atom "sell")))
        (magnitude (encode-linear (abs (:raw-cosine prediction)) 1.0)))
    (bind expert-atom (bind direction magnitude))))

;; Consumers filter by reading the expert's status:
;;   Manager: reads proven experts' opinions, ignores tentative
;;   Risk:    sees everything — proven and tentative
;;   Ledger:  records everything
