;; regime-full-thought.wat — Full lens regime observer thought.
;;
;; Everything Core sees + phase awareness as streams.
;; "How is the regime changing AND how are the phases changing?"

(define (regime-full-thought window market-rhythms dims)
  (bundle
    ;; ── Market rhythms (passed through) ─────────────────────────
    market-rhythms

    ;; ── Same 10 regime + time rhythms as Core ───────────────────
    (indicator-rhythm window "kama-er"        (lambda (c) (:kama-er c))        dims)
    (indicator-rhythm window "choppiness"     (lambda (c) (:choppiness c))     dims)
    (indicator-rhythm window "dfa-alpha"      (lambda (c) (:dfa-alpha c))      dims)
    (indicator-rhythm window "variance-ratio" (lambda (c) (:variance-ratio c)) dims)
    (indicator-rhythm window "entropy-rate"   (lambda (c) (:entropy-rate c))   dims)
    (indicator-rhythm window "fractal-dim"    (lambda (c) (:fractal-dim c))    dims)
    (indicator-rhythm window "aroon-up"       (lambda (c) (:aroon-up c))       dims)
    (indicator-rhythm window "aroon-down"     (lambda (c) (:aroon-down c))     dims)
    (indicator-rhythm window "hour"           (lambda (c) (:hour c))           dims)
    (indicator-rhythm window "day-of-week"    (lambda (c) (:day-of-week c))    dims)

    ;; ── Phase streams — how are the phases evolving? ────────────
    (indicator-rhythm window "phase-duration"
      (lambda (c) (exact->inexact (:phase-duration c))) dims)

    (indicator-rhythm window "avg-phase-duration"
      (lambda (c) (avg-duration (:phase-history c))) dims)

    (indicator-rhythm window "avg-phase-range"
      (lambda (c) (avg-range (:phase-history c))) dims)))

;; 13 regime+phase rhythm vectors + ~10-15 market rhythms = ~23-28 items.
;; Budget at D=10,000: 100. Comfortable.
;;
;; What Full adds over Core:
;;
;; "phase-duration rhythm shows short-long-short-long pattern"
;;   → alternating between brief moves and extended consolidations.
;;
;; "avg-phase-duration rhythm falling over time"
;;   → phases getting shorter → market speeding up → regime change.
;;
;; "avg-phase-range rhythm rising + choppiness rhythm rising"
;;   → wider swings, more chaos → volatility regime.
