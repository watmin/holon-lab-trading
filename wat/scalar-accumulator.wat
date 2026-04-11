;; scalar-accumulator.wat — Per-scalar f64 learning via VSA prototypes.
;; Lives on the broker. Global per-pair. Each distance gets its own.
;; Separates grace/violence observations into separate vector prototypes.
;; Extract sweeps candidates and returns the value closest to the grace centroid.
;; Depends on: Outcome enum, ScalarEncoder.

(require primitives)

;; ScalarEncoding is declared in enums.wat

;; ── Struct ──────────────────────────────────────────────────────────

(struct scalar-accumulator
  [name : String]                  ; which scalar ("trail-distance", etc.)
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

;; Encode value per the accumulator's encoding, amplify by weight,
;; and bundle into the appropriate accumulator based on outcome.
;; scalar-encoder is passed explicitly — the accumulator does not own it.
(define (observe-scalar [acc : ScalarAccumulator]
                        [value : f64]
                        [outcome : Outcome]
                        [weight : f64]
                        [scalar-encoder : ScalarEncoder])
  (let ((encoded (encode-value acc value scalar-encoder))
        (scaled (amplify encoded encoded weight)))
    (match outcome
      (:grace    (update acc :grace-acc
                   (bundle (:grace-acc acc) scaled)
                   :count (+ (:count acc) 1)))
      (:violence (update acc :violence-acc
                   (bundle (:violence-acc acc) scaled)
                   :count (+ (:count acc) 1))))))

;; Sweep `steps` candidate values across `range`, encode each, cosine
;; against the Grace prototype. Return the candidate closest to Grace.
;; scalar-encoder is passed explicitly — the accumulator does not own it.
(define (extract-scalar [acc : ScalarAccumulator]
                        [steps : usize]
                        [range : (f64 f64)]
                        [scalar-encoder : ScalarEncoder])
  : f64
  (let (((range-min range-max) range)
        (step-size (/ (- range-max range-min) (- steps 1)))
        (candidates (map (lambda (i)
                           (+ range-min (* i step-size)))
                         (range 0 steps)))
        (scores (map (lambda (v)
                       (let ((encoded (encode-value acc v scalar-encoder)))
                         (list v (cosine encoded (:grace-acc acc)))))
                     candidates)))
    (first (fold (lambda (best candidate)
                   (if (> (second candidate) (second best))
                       candidate
                       best))
                 (first scores)
                 (rest scores)))))

;; ── Private ─────────────────────────────────────────────────────────

;; Encode a value using the accumulator's configured encoding.
;; scalar-encoder is passed explicitly — matches Rust signature.
(define (encode-value [acc : ScalarAccumulator]
                      [value : f64]
                      [scalar-encoder : ScalarEncoder])
  : Vector
  (match (:encoding acc)
    (:log          (encode-log scalar-encoder value))
    ((Linear s)   (encode-linear scalar-encoder value s))
    ((Circular p) (encode-circular scalar-encoder value p))))
