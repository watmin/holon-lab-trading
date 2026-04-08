; scalar-accumulator.wat — per-magic-number f64 learning.
;
; Depends on: Outcome (from enums), ScalarEncoding (from enums).
;
; Lives on the broker. Global per-pair. Each distance (trail, stop,
; tp, runner-trail) gets its own. Separates grace/violence observations
; into separate f64 prototypes. Grace outcomes accumulate one way.
; Violence outcomes accumulate the other. Extract recovers the value
; Grace prefers — sweep candidate values against the Grace accumulator.

(require primitives)
(require enums)    ; Outcome, ScalarEncoding

;; ── Struct ──────────────────────────────────────────────────────────────

(struct scalar-accumulator
  [name : String]              ; which magic number ("trail-distance", etc.)
  [encoding : ScalarEncoding]  ; configured at construction — the data and
                               ; its interpretation travel together
  [grace-acc : Vector]         ; accumulated encoded values from Grace outcomes
  [violence-acc : Vector]      ; accumulated encoded values from Violence outcomes
  [count : usize])             ; number of observations. 0 = no data.

;; ── Constructor ─────────────────────────────────────────────────────────

(define (make-scalar-accumulator [name : String]
                                 [encoding : ScalarEncoding])
  : ScalarAccumulator
  (make-scalar-accumulator
    name
    encoding
    (zeros)             ; grace-acc — zero vector
    (zeros)             ; violence-acc — zero vector
    0))                 ; count

;; ── observe-scalar — accumulate an encoded value ────────────────────────
;;
;; value: f64 — the scalar to accumulate (e.g. a distance).
;; Encoded via the accumulator's ScalarEncoding — pattern-match to dispatch.
;; outcome: Outcome — :grace or :violence. Determines which accumulator
;; receives the encoded value.
;; weight: f64 — scales the contribution.

(define (observe-scalar [acc : ScalarAccumulator]
                        [value : f64]
                        [outcome : Outcome]
                        [weight : f64])
  (let ((encoded (match (:encoding acc)
                   (:log               (encode-log value))
                   ((Linear scale)     (encode-linear value scale))
                   ((Circular period)  (encode-circular value period)))))
    (let ((weighted (amplify encoded encoded weight)))
      (match outcome
        (:grace    (set! (:grace-acc acc)
                         (bundle (:grace-acc acc) weighted)))
        (:violence (set! (:violence-acc acc)
                         (bundle (:violence-acc acc) weighted)))))
    (inc! (:count acc))))

;; ── extract-scalar — recover the value Grace prefers ────────────────────
;;
;; steps: how many candidates to try.
;; range: (min, max) bounds to sweep across.
;; Sweep candidates, encode each, cosine against the Grace prototype.
;; Return the candidate closest to Grace.

(define (extract-scalar [acc : ScalarAccumulator]
                        [steps : usize]
                        [range : (f64, f64)])
  : f64
  (let* ((min-val (first range))
         (max-val (second range))
         (step-size (/ (- max-val min-val) (- steps 1)))
         (candidates (map (lambda (i) (+ min-val (* i step-size)))
                          (range steps)))
         (scores (map (lambda (v)
                        (let ((encoded (match (:encoding acc)
                                         (:log               (encode-log v))
                                         ((Linear scale)     (encode-linear v scale))
                                         ((Circular period)  (encode-circular v period)))))
                          (list v (cosine encoded (:grace-acc acc)))))
                      candidates)))
    ;; Return the candidate with the highest cosine to Grace
    (first (first (sort-by second > scores)))))
