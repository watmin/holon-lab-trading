;; scalar-accumulator.wat — per-magic-number f64 learning
;; Depends on: enums.wat (Outcome, ScalarEncoding)

(require primitives)
(require enums)

;; ── ScalarAccumulator ──────────────────────────────────────────────
;; Lives on the broker. Global per-pair. Each distance (trail, stop,
;; tp, runner-trail) gets its own. Grace outcomes accumulate one way,
;; Violence outcomes the other.

(struct scalar-accumulator
  [name : String]
  [encoding : ScalarEncoding]
  [grace-acc : Vector]
  [violence-acc : Vector]
  [count : usize])

(define (make-scalar-accumulator [name : String] [encoding : ScalarEncoding])
  : ScalarAccumulator
  (scalar-accumulator name encoding (zeros) (zeros) 0))

;; encode-by-scheme — dispatch on ScalarEncoding to produce a vector
(define (encode-by-scheme [encoding : ScalarEncoding] [value : f64])
  : Vector
  (match encoding
    (:log
      (encode-log value))
    ((Linear scale)
      (encode-linear value scale))
    ((Circular period)
      (encode-circular value period))))

;; observe-scalar — accumulate an encoded value into the appropriate prototype
(define (observe-scalar [acc : ScalarAccumulator]
                        [value : f64]
                        [outcome : Outcome]
                        [weight : f64])
  (let ((encoded (encode-by-scheme (:encoding acc) value))
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

;; extract-scalar — sweep candidates, find the one Grace prefers
(define (extract-scalar [acc : ScalarAccumulator]
                        [steps : usize]
                        [bounds : (f64, f64)])
  : f64
  (let (((lo hi) bounds)
        (step-size (/ (- hi lo) (max steps 1)))
        (best-value lo)
        (best-score f64-neg-infinity))
    (for-each (lambda (i)
      (let ((candidate (+ lo (* i step-size)))
            (encoded (encode-by-scheme (:encoding acc) candidate))
            (score (cosine encoded (:grace-acc acc))))
        (when (> score best-score)
          (set! best-value candidate)
          (set! best-score score))))
      (range 0 (+ steps 1)))
    best-value))
