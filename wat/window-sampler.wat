;; window-sampler.wat — deterministic log-uniform window selection
;; Depends on: nothing

(require primitives)

(struct window-sampler
  [seed : usize]
  [min-window : usize]
  [max-window : usize])

(define (make-window-sampler [seed : usize] [min-window : usize] [max-window : usize])
  : WindowSampler
  (window-sampler seed min-window max-window))

;; Deterministic log-uniform sampling. The same seed + encode-count always
;; yields the same window. No randomness at runtime — deterministic replay.
;; Log-uniform: small windows are more likely than large windows. The
;; distribution of time scales is uniform in log-space, not linear.
(define (sample [ws : WindowSampler] [encode-count : usize])
  : usize
  (let ((ln-min (ln (+ (:min-window ws) 0.0)))
        (ln-max (ln (+ (:max-window ws) 0.0)))
        ;; Deterministic hash: seed × prime + encode-count, mod a large prime
        (hash (mod (+ (* (:seed ws) 2654435761) encode-count) 4294967291))
        ;; Normalize to [0, 1)
        (t (/ (+ hash 0.0) 4294967291.0))
        ;; Log-uniform: uniform in log-space
        (ln-window (+ ln-min (* t (- ln-max ln-min))))
        (window (round (exp ln-window))))
    (clamp window (:min-window ws) (:max-window ws))))
