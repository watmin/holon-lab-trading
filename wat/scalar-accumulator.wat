;; scalar-accumulator.wat — per-magic-number f64 learning
;; Depends on: enums (Outcome, ScalarEncoding)
;; Lives on the broker. Global per-pair.

(require primitives)
(require enums)

(struct scalar-accumulator
  [name : String]              ; diagnostic label ("trail-distance", etc.)
  [encoding : ScalarEncoding]  ; how values are encoded
  [grace-acc : Vector]         ; accumulated encoded values from Grace outcomes
  [violence-acc : Vector]      ; accumulated encoded values from Violence outcomes
  [count : usize])             ; number of observations

(define (make-scalar-accumulator [name : String] [encoding : ScalarEncoding])
  : ScalarAccumulator
  (scalar-accumulator name encoding (zeros) (zeros) 0))

;; Encode a scalar value using the accumulator's configured encoding
(define (encode-scalar-value [encoding : ScalarEncoding] [value : f64])
  : Vector
  (match encoding
    (:log
      (encode-log value))
    ((Linear scale)
      (encode-linear value scale))
    ((Circular period)
      (encode-circular value period))))

;; Observe a scalar value with its outcome
;; Grace outcomes accumulate into grace-acc, Violence into violence-acc
(define (observe-scalar [acc : ScalarAccumulator]
                        [value : f64]
                        [outcome : Outcome]
                        [weight : f64])
  : ScalarAccumulator
  (let ((encoded (amplify (encode-scalar-value (:encoding acc) value)
                          (encode-scalar-value (:encoding acc) value)
                          weight)))
    (match outcome
      (:grace
        (update acc
          :grace-acc (bundle (:grace-acc acc) encoded)
          :count (+ (:count acc) 1)))
      (:violence
        (update acc
          :violence-acc (bundle (:violence-acc acc) encoded)
          :count (+ (:count acc) 1))))))

;; Extract the scalar value that Grace prefers
;; Sweep candidates across the range, encode each, cosine against
;; the Grace prototype. Return the candidate closest to Grace.
(define (extract-scalar [acc : ScalarAccumulator]
                        [steps : usize]
                        [bounds : (f64 f64)])
  : f64
  (let (((lo hi) bounds)
        (step-size (/ (- hi lo) (+ 0.0 steps)))
        (grace-proto (:grace-acc acc)))
    (let ((best-val lo)
          (best-sim f64-neg-infinity))
      (fold (lambda (state i)
              (let (((bv bs) state)
                    (candidate (+ lo (* (+ 0.0 i) step-size)))
                    (encoded (encode-scalar-value (:encoding acc) candidate))
                    (sim (cosine encoded grace-proto)))
                (if (> sim bs)
                  (list candidate sim)
                  (list bv bs))))
            (list best-val best-sim)
            (range 0 (+ steps 1)))
      best-val)))
