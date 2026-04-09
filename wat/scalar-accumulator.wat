;; scalar-accumulator.wat — ScalarAccumulator
;; Depends on: enums (Outcome, ScalarEncoding)

(require primitives)
(require enums)

;; ── ScalarAccumulator — per-magic-number f64 learning ─────────────────
;; Lives on the broker. Global per-pair. Each distance (trail, stop, tp,
;; runner-trail) gets its own. Separates grace/violence observations into
;; separate vector prototypes. Grace outcomes accumulate one way. Violence
;; outcomes accumulate the other. Extract recovers the value Grace prefers.
(struct scalar-accumulator
  [name : String]
  [encoding : ScalarEncoding]
  [grace-acc : Vector]
  [violence-acc : Vector]
  [count : usize])

(define (make-scalar-accumulator [name : String]
                                 [encoding : ScalarEncoding])
  : ScalarAccumulator
  (scalar-accumulator name encoding (zeros) (zeros) 0))

;; ── encode-scalar-value — dispatch on encoding enum ───────────────────
(define (encode-scalar-value [encoding : ScalarEncoding]
                             [value : f64])
  : Vector
  (match encoding
    (:log
      (encode-log value))
    ((Linear scale)
      (encode-linear value scale))
    ((Circular period)
      (encode-circular value period))))

;; ── observe-scalar — accumulate an observation ────────────────────────
;; value: f64 — the scalar to accumulate (e.g. a distance).
;; outcome: Outcome — :grace or :violence.
;; weight: f64 — scales the contribution.
(define (observe-scalar [acc : ScalarAccumulator]
                        [value : f64]
                        [outcome : Outcome]
                        [weight : f64])
  (let ((encoded (encode-scalar-value (:encoding acc) value))
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

;; ── extract-scalar — recover the value Grace prefers ──────────────────
;; Sweep candidate values across range, encode each, cosine against the
;; Grace prototype. Return the candidate closest to Grace.
;; steps: usize — how many candidates to try.
;; range: (f64, f64) — (min, max) bounds to sweep across.
(define (extract-scalar [acc : ScalarAccumulator]
                        [steps : usize]
                        [range : (f64, f64)])
  : f64
  (let (((range-min range-max) range)
        (step-size (/ (- range-max range-min) (+ 0.0 steps)))
        (grace-proto (:grace-acc acc)))
    (let ((best-value range-min)
          (best-score f64-neg-infinity))
      (for-each (lambda (i)
        (let ((candidate (+ range-min (* (+ 0.0 i) step-size)))
              (encoded (encode-scalar-value (:encoding acc) candidate))
              (score (cosine encoded grace-proto)))
          (when (> score best-score)
            (set! best-value candidate)
            (set! best-score score))))
        (range 0 steps))
      best-value)))
