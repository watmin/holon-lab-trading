; scalar-accumulator.wat — per-magic-number f64 learning.
; Depends on: nothing (uses scalar encoding from stdlib).
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
  [encoding     : Keyword]    ; :log, :linear, or :circular — configured at construction
  [grace-acc    : Vector]
  [violence-acc : Vector]
  [count        : usize])

;; ── Internal helper — dispatch encoding by the accumulator's configured scheme

(define (encode-value [acc : ScalarAccumulator] [value : f64])
  : Vector
  (match (:encoding acc)
    (:log      (encode-log value))
    (:linear   (encode-linear value 1.0))
    (:circular (encode-circular value 1.0))))

;; Interface

(define (make-scalar-accumulator [name : String]
                                [encoding : Keyword])
  : ScalarAccumulator
  ; grace-acc and violence-acc start as zero vectors.
  ; count starts at 0.
  (make-scalar-accumulator name encoding (zeros) (zeros) 0))

(define (observe-scalar [acc     : ScalarAccumulator]
                        [value   : f64]
                        [outcome : Outcome]
                        [weight  : f64])
  ; Encode the value using the configured scheme, scale by weight,
  ; accumulate into the appropriate prototype based on outcome.
  (let ((encoded (encode-value acc value)))
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
  ; Sweep `steps` candidate values across `range`, encode each using
  ; the configured scheme, cosine against the Grace prototype.
  ; Return the candidate closest to Grace.
  ; "What value does Grace prefer for this pair overall?"
  (let* ((lo    (first range))
         (hi    (second range))
         (step  (/ (- hi lo) (+ steps 0.0)))
         (candidates (map (lambda (i)
                            (+ lo (* (+ i 0.0) step)))
                          (range 0 steps)))
         (scored (map (lambda (v)
                        (list v (cosine (encode-value acc v)
                                        (:grace-acc acc))))
                      candidates)))
    (first (fold (lambda (best pair)
                   (if (> (second pair) (second best))
                       pair
                       best))
                 (first scored)
                 (rest scored)))))
