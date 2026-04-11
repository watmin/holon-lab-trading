;; scalar-accumulator.wat — Per-magic-number f64 learning.
;; Lives on the broker. Global per-pair. Each distance gets its own.
;; Separates grace/violence observations into separate f64 prototypes.
;; Depends on: Outcome enum.

(require primitives)

;; ScalarEncoding is declared in enums.wat

;; ── Struct ──────────────────────────────────────────────────────────

(struct scalar-accumulator
  [name : String]                  ; which magic number ("trail-distance", etc.)
  [encoding : ScalarEncoding]      ; configured at construction
  [grace-acc : Vector]             ; accumulated encoded values from Grace outcomes
  [violence-acc : Vector]          ; accumulated encoded values from Violence outcomes
  [count : usize])                 ; number of observations. 0 = no data.

;; ── Interface ───────────────────────────────────────────────────────

(define (make-scalar-accumulator [name : String]
                                 [encoding : ScalarEncoding]
                                 [dims : usize])
  : ScalarAccumulator
  (scalar-accumulator name encoding (zeros dims) (zeros dims) 0))

(define (observe-scalar [acc : ScalarAccumulator]
                        [value : f64]
                        [outcome : Outcome]
                        [weight : f64])
  ;; Encode value via the accumulator's ScalarEncoding, then accumulate
  ;; into the appropriate prototype based on outcome.
  (let ((encoded (match (:encoding acc)
                   (:log          (encode-log value))
                   ((Linear s)   (encode-linear value s))
                   ((Circular p) (encode-circular value p))))
        (scaled (amplify encoded weight)))
    (match outcome
      (:grace    (update acc :grace-acc
                   (bundle (:grace-acc acc) scaled)
                   :count (+ (:count acc) 1)))
      (:violence (update acc :violence-acc
                   (bundle (:violence-acc acc) scaled)
                   :count (+ (:count acc) 1))))))

(define (extract-scalar [acc : ScalarAccumulator]
                        [steps : usize]
                        [range : (f64 f64)])
  : f64
  ;; Sweep `steps` candidate values across `range`, encode each, cosine
  ;; against the Grace prototype. Return the candidate closest to Grace.
  (let (((range-min range-max) range)
        (step-size (/ (- range-max range-min) (- steps 1)))
        (candidates (map (lambda (i)
                           (+ range-min (* i step-size)))
                         (range 0 steps)))
        (scores (map (lambda (v)
                       (let ((encoded (match (:encoding acc)
                                       (:log          (encode-log v))
                                       ((Linear s)   (encode-linear v s))
                                       ((Circular p) (encode-circular v p)))))
                         (list v (cosine encoded (:grace-acc acc)))))
                     candidates)))
    (first (fold (lambda (best candidate)
                   (if (> (second candidate) (second best))
                       candidate
                       best))
                 (first scores)
                 (rest scores)))))
