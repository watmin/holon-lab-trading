;; ── exit expert ────────────────────────────────────────────────────
;;
;; Thinks about: open positions. Should this position hold, tighten, or exit?
;; Vocabulary: position state (P&L, hold duration, ATR at entry, MFE, MAE,
;;             phase, trailing stop distance from current price).
;; Label: did holding longer result in better or worse outcome?
;;
;; The exit expert is NOT a market expert. It doesn't see candles or
;; indicators. It sees the POSITION'S state and learns when to act.
;;
;; Template 1 (PREDICTION): "will this position improve or deteriorate?"
;; The discriminant separates position states that precede improvement
;; from those that precede deterioration.

;; ── Atoms ───────────────────────────────────────────────────────────

(atom "position-pnl")          ; current unrealized P&L as fraction
(atom "position-hold")         ; candles held (encode-log — orders of magnitude)
(atom "position-mfe")          ; max favorable excursion so far
(atom "position-mae")          ; max adverse excursion so far
(atom "position-atr-entry")    ; ATR at entry (market volatility when entered)
(atom "position-atr-now")      ; ATR right now (has volatility changed?)
(atom "position-stop-dist")    ; distance from current price to trailing stop
(atom "position-phase")        ; active | runner
(atom "position-direction")    ; buy | sell

;; ── Encoding ────────────────────────────────────────────────────────
;;
;; Each open position encodes its state as a thought vector:

(define (encode-position pos current-price current-atr)
  (bundle
    (bind position-pnl (encode-linear (return-pct pos current-price) 1.0))
    (bind position-hold (encode-log (candles-held pos)))
    (bind position-mfe (encode-linear (/ (- (high-water pos) (entry-price pos))
                                         (entry-price pos)) 1.0))
    (bind position-mae (encode-linear (max-adverse pos) 1.0))
    (bind position-atr-entry (encode-log (entry-atr pos)))
    (bind position-atr-now (encode-log current-atr))
    (bind position-stop-dist (encode-linear
      (/ (abs (- current-price (trailing-stop pos))) current-price) 1.0))
    (bind position-phase (atom (if (runner? pos) "runner" "active")))
    (bind position-direction (atom (if (buy? pos) "buy" "sell")))))

;; ── Learning ────────────────────────────────────────────────────────
;;
;; Every N candles while a position is open, the exit expert encodes
;; the position state and predicts: "will this position be worth MORE
;; or LESS in N candles?"
;;
;; Labels (symbols, not the old Outcome enum):
;;   (define hold (register exit-journal "Hold"))
;;   (define exit (register exit-journal "Exit"))
;;
;; After N candles:
;;   Hold = the position improved (holding was correct)
;;   Exit = the position deteriorated (should have exited)
;;
;; The exit expert's discriminant learns which position states precede
;; improvement vs deterioration.

;; ── Application ─────────────────────────────────────────────────────
;;
;; On each candle, for each open position:
;;   1. Encode position state
;;   2. Exit expert predicts: Hold or Exit
;;   3. If Exit with conviction above threshold:
;;      - Active position: force close (don't wait for stop)
;;      - Runner: tighten the trail (reduce k_trail for this position)
;;   4. If Hold with high conviction:
;;      - Runner: loosen the trail (increase k_trail, let it breathe)
;;
;; The exit expert modulates the TRAIL DISTANCE per position per candle.
;; It doesn't override the stop — it adjusts how tight the stop follows.
;; Tight = aggressive profit taking. Loose = let runners run.

;; ── Gate ─────────────────────────────────────────────────────────────
;;
;; The exit expert must prove itself before modulating trails.
;; Proof: its Hold predictions are correct >52% of the time
;; (positions that it said Hold did indeed improve).
;; Before proof: positions use the default k_trail (1.5 × ATR).

;; ── What the exit expert does NOT do ────────────────────────────────
;;
;; - Does NOT decide entry (that's the market manager)
;; - Does NOT see market indicators (that's the market experts)
;; - Does NOT know about other positions (that's the risk manager)
;; - Does NOT override the stop loss (the stop is the safety net)
;; - It adjusts the TRAIL, not the stop
