; window-sampler.wat — deterministic log-uniform window selection
;
; Depends on: nothing.
; Each market observer owns one. Same seed + same encode-count = same window.
; Log-uniform means small windows are explored as densely as large ones:
; the gap between 48 and 96 is sampled as often as 960 and 1920.

; ── WindowSampler — three fields, no state ─────────────────────────────

(struct window-sampler
  [seed : usize]
  [min-window : usize]
  [max-window : usize])

; ── Constructor ────────────────────────────────────────────────────────

(define (make-window-sampler [seed : usize]
                             [min-window : usize]
                             [max-window : usize])
  : WindowSampler
  (WindowSampler seed min-window max-window))

; ── Sampling ───────────────────────────────────────────────────────────

(define (sample [ws : WindowSampler]
                [encode-count : usize])
  : usize
  ; Deterministic pseudo-random: multiply-and-mod hash.
  ; No bitwise ops — the wat language provides arithmetic, not bit manipulation.
  (let* ((rng   (+ (* (:seed ws) 2654435761) encode-count))
         (hash  (mod (abs rng) 1000000))
         (t     (/ (+ hash 0.0) 1000000.0))
         (ln-min (ln (+ (:min-window ws) 0.0)))
         (ln-max (ln (+ (:max-window ws) 0.0)))
         (ln-w   (+ ln-min (* t (- ln-max ln-min)))))
    (clamp (round (exp ln-w))
           (:min-window ws)
           (:max-window ws))))
