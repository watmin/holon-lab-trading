;; position-full-thought.wat — Full lens position observer thought.
;;
;; Everything Core sees + phase awareness as streams.
;; "How is the regime changing AND how are the phases changing?"

(define (position-full-thought window market-rhythms dims)
  (bundle
    ;; ── Market rhythms (passed through) ─────────────────────────
    market-rhythms  ;; ~10-15 rhythm vectors

    ;; ── Same 10 regime + time rhythms as Core ───────────────────
    (indicator-rhythm window "kama-er"        (lambda (c) c.kama-er)        dims)
    (indicator-rhythm window "choppiness"     (lambda (c) c.choppiness)     dims)
    (indicator-rhythm window "dfa-alpha"      (lambda (c) c.dfa-alpha)      dims)
    (indicator-rhythm window "variance-ratio" (lambda (c) c.variance-ratio) dims)
    (indicator-rhythm window "entropy-rate"   (lambda (c) c.entropy-rate)   dims)
    (indicator-rhythm window "fractal-dim"    (lambda (c) c.fractal-dim)    dims)
    (indicator-rhythm window "aroon-up"       (lambda (c) c.aroon-up)       dims)
    (indicator-rhythm window "aroon-down"     (lambda (c) c.aroon-down)     dims)
    (indicator-rhythm window "hour"           (lambda (c) c.hour)           dims)
    (indicator-rhythm window "day-of-week"    (lambda (c) c.day-of-week)    dims)

    ;; ── Phase streams — how are the phases evolving? ────────────
    ;; phase-duration resets at each new phase. As a stream, it shows
    ;; "how long has the current phase been running" over time.
    ;; Short bursts = choppy. Long steady values = trending.
    (indicator-rhythm window "phase-duration"
      (lambda (c) (exact->inexact c.phase-duration)) dims)

    ;; Phase summary streams — computed from phase_history at each candle.
    ;; These change slowly — the averages shift as new phases complete.
    (indicator-rhythm window "avg-phase-duration"
      (lambda (c) (avg-duration c.phase-history)) dims)
    (indicator-rhythm window "avg-phase-range"
      (lambda (c) (avg-range c.phase-history)) dims)))

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
;;
;; The Full lens sees the market's structural evolution — not just
;; the regime character (Core) but how the phase structure itself
;; is changing over time.
