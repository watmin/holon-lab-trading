;; -- window-sampler.wat -- deterministic log-uniform window sampling ---------
;;
;; Each candle gets a window size drawn from a log-uniform distribution
;; over [min-window, max-window]. Same candle index + same seed = same
;; window size. Reproducible across runs.
;;
;; Log-uniform means we explore small windows as densely as large ones.
;; The difference between 48 and 96 candles is as likely to be sampled
;; as the difference between 960 and 1920.

(require core/structural)

;; -- State ------------------------------------------------------------------

(struct window-sampler
  seed                   ; u64 -- deterministic seed
  min-window             ; usize -- lower bound (default 12 = 1 hour)
  max-window)            ; usize -- upper bound (default 2016 = 1 week)

(define (new-window-sampler seed min-window max-window)
  (window-sampler :seed seed :min-window min-window :max-window max-window))

;; -- Sample -----------------------------------------------------------------

(define (sample sampler candle-idx)
  "Sample a window size for a given candle index.
   Returns a value in [min-window, max-window], log-uniformly distributed.
   Deterministic: same candle-idx always returns the same window."
  ;; Hash: mix candle index with seed (three-round multiply-xorshift)
  ;; Map hash to [0, 1) uniformly
  ;; Log-uniform: exp(uniform(ln(min), ln(max)))
  ; rune:gaze(phantom) — hash-to-uniform is not in the wat language
  (let ((u (hash-to-uniform (:seed sampler) candle-idx))
        (ln-min (ln (:min-window sampler)))
        (ln-max (ln (:max-window sampler)))
        (ln-w (+ ln-min (* u (- ln-max ln-min)))))
    (clamp (round (exp ln-w)) (:min-window sampler) (:max-window sampler))))

;; -- Horizon ----------------------------------------------------------------

(define (horizon-for sampler window)
  "The horizon for a given window: 75% of window size.
   Starting heuristic -- the horizon expert will learn the real ratio.
   At least 12 candles (1 hour)."
  (max 12 (/ (* window 3) 4)))

;; -- What the window sampler does NOT do ------------------------------------
;; - Does NOT choose which expert sees which window (that's the observer)
;; - Does NOT learn optimal windows (future: horizon expert)
;; - Does NOT depend on market data (pure function of seed + index)
;; - Deterministic. Reproducible. Stateless after construction.
