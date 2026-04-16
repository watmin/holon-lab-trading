;; regime-core-thought.wat — Core lens regime observer thought.
;;
;; Regime character over time + time as circular rhythms.
;; Receives market rhythms, adds its own regime rhythms.

(define (regime-core-thought window market-rhythms dims)
  (bundle
    ;; ── Market rhythms (passed through) ─────────────────────────
    market-rhythms

    ;; ── Regime streams — thermometer, natural bounds ────────────
    (indicator-rhythm window "kama-er"        (lambda (c) (:kama-er c))        0.0 1.0 0.2 dims)
    (indicator-rhythm window "choppiness"     (lambda (c) (:choppiness c))     0.0 100.0 10.0 dims)
    (indicator-rhythm window "dfa-alpha"      (lambda (c) (:dfa-alpha c))      0.0 2.0 0.3 dims)
    (indicator-rhythm window "variance-ratio" (lambda (c) (:variance-ratio c)) 0.0 3.0 0.5 dims)
    (indicator-rhythm window "entropy-rate"   (lambda (c) (:entropy-rate c))   0.0 1.0 0.2 dims)
    (indicator-rhythm window "fractal-dim"    (lambda (c) (:fractal-dim c))    1.0 2.0 0.2 dims)
    (indicator-rhythm window "aroon-up"       (lambda (c) (:aroon-up c))       0.0 100.0 10.0 dims)
    (indicator-rhythm window "aroon-down"     (lambda (c) (:aroon-down c))     0.0 100.0 10.0 dims)

    ;; ── Time — CIRCULAR rhythms, no delta ───────────────────────
    ;; Hour wraps 23→0. Day wraps 7→1. Circular encoding handles it.
    (circular-rhythm window "hour"        (lambda (c) (:hour c))        24.0 dims)
    (circular-rhythm window "day-of-week" (lambda (c) (:day-of-week c)) 7.0 dims)))

;; 8 regime rhythms + 2 circular time rhythms + ~15 market rhythms = ~25 items.
;; Budget at D=10,000: 100. Comfortable.
