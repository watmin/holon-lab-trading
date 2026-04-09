;; window-sampler.wat — deterministic log-uniform window selection
;; Depends on: nothing
;; Each market observer has its own — its own seed, its own time scale.

(require primitives)

(struct window-sampler
  [seed : usize]
  [min-window : usize]
  [max-window : usize])

;; Constructor
(define (make-window-sampler [seed : usize] [min-w : usize] [max-w : usize])
  : WindowSampler
  (window-sampler seed min-w max-w))

;; Deterministic log-uniform sample from the window range.
;; Uses a hash of (seed, encode-count) to pick a window size.
;; Log-uniform: equal probability per multiplicative interval,
;; so the observer explores short and long windows fairly.
(define (sample [ws : WindowSampler] [encode-count : usize])
  : usize
  (let ((hash (mod (* (+ (:seed ws) encode-count) 2654435761) 4294967296))
        (t    (/ (mod hash 10000) 10000.0))
        (log-min (ln (max 1.0 (+ 0.0 (:min-window ws)))))
        (log-max (ln (max 1.0 (+ 0.0 (:max-window ws)))))
        (log-val (+ log-min (* t (- log-max log-min))))
        (raw     (round (exp log-val))))
    (clamp raw (:min-window ws) (:max-window ws))))
