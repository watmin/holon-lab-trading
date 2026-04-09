;; window-sampler.wat — deterministic log-uniform window selection
;; Depends on: nothing

(require primitives)

;; ── WindowSampler ──────────────────────────────────────────────────
;; Each market observer has its own — its own seed, its own time scale.
;; Deterministic log-uniform selection from [min-window, max-window].

(struct window-sampler
  [seed : usize]
  [min-window : usize]
  [max-window : usize])

(define (make-window-sampler [seed : usize]
                             [min-window : usize]
                             [max-window : usize])
  : WindowSampler
  (window-sampler seed min-window max-window))

;; sample — deterministic log-uniform window size from encode-count.
;; The hash ensures reproducibility. Log-uniform gives equal probability
;; to each order of magnitude: short windows and long windows are equally
;; likely to be explored.
(define (sample [ws : WindowSampler] [encode-count : usize])
  : usize
  (let ((hash (mod (* (+ encode-count (:seed ws)) 2654435761) 4294967296))
        (t (/ (mod hash 10000) 10000.0))
        (log-min (ln (max (:min-window ws) 1)))
        (log-max (ln (:max-window ws)))
        (log-val (+ log-min (* t (- log-max log-min))))
        (raw (round (exp log-val)))
        (clamped (clamp raw (:min-window ws) (:max-window ws))))
    clamped))
