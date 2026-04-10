;; window-sampler.wat — deterministic log-uniform window selection
;; Depends on: nothing
;; Owned by the market observer. Not shared.

(require primitives)

(struct window-sampler
  [seed : usize]
  [min-window : usize]
  [max-window : usize])

(define (make-window-sampler [seed : usize]
                             [min-window : usize]
                             [max-window : usize])
  : WindowSampler
  (window-sampler seed min-window max-window))

;; Deterministic log-uniform sample. Same seed + same encode-count → same window.
;; The log-uniform distribution favors shorter windows (more responsive)
;; while still sampling long windows (structural context).
(define (sample [ws : WindowSampler] [encode-count : usize])
  : usize
  (let ((log-min (ln (max 1.0 (+ 0.0 (:min-window ws)))))
        (log-max (ln (max 1.0 (+ 0.0 (:max-window ws)))))
        ;; Simple deterministic hash: seed × encode-count → pseudo-random float in [0, 1)
        (hash (mod (* (+ (:seed ws) encode-count) 2654435761) 4294967296))
        (t (/ (+ 0.0 hash) 4294967296.0))
        (log-val (+ log-min (* t (- log-max log-min))))
        (window (round (exp log-val))))
    (clamp (max 1 window) (:min-window ws) (:max-window ws))))
