;; ── observer ────────────────────────────────────────────────────
;;
;; Thinks about: open positions. Should this position hold or exit?
;; Not a market observer. Sees position state, not candles or indicators.
;; Template 1 (PREDICTION): learns which position states precede
;; improvement vs deterioration.

(require core/primitives)
(require core/structural)
(require common)
(require patterns)

;; ── Encoding ────────────────────────────────────────────────────────

;; rune:scry(aspirational) — position-mae declared below but not yet
;; encoded in the Rust. The data exists on Pending.max_adverse.
(define (return-pct pos current-price)
  "Signed return of a position: (current - entry) / entry.
   Positive when price moved in the position's favor."
  (/ (- current-price (:entry-price pos)) (:entry-price pos)))

(define (encode-position pos current-price current-atr)
  (bundle
    (bind (atom "position-pnl")       (encode-linear (return-pct pos current-price) 1.0))
    (bind (atom "position-hold")      (encode-log (:candles-held pos)))
    (bind (atom "position-mfe")       (encode-linear
      (/ (- (:high-water pos) (:entry-price pos)) (:entry-price pos)) 1.0))
    (bind (atom "position-mae")       (encode-linear (:max-adverse pos) 1.0))
    (bind (atom "position-atr-entry") (encode-log (:entry-atr pos)))
    (bind (atom "position-atr-now")   (encode-log current-atr))
    (bind (atom "position-stop-dist") (encode-linear
      (/ (abs (- current-price (:trailing-stop pos))) current-price) 1.0))
    (bind (atom "position-phase")     (if (= (:phase pos) :runner) (atom "runner") (atom "active")))
    (bind (atom "position-direction") (if (= (:direction pos) :long) (atom "buy") (atom "sell")))))

;; ── Journal ─────────────────────────────────────────────────────────

(define exit-journal (journal "exit" dims refit-interval))
(define hold-label   (register exit-journal "Hold"))
(define exit-label   (register exit-journal "Exit"))

;; ── Learning ────────────────────────────────────────────────────────
;;
;; Every exit-observe-interval candles while a position is open:
;;   1. Encode position state → thought vector
;;   2. Record snapshot P&L
;;   After exit-observe-interval more candles:
;;     Hold = position improved (holding was correct)
;;     Exit = position deteriorated (should have exited)

(define (resolve-exit-observation obs pos)
  (let ((improved (> (return-pct pos (current-price)) (:snapshot-pnl obs))))
    (observe exit-journal (:thought obs)
      (if improved hold-label exit-label)
      1.0)))

;; ── Application ─────────────────────────────────────────────────────
;;
;; rune:scry(aspirational) — exit observer learns but does not yet predict.
;; When wired, prediction modulates trailing stop per position:
;;   Exit with conviction → tighten trail
;;   Hold with conviction → loosen trail

;; ── observer does NOT do ────────────────────────────────
;; - Does NOT decide entry (that's the manager)
;; - Does NOT see market indicators (that's the market experts)
;; - Does NOT know about other positions (that's risk)
;; - Does NOT override the stop loss (the stop is the safety net)
;; - Adjusts the TRAIL, not the stop
