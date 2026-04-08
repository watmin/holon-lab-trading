; window-sampler.wat — deterministic log-uniform window selection.
;
; Depends on: nothing.
;
; Each market observer has its own — its own seed, its own time scale.
; The observer uses it every candle to decide how much history to look at.
;
; min-window and max-window are crutches. The observer needs them
; to bootstrap. The optimal window is learnable. Future work.

(require primitives)

;; ── Struct ──────────────────────────────────────────────────────────────

(struct window-sampler
  [seed : usize]
  [min-window : usize]
  [max-window : usize])

;; ── Constructor ─────────────────────────────────────────────────────────

(define (make-window-sampler [seed : usize]
                             [min-window : usize]
                             [max-window : usize])
  : WindowSampler
  (make-window-sampler seed min-window max-window))

;; ── sample — deterministic window size for this candle ──────────────────
;;
;; encode-count: how many candles the post has processed so far.
;; Returns a window size in [min-window, max-window] via log-uniform
;; sampling. Deterministic: same seed + same count = same window.

(define (sample [ws : WindowSampler]
                [encode-count : usize])
  : usize
  ;; Hash the seed with encode-count for deterministic pseudo-random selection.
  ;; Log-uniform: equal probability per multiplicative interval.
  ;; ln(min) + hash-fraction * (ln(max) - ln(min)) -> exp -> round
  (let* ((hash (mod (+ (* encode-count 2654435761) (:seed ws)) 4294967296))
         (frac (/ (+ hash 0.0) 4294967296.0))
         (ln-min (ln (+ (:min-window ws) 0.0)))
         (ln-max (ln (+ (:max-window ws) 0.0)))
         (ln-val (+ ln-min (* frac (- ln-max ln-min))))
         (val (round (exp ln-val))))
    (clamp val (:min-window ws) (:max-window ws))))
