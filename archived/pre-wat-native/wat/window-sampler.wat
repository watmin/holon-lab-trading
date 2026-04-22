;; window-sampler.wat — Deterministic log-uniform window selection.
;; Each market observer owns one. Its own seed, its own time scale.
;; Depends on: nothing.

(require primitives)

;; ── Struct ──────────────────────────────────────────────────────────

(struct window-sampler
  [seed : usize]
  [min-window : usize]
  [max-window : usize])

;; ── Interface ───────────────────────────────────────────────────────

(define (make-window-sampler [seed : usize]
                             [min : usize]
                             [max : usize])
  : WindowSampler
  (window-sampler seed min max))

(define (sample [ws : WindowSampler] [encode-count : usize])
  : usize
  ;; Deterministic log-uniform sample from [min-window, max-window]
  ;; using seed and encode-count to produce a reproducible window size.
  (let ((min-log (ln (:min-window ws)))
        (max-log (ln (:max-window ws)))
        ;; Deterministic hash from seed + encode-count
        (hash (mod (* (+ (:seed ws) encode-count) 2654435761) 4294967296))
        (t (/ hash 4294967296.0))
        (log-val (+ min-log (* t (- max-log min-log)))))
    (clamp (round (exp log-val))
           (:min-window ws)
           (:max-window ws))))
