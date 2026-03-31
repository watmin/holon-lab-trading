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
  phase trailing-stop take-profit best-price
  total-fees candles-held)

;; best-price: the most favorable price seen since entry.
;; For longs: the highest price. For shorts: the lowest price.

;; phase:     :active | :runner | :closed
;; direction: :long | :short

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

;; exit-reason: :trailing-stop | :take-profit | :horizon-expiry

(struct exit-observation
  thought pos-id snapshot-pnl snapshot-candle)

;; ── Construction ────────────────────────────────────────────────────

;; rune:forge(bare-type) — 10 parameters, 7 are bare f64 with different
;; semantics. Swapping entry-price with entry-atr compiles silently.
(define (new-position id candle-idx entry-price entry-atr direction
                      base-deployed quote-received entry-fee k-stop k-tp)
  "BUY: stop below entry, TP above. SELL: inverted."
  (let ((stop (match direction
                :long  (* entry-price (- 1.0 (* k-stop entry-atr)))
                :short (* entry-price (+ 1.0 (* k-stop entry-atr)))))
        (tp   (match direction
                :long  (* entry-price (+ 1.0 (* k-tp entry-atr)))
                :short (* entry-price (- 1.0 (* k-tp entry-atr))))))
    (managed-position
      :id id :entry-candle candle-idx
      :entry-price entry-price :entry-atr entry-atr
      :direction direction
      :base-deployed base-deployed
      :quote-held quote-received
      :base-reclaimed 0.0
      :phase :active
      :trailing-stop stop :take-profit tp
      :best-price entry-price
      :total-fees entry-fee :candles-held 0)))

;; ── Tick ────────────────────────────────────────────────────────────

;; rune:forge(bare-type) — k-trail is bare f64; a TrailFactor newtype
;; would prevent passing a price where a multiplier is expected.
(define (tick pos current-price k-trail)
  "Update position with current price. Returns :stop-loss | :take-profit | nothing."
  (if (= (:phase pos) :closed) nothing
    (match (:direction pos)
      :long
        (let ((best-price (max (:best-price pos) current-price))
              (new-stop   (* best-price (- 1.0 (* k-trail (:entry-atr pos))))))
          (let ((trailing-stop (max (:trailing-stop pos) new-stop)))
            (if (<= current-price trailing-stop) :stop-loss
              (if (and (= (:phase pos) :active) (>= current-price (:take-profit pos)))
                  :take-profit
                  nothing))))
      :short
        (let ((best-price (min (:best-price pos) current-price))
              (new-stop   (* best-price (+ 1.0 (* k-trail (:entry-atr pos))))))
          (let ((trailing-stop (min (:trailing-stop pos) new-stop)))
            (if (>= current-price trailing-stop) :stop-loss
              (if (and (= (:phase pos) :active) (<= current-price (:take-profit pos)))
                  :take-profit
                  nothing)))))))

;; ── P&L ─────────────────────────────────────────────────────────────

(define (return-pct pos current-price)
  "Current return as fraction of deployed capital."
  (if (<= (:base-deployed pos) 0.0) 0.0
    (match (:direction pos)
      :long
        (let ((value (+ (* (:quote-held pos) current-price) (:base-reclaimed pos))))
          (- (/ (- value (:total-fees pos)) (:base-deployed pos)) 1.0))
      :short
        (- (/ (- (:entry-price pos) current-price) (:entry-price pos))
           (/ (:total-fees pos) (:base-deployed pos))))))

;; ── Sizing ──────────────────────────────────────────────────────────

(define (position-size band-edge risk-mult max-single-position)
  "Half-Kelly, modulated by risk, capped at max-single-position."
  (min (* (/ band-edge 2.0) risk-mult)
       max-single-position))

;; ── Cooldown ────────────────────────────────────────────────────────

(define (market-moved? current-price last-exit-price last-exit-atr k-stop)
  "Has the market moved enough since the last exit to justify re-entry?
   Price difference normalized by last-exit-price (percentage move)."
  (or (= last-exit-price 0)
      (> (/ (abs (- current-price last-exit-price)) last-exit-price)
         (* k-stop last-exit-atr))))

;; ── What positions do NOT do ────────────────────────────────────────
;; - Do NOT decide entry (that's the manager + treasury)
;; - Do NOT assess portfolio risk (that's the risk branch)
;; - Do NOT record themselves (that's the ledger)
;; - Each position is independent. Aggregate exposure is risk's concern.
