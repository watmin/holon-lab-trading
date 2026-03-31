;; ── vocab/fibonacci.wat — Fibonacci retracement levels ──────────
;;
;; Computes proximity to fib levels using the viewport swing high/low.
;; Window-dependent — swing range is the expert's observation window,
;; not pre-computed on Candle.
;;
;; Expert profile: structure

(require vocab/mod)
(require std/facts)

;; ── Atoms introduced ───────────────────────────────────────────

;; Indicators:   close
;; Fib levels:   fib-236, fib-382, fib-500, fib-618, fib-786
;; Predicates:   above, below, touches

;; ── Fib levels ─────────────────────────────────────────────────
;;
;; Standard Fibonacci ratios applied to the viewport's swing range:
;;   level = swing_low + range * ratio
;;
;; Ratios: 0.236, 0.382, 0.500, 0.618, 0.786
;; These are the standard retracement set. Not tuned.

;; ── Facts produced ─────────────────────────────────────────────

(define (eval-fibonacci candles)
  "Fibonacci proximity facts. Returns Some(Vec<Fact>) or None if < 10 candles."

  ;; For each fib level:
  ;;   Comparison: (touches close fib-NNN) when |close - level| < 0.5 * ATR
  ;;   Comparison: (above close fib-NNN) or (below close fib-NNN)
  ;;
  ;; Touch threshold: 0.5 * ATR.
  ;;   Scales with volatility. 0.5 is tight — half an ATR.
  ;;   ATR = atr_r * close (relative ATR converted to absolute).
  ;;
  ;; Returns None if swing range < 1e-10 (degenerate window).

  (for-each (lambda (name ratio)
    (let ((level (+ swing-low (* range ratio))))
      ;; Proximity check — touches
      (when (< (abs (- close level)) (* atr 0.5))
        (fact/comparison "touches" "close" name))
      ;; Position — above or below
      (fact/comparison (if (> close level) "above" "below") "close" name)))

    [("fib-236" 0.236) ("fib-382" 0.382) ("fib-500" 0.500)
     ("fib-618" 0.618) ("fib-786" 0.786)]))

;; ── Minimum: 10 candles ────────────────────────────────────────
;; Need enough range for fib levels to be meaningful.

;; ── What fibonacci does NOT do ─────────────────────────────────
;; - Does NOT pre-compute levels (they depend on the expert's window)
;; - Does NOT detect swings explicitly (uses window min/max)
;; - Does NOT emit scalars (proximity is binary: touches or positional)
;; - Does NOT import holon or create vectors
;; - Pure function. Candles in, facts out.
