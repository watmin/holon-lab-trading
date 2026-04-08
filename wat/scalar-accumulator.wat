; scalar-accumulator.wat — per-magic-number f64 learning.
; Depends on: nothing (uses encode-log from stdlib).
;
; Lives on the broker. Global per-pair. Each distance (trail, stop, tp,
; runner-trail) gets its own accumulator.
;
; Separates grace/violence observations into separate f64 prototypes.
; Extract recovers the value Grace prefers — sweep candidate values
; against the Grace accumulator, find the one with highest cosine.

(require primitives)

(struct scalar-accumulator
  [name         : String]
  [grace-acc    : Vector]
  [violence-acc : Vector]
  [count        : usize])

;; Interface

(define (make-scalar-accumulator [name : String])
  : ScalarAccumulator
  ; grace-acc and violence-acc start as zero vectors.
  ; count starts at 0.
  (make-scalar-accumulator name (zeros) (zeros) 0))

(define (observe-scalar [acc     : ScalarAccumulator]
                        [value   : f64]
                        [outcome : Outcome]
                        [weight  : f64])
  ; Encode the value, scale by weight, accumulate into the appropriate
  ; prototype based on outcome.
  (let ((encoded (encode-log value)))
    (match outcome
      (:grace    (set! (:grace-acc acc)
                       (bundle (:grace-acc acc)
                               (amplify encoded encoded weight))))
      (:violence (set! (:violence-acc acc)
                       (bundle (:violence-acc acc)
                               (amplify encoded encoded weight)))))
    (inc! (:count acc))))

(define (extract-scalar [acc   : ScalarAccumulator]
                        [steps : usize]
                        [range : (f64 f64)])
  : f64
  ; Sweep `steps` candidate values across `range`, encode each,
  ; cosine against the Grace prototype. Return the candidate closest
  ; to Grace. "What value does Grace prefer for this pair overall?"
  (let* ((lo    (first range))
         (hi    (second range))
         (step  (/ (- hi lo) (+ steps 0.0)))
         (candidates (map (lambda (i)
                            (+ lo (* (+ i 0.0) step)))
                          (range 0 steps)))
         (scored (map (lambda (v)
                        (list v (cosine (encode-log v)
                                        (:grace-acc acc))))
                      candidates)))
    (first (fold (lambda (best pair)
                   (if (> (second pair) (second best))
                       pair
                       best))
                 (first scored)
                 (rest scored)))))
