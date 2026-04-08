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
  ; Hash: mix encode-count with seed for deterministic pseudo-random value
  (let* ((h (* (+ (* (:seed ws) 6364136223846793005)
                   encode-count)
               1442695040888963407))
         ; Avalanche — spread entropy across all bits
         (h (^ h (>> h 33)))
         (h (* h 0xff51afd7ed558ccd))
         (h (^ h (>> h 33)))
         ; Map to [0, 1) uniformly
         (u (/ (>> h 11) (<< 1 53)))
         ; Log-uniform: exp(uniform(ln(min), ln(max)))
         (ln-min (ln (:min-window ws)))
         (ln-max (ln (:max-window ws)))
         (ln-w (+ ln-min (* u (- ln-max ln-min))))
         (w (round (exp ln-w))))
    (clamp w (:min-window ws) (:max-window ws))))
