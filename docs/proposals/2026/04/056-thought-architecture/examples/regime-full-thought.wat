;; regime-full-thought.wat — Full lens regime observer thought.
;;
;; Everything Core sees + phase awareness as streams.

(define (regime-full-thought window market-rhythms dims)
  (bundle
    ;; ── Market rhythms (passed through) ─────────────────────────
    market-rhythms

    ;; ── Same 8 regime + 2 time rhythms as Core ─────────────────
    (indicator-rhythm window "kama-er"        (lambda (c) (:kama-er c))        0.0 1.0 0.2 dims)
    (indicator-rhythm window "choppiness"     (lambda (c) (:choppiness c))     0.0 100.0 10.0 dims)
    (indicator-rhythm window "dfa-alpha"      (lambda (c) (:dfa-alpha c))      0.0 2.0 0.3 dims)
    (indicator-rhythm window "variance-ratio" (lambda (c) (:variance-ratio c)) 0.0 3.0 0.5 dims)
    (indicator-rhythm window "entropy-rate"   (lambda (c) (:entropy-rate c))   0.0 1.0 0.2 dims)
    (indicator-rhythm window "fractal-dim"    (lambda (c) (:fractal-dim c))    1.0 2.0 0.2 dims)
    (indicator-rhythm window "aroon-up"       (lambda (c) (:aroon-up c))       0.0 100.0 10.0 dims)
    (indicator-rhythm window "aroon-down"     (lambda (c) (:aroon-down c))     0.0 100.0 10.0 dims)

    (circular-rhythm window "hour"        (lambda (c) (:hour c))        24.0 dims)
    (circular-rhythm window "day-of-week" (lambda (c) (:day-of-week c)) 7.0 dims)

    ;; ── Phase streams — thermometer ─────────────────────────────
    (indicator-rhythm window "phase-duration"
      (lambda (c) (exact->inexact (:phase-duration c)))
      0.0 200.0 50.0 dims)

    (indicator-rhythm window "avg-phase-duration"
      (lambda (c) (avg-duration (:phase-history c)))
      0.0 200.0 50.0 dims)

    (indicator-rhythm window "avg-phase-range"
      (lambda (c) (avg-range (:phase-history c)))
      0.0 0.1 0.02 dims)))

;; 13 rhythms + ~15 market rhythms = ~28 items.
;; Budget at D=10,000: 100. Comfortable.
