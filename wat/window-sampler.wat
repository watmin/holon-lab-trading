;; window-sampler.wat — WindowSampler
;; Depends on: nothing

(require primitives)

;; ── WindowSampler — deterministic log-uniform window selection ────────
;; Each market observer has its own — its own seed, its own time scale.
;; min-window and max-window are crutches. The observer needs them to
;; bootstrap — it cannot learn its own time scale from nothing.
(struct window-sampler
  [seed : usize]
  [min-window : usize]
  [max-window : usize])

(define (make-window-sampler [seed : usize]
                             [min-window : usize]
                             [max-window : usize])
  : WindowSampler
  (window-sampler seed min-window max-window))

;; Deterministic log-uniform sample. Same seed + same encode-count = same window.
;; The hash mixes seed and encode-count to produce a deterministic value
;; in [min-window, max-window] on a log scale — small windows are more
;; likely than large ones.
(define (sample [ws : WindowSampler]
                [encode-count : usize])
  : usize
  (let ((log-min (ln (max 1.0 (+ 0.0 (:min-window ws)))))
        (log-max (ln (max 1.0 (+ 0.0 (:max-window ws)))))
        ;; Simple deterministic hash: mix seed and encode-count
        (hash (mod (* (+ (:seed ws) encode-count) 2654435761) 4294967296))
        (t (/ (+ 0.0 hash) 4294967296.0))
        (log-val (+ log-min (* t (- log-max log-min))))
        (window (round (exp log-val))))
    (clamp window (:min-window ws) (:max-window ws))))
