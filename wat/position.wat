;; ── position.wat — managed allocations from the treasury ────────────
;;
;; A position is a fraction of capital with its own lifecycle.
;; Entry → Management → Partial exit → Runner → Final exit.

(require core/primitives)
(require core/structural)

;; ── Types ───────────────────────────────────────────────────────────

(struct managed-position
  id entry-candle entry-price entry-atr direction
  base-deployed quote-held base-reclaimed
  phase trailing-stop take-profit high-water
  total-fees candles-held)

;; phase: Active | Runner | Closed
;; direction: Long | Short (from journal Direction)

(struct pending
  candle-idx year tht-vec
  tht-pred meta-dir high-conviction meta-conviction
  position-frac observer-vecs observer-preds mgr-thought fact-labels
  first-outcome outcome-pct
  entry-price entry-ts entry-atr
  max-favorable max-adverse
  crossing-candles crossing-ts crossing-price path-candles
  trailing-stop exit-reason exit-pct
  deployed-usd)

(struct exit-observation
  thought pos-id snapshot-pnl snapshot-candle)

;; ── Lifecycle ───────────────────────────────────────────────────────
;;
;; 1. ENTRY: manager says direction with conviction in proven band.
;;    (let ((amount (* (allocatable treasury) kelly-fraction)))
;;      (claim treasury (:base-asset treasury) amount)
;;      (swap treasury "USDC" "WBTC" amount price fee-rate))
;;
;; 2. MANAGEMENT (every candle):
;;    (let ((trail-dist (* k-trail (:entry-atr pos))))
;;      (update pos :trailing-stop (max (:trailing-stop pos)
;;                                      (- (price candle) trail-dist)))
;;      (update pos :high-water    (max (:high-water pos) (price candle)))
;;      (update pos :candles-held  (+ (:candles-held pos) 1)))
;;
;; 3. PARTIAL EXIT (first target hit):
;;    Sell enough WBTC to reclaim: entry USDC + fees + min-profit.
;;    Remaining = house money. Free ride.
;;    (update pos :phase :runner)
;;
;; 4. RUNNER: only trailing stop manages. Can ride indefinitely.
;;
;; 5. FINAL EXIT: trailing stop hit.
;;    (release treasury "WBTC" (:quote-held pos))
;;    (swap treasury "WBTC" "USDC" (:quote-held pos) price fee-rate)

;; ── Sizing ──────────────────────────────────────────────────────────
;;
;; (define (position-size band-edge risk-mult)
;;   "Half-Kelly, modulated by risk."
;;   (* (/ band-edge 2.0) risk-mult))
;;
;; Bounded by: max-single-position, risk gate, fee gate.
;; Fee gate: (> (expected-move atr horizon) (* 2 swap-fee))

;; ── Cooldown ────────────────────────────────────────────────────────
;;
;; After exit, wait for market movement before re-entering:
;; (> (abs (- (price candle) last-exit-price))
;;    (* k-stop last-exit-atr))
;;
;; The market must move one stop-loss worth of ATR. Market-driven,
;; not timer-driven. Prevents oscillation.

;; ── What positions do NOT do ────────────────────────────────────────
;; - Do NOT decide entry (that's the manager + treasury)
;; - Do NOT assess portfolio risk (that's the risk branch)
;; - Do NOT record themselves (that's the ledger)
;; - Each position is independent. Aggregate exposure is risk's concern.
