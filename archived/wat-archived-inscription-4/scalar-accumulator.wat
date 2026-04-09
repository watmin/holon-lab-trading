; scalar-accumulator.wat — per-distance f64 learning.
; Depends on: enums (Outcome, ScalarEncoding).
;
; Lives on the broker. Global per-pair. Each distance (trail, stop, tp,
; runner-trail) gets its own accumulator.
;
; Separates grace/violence observations into separate f64 prototypes.
; Extract recovers the value Grace prefers — sweep candidate values
; against the Grace accumulator, find the one with highest cosine.

(require primitives)
(require enums)       ; Outcome (:grace/:violence) used in observe-scalar

;; ScalarEncoding lives in enums.wat — required above.

(struct scalar-accumulator
  [name         : String]
  [encoding     : ScalarEncoding]
  [grace-acc    : Vector]
  [violence-acc : Vector]
  [count        : usize])

;; ── Internal helper — dispatch encoding by pattern match

(define (encode-value [enc : ScalarEncoding] [value : f64])
  : Vector
  (match enc
    (:log           (encode-log value))
    ((Linear s)     (encode-linear value s))
    ((Circular p)   (encode-circular value p))))

;; Interface

(define (make-scalar-accumulator [name : String]
                                [encoding : ScalarEncoding])
  : ScalarAccumulator
  (scalar-accumulator name encoding (zeros) (zeros) 0))

(define (observe-scalar [acc     : ScalarAccumulator]
                        [value   : f64]
                        [outcome : Outcome]
                        [weight  : f64])
  (let ((encoded (encode-value (:encoding acc) value)))
    (match outcome
      (:grace    (set! (:grace-acc acc)
                       (bundle (:grace-acc acc)
                               (amplify encoded encoded weight))))
      (:violence (set! (:violence-acc acc)
                       (bundle (:violence-acc acc)
                               (amplify encoded encoded weight)))))
    (inc! (:count acc))))

(define (extract-scalar [acc    : ScalarAccumulator]
                        [steps  : usize]
                        [bounds : (f64 f64)])
  : f64
  (let* ((lo    (first bounds))
         (hi    (second bounds))
         (step  (/ (- hi lo) (+ steps 0.0)))
         (candidates (map (lambda (i)
                            (+ lo (* (+ i 0.0) step)))
                          (range 0 steps)))
         (scored (map (lambda (v)
                        (list v (cosine (encode-value (:encoding acc) v)
                                        (:grace-acc acc))))
                      candidates)))
    (first (fold (lambda (best pair)
                   (if (> (second pair) (second best))
                       pair
                       best))
                 (first scored)
                 (rest scored)))))
