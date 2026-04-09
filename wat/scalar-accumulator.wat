;; scalar-accumulator.wat — per-magic-number f64 learning
;; Depends on: enums (Outcome, ScalarEncoding), primitives

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

;; Encode a value using the accumulator's configured encoding.
(define (encode-with-encoding [encoding : ScalarEncoding] [value : f64])
  : Vector
  (match encoding
    (:log
      (encode-log value))
    ((Linear scale)
      (encode-linear value scale))
    ((Circular period)
      (encode-circular value period))))

;; Observe a scalar value with an outcome and weight.
;; Grace outcomes accumulate into grace-acc. Violence into violence-acc.
(define (observe-scalar [acc : ScalarAccumulator] [value : f64]
                        [outcome : Outcome] [weight : f64])
  (let ((encoded (encode-with-encoding (:encoding acc) value))
        (weighted (amplify encoded encoded weight)))
    (match outcome
      (:grace
        (begin
          (set! acc :grace-acc (bundle (:grace-acc acc) weighted))
          (inc! acc :count)))
      (:violence
        (begin
          (set! acc :violence-acc (bundle (:violence-acc acc) weighted))
          (inc! acc :count))))))

;; Extract the value Grace prefers. Sweep candidate values, encode each,
;; cosine against the Grace prototype. Return the candidate closest to Grace.
(define (extract-scalar [acc : ScalarAccumulator] [steps : usize]
                        [range-min : f64] [range-max : f64])
  : f64
  (let ((step-size (/ (- range-max range-min) (+ steps 0.0)))
        (best-value range-min)
        (best-score f64-neg-infinity))
    (for-each (lambda (i)
      (let ((candidate (+ range-min (* (+ i 0.0) step-size)))
            (encoded (encode-with-encoding (:encoding acc) candidate))
            (score (cosine encoded (:grace-acc acc))))
        (when (> score best-score)
          (set! best-value candidate)
          (set! best-score score))))
      (range 0 steps))
    best-value))
