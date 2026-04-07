; window-sampler.wat — deterministic log-uniform window selection.
; Depends on: nothing.
;
; Each market observer has its own — its own seed, its own time scale.
; The observer uses it every candle to decide how much history to look at.
;
; Owned by the market observer. Not by the enterprise. Not shared.

(require primitives)

(struct window-sampler
  [seed       : usize]
  [min-window : usize]
  [max-window : usize])

;; Interface

(define (new-window-sampler [seed : usize]
                            [min  : usize]
                            [max  : usize])
  : WindowSampler
  (make-window-sampler seed min max))

(define (sample [sampler      : WindowSampler]
                [encode-count : usize])
  : usize
  ; Returns a window size for this candle. Deterministic given the
  ; seed and encode-count. Log-uniform distribution between min and max.
  (let* ((rng   (+ (* (:seed sampler) 2654435761) encode-count))
         (hash  (mod (abs rng) 1000000))
         (t     (/ (+ hash 0.0) 1000000.0))
         (ln-min (ln (+ (:min-window sampler) 0.0)))
         (ln-max (ln (+ (:max-window sampler) 0.0)))
         (ln-w   (+ ln-min (* t (- ln-max ln-min)))))
    (clamp (round (exp ln-w))
           (:min-window sampler)
           (:max-window sampler))))
