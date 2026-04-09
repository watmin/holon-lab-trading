;; scalar-accumulator.wat — per-magic-number f64 learning
;; Depends on: enums (Outcome, ScalarEncoding)
;; Lives on the broker. Global per-pair.
;; Grace outcomes accumulate one way. Violence the other.
;; Extract recovers the value Grace prefers.

(require primitives)
(require enums)

(struct scalar-accumulator
  [name : String]              ; which magic number ("trail-distance", etc.)
  [encoding : ScalarEncoding]  ; configured at construction
  [grace-acc : Vector]         ; accumulated encoded values from Grace outcomes
  [violence-acc : Vector]      ; accumulated encoded values from Violence outcomes
  [count : usize])             ; number of observations. 0 = no data.

(define (make-scalar-accumulator [name : String] [encoding : ScalarEncoding])
  : ScalarAccumulator
  (scalar-accumulator name encoding (zeros) (zeros) 0))

;; Encode a value according to the accumulator's encoding scheme.
(define (encode-with-scheme [encoding : ScalarEncoding] [value : f64])
  : Vector
  (match encoding
    (:log              (encode-log value))
    ((Linear scale)    (encode-linear value scale))
    ((Circular period) (encode-circular value period))))

;; Observe a resolved scalar value.
;; outcome: :grace or :violence — determines which accumulator receives.
;; weight: f64 — scales the contribution. Larger = stronger signal.
(define (observe-scalar [acc : ScalarAccumulator] [value : f64]
                        [outcome : Outcome] [weight : f64])
  (let ((encoded (amplify (encode-with-scheme (:encoding acc) value)
                          (encode-with-scheme (:encoding acc) value)
                          weight)))
    (match outcome
      (:grace   (begin
                  (set! (:grace-acc acc) (bundle (:grace-acc acc) encoded))
                  (inc! (:count acc))))
      (:violence (begin
                   (set! (:violence-acc acc) (bundle (:violence-acc acc) encoded))
                   (inc! (:count acc)))))))

;; Extract the value Grace prefers.
;; Sweep candidates across range, encode each, cosine against Grace prototype.
;; Return the candidate closest to Grace.
(define (extract-scalar [acc : ScalarAccumulator] [steps : usize]
                        [bounds : (f64, f64)])
  : f64
  (let (((lo hi) bounds)
        (step-size (/ (- hi lo) (+ 0.0 steps)))
        (best-val  lo)
        (best-sim  -2.0))
    (for-each (lambda (i)
      (let ((candidate (+ lo (* (+ 0.0 i) step-size)))
            (encoded   (encode-with-scheme (:encoding acc) candidate))
            (sim       (cosine encoded (:grace-acc acc))))
        (when (> sim best-sim)
          (set! best-val candidate)
          (set! best-sim sim))))
      (range 0 (+ steps 1)))
    best-val))
