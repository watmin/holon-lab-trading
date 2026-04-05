;; ── exit observer ────────────────────────────────────────────────
;;
;; Thinks about: open positions. Should this position hold or exit?
;; Not a market observer. Sees position state, not candles or indicators.
;; Template 1 (PREDICTION): learns which position states precede
;; improvement vs deterioration.

(require core/primitives)
(require core/structural)
(require position)

;; ── Encoding ────────────────────────────────────────────────────────
;; Nine facts about a position's current state.
;; Uses source/target rate — no match on direction.
;; return-pct comes from position.wat (one definition, one formula).

;; All linear-encoded facts are clamped to [0,1] before encoding.
;; PNL is shifted: clamp(-1,1) * 0.5 + 0.5 → [0,1].
;; MAE is clamped to [-1,0] then abs → [0,1].
(define (encode-position pos pnl-frac current-rate current-atr is-buy)
  "Encode position state for the exit observer.
   pnl-frac: pre-computed return (from position.wat return-pct).
   current-rate: source/target exchange rate.
   is-buy: for direction atom (the one place we need it)."
  (let ((mfe-frac   (/ (- (:extreme-rate pos) (:entry-rate pos)) (:entry-rate pos)))
        (stop-dist  (/ (abs (- (:trailing-stop pos) current-rate)) current-rate)))
    (bundle
      (bind (atom "position-pnl")       (encode-linear (+ (* (clamp pnl-frac -1.0 1.0) 0.5) 0.5) 1.0))
      (bind (atom "position-hold")      (encode-log (:candles-held pos)))
      (bind (atom "position-mfe")       (encode-linear (clamp mfe-frac 0.0 1.0) 1.0))
      (bind (atom "position-mae")       (encode-linear (abs (clamp (:max-adverse pos) -1.0 0.0)) 1.0))
      (bind (atom "position-atr-entry") (encode-log (:entry-atr pos)))
      (bind (atom "position-atr-now")   (encode-log current-atr))
      (bind (atom "position-stop-dist") (encode-linear (clamp stop-dist 0.0 1.0) 1.0))
      (bind (atom "position-phase")     (if (= (:phase pos) :runner) (atom "runner") (atom "active")))
      (bind (atom "position-direction") (if is-buy (atom "buy") (atom "sell"))))))

;; ── Learning ────────────────────────────────────────────────────────
;;
;; Every exit-observe-interval candles while a position is open:
;;   1. Encode position state → thought vector (via encode-position above)
;;   2. Record snapshot P&L
;;   After exit-observe-interval more candles:
;;     Hold = position improved (holding was correct)
;;     Exit = position deteriorated (should have exited)

;; rune:scry(aspirational) — exit observer learns but does not yet predict.
;; When wired, prediction modulates trailing stop per position:
;;   Exit with conviction → tighten trail
;;   Hold with conviction → loosen trail

;; ── exit observer does NOT do ────────────────────────────────
;; - Does NOT decide entry (that's the manager)
;; - Does NOT see market indicators (that's the market observers)
;; - Does NOT know about other positions (that's risk)
;; - Does NOT override the stop loss (the stop is the safety net)
;; - Does NOT define return-pct (that's position.wat — one formula)
;; - Adjusts the TRAIL, not the stop
