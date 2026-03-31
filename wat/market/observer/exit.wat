;; ── exit expert ────────────────────────────────────────────────────
;;
;; Thinks about: open positions. Should this position hold or exit?
;; Not a market expert. Sees position state, not candles or indicators.
;; Template 1 (PREDICTION): learns which position states precede
;; improvement vs deterioration.

(require core/primitives)
(require core/structural)
(require std/common)
(require std/patterns)

;; ── Vocabulary ──────────────────────────────────────────────────────
;;
;; Position state encoding (one thought per open position per sample):
;;
;; (define (encode-position pos current-price current-atr)
;;   (bundle
;;     (bind (atom "position-pnl")       (encode-linear (return-pct pos current-price) 1.0))
;;     (bind (atom "position-hold")      (encode-log (candles-held pos)))
;;     (bind (atom "position-mfe")       (encode-linear (/ (- (high-water pos) (entry-price pos))
;;                                                         (entry-price pos)) 1.0))
;;     (bind (atom "position-mae")       (encode-linear (max-adverse pos) 1.0))
;;     (bind (atom "position-atr-entry") (encode-log (entry-atr pos)))
;;     (bind (atom "position-atr-now")   (encode-log current-atr))
;;     (bind (atom "position-stop-dist") (encode-linear
;;       (/ (abs (- current-price (trailing-stop pos))) current-price) 1.0))
;;     (bind (atom "position-phase")     (atom (if (runner? pos) "runner" "active")))
;;     (bind (atom "position-direction") (atom (if (buy? pos) "buy" "sell")))))

;; ── Labels ──────────────────────────────────────────────────────────

(define exit-journal (journal "exit" dims refit-interval))
(define hold-label   (register exit-journal "Hold"))
(define exit-label   (register exit-journal "Exit"))

;; ── Learning ────────────────────────────────────────────────────────
;;
;; Every exit-observe-interval candles while a position is open:
;;   1. Encode position state → thought
;;   2. Record snapshot P&L
;;   After exit-observe-interval more candles:
;;     Hold = position improved (holding was correct)
;;     Exit = position deteriorated (should have exited)
;;
;; (observe exit-journal thought
;;   (if (> (pnl-at-resolution) (pnl-at-snapshot)) hold-label exit-label)
;;   1.0)

;; ── Application ─────────────────────────────────────────────────────
;;
;; On each candle, for each open position:
;;   (let ((prediction (predict exit-journal (encode-position pos price atr))))
;;     (match (:direction prediction)
;;       Exit  → (if (runner? pos) (tighten-trail pos) (force-close pos))
;;       Hold  → (if (runner? pos) (loosen-trail pos)  (noop))))
;;
;; Tight trail = aggressive profit taking. Loose trail = let runners run.

;; ── Gate ────────────────────────────────────────────────────────────
;;
;; Before proof: positions use default k-trail.
;; Proof: Hold predictions correct > 52% of the time.
;; (gate (opinion prediction exit-atom) exit-atom (curve-valid? exit-journal))

;; ── What the exit expert does NOT do ────────────────────────────────
;; - Does NOT decide entry (that's the manager)
;; - Does NOT see market indicators (that's the market experts)
;; - Does NOT know about other positions (that's risk)
;; - Does NOT override the stop loss (the stop is the safety net)
;; - Adjusts the TRAIL, not the stop
