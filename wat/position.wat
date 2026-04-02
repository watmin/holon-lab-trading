;; ── position.wat — managed allocations from the treasury ────────────
;;
;; A position is a swap: source token → target token at a rate.
;; The position manages the target token with stops and take-profits.
;; Entry → Management → Partial exit → Runner → Final exit.
;;
;; Token-to-token. Long or Short is the reason, not the mechanism.
;; The struct speaks source/target, not base/quote.

(require core/primitives)
(require core/structural)
(require treasury)

;; ── Types ───────────────────────────────────────────────────────────

;; A position tracks a specific swap: I sold X of source, received Y of target.
;; The lifecycle operates on the exchange rate. One formula, both directions.
(struct managed-position
  id entry-candle
  source-asset              ; Asset — what we sold (e.g. USDC for a Buy, WBTC for a Sell)
  target-asset              ; Asset — what we received (e.g. WBTC for a Buy, USDC for a Sell)
  source-amount             ; units of source spent (claimed from treasury)
  target-held               ; units of target currently held in this position
  source-reclaimed          ; units of source recovered from partial exits
  entry-rate                ; exchange rate at entry: source/target (e.g. 87000 USDC per WBTC)
  entry-atr                 ; ATR at entry — scales stop/TP in rate space
  ;; Management
  phase                     ; :active | :runner | :closed
  trailing-stop             ; absolute rate level
  take-profit               ; absolute rate level (first target)
  extreme-rate              ; best rate in our favor (tracked per tick)
  ;; Accounting
  max-adverse               ; worst return against us (negative fraction)
  total-fees                ; cumulative fees paid (in source units)
  candles-held)             ; how long this position has been open

;; extreme-rate: the most favorable rate seen since entry.
;; For a Buy (USDC→WBTC): rate = USDC/WBTC. Price going UP means rate going UP.
;;   extreme-rate tracks the highest rate. Stop is below. TP is above.
;; For a Sell (WBTC→USDC): rate = WBTC/USDC = 1/price. Price going DOWN means rate going UP.
;;   extreme-rate tracks the highest rate. Stop is below. TP is above.
;; The TRICK: by defining rate as source/target, both directions have the same
;; stop/TP logic. Rate going up is always good. Stop is always below extreme.

;; phase: :active | :runner | :closed

(struct pending
  candle-idx tht-vec
  tht-pred meta-dir meta-conviction
  position-frac observer-vecs observer-preds mgr-thought fact-labels
  crossing                  ; CrossingSnapshot or absent
  entry-price entry-ts entry-atr
  max-favorable max-adverse
  exit-reason exit-pct
  deployed-usd)

;; exit-reason: :trailing-stop | :take-profit | :horizon-expiry

(struct crossing-snapshot
  label pct candles ts price)

(struct exit-observation
  thought pos-id snapshot-pnl snapshot-candle)

;; ── Construction ────────────────────────────────────────────────────

(struct position-entry
  id candle-idx
  source-asset target-asset
  source-amount target-received
  entry-rate entry-atr entry-fee
  k-stop k-tp)

(define (new-position entry)
  "Create a managed position from a swap.
   Stop and TP are in rate space. Rate going up = profit for ALL positions.
   No match on direction. One formula."
  (let ((rate (:entry-rate entry))
        (atr  (:entry-atr entry))
        (stop (* rate (- 1.0 (* (:k-stop entry) atr))))
        (tp   (* rate (+ 1.0 (* (:k-tp entry) atr)))))
    (managed-position
      :id (:id entry) :entry-candle (:candle-idx entry)
      :source-asset (:source-asset entry)
      :target-asset (:target-asset entry)
      :source-amount (:source-amount entry)
      :target-held (:target-received entry)
      :source-reclaimed 0.0
      :entry-rate rate :entry-atr atr
      :phase :active
      :trailing-stop stop :take-profit tp
      :extreme-rate rate
      :max-adverse 0.0
      :total-fees (:entry-fee entry) :candles-held 0)))

;; ── Tick ────────────────────────────────────────────────────────────

;; k-trail: ATR multiplier for trailing stop distance.
;; In Rust, TrailFactor newtype prevents passing a price where a multiplier belongs.
(define (tick pos current-rate k-trail)
  "Update position with current rate. Returns :stop-loss | :take-profit | absent.
   Rate = source/target. Rate going up is always good.
   One formula for all directions."
  (when (!= (:phase pos) :closed)
    ;; Track worst excursion
    (let ((ret (return-pct pos current-rate)))
      (when (< ret (:max-adverse pos))
        (set! (:max-adverse pos) ret)))
    ;; Rate going up = profit. Track extreme. Trail stop upward.
    (let ((extreme (max (:extreme-rate pos) current-rate))
          (new-stop (* extreme (- 1.0 (* k-trail (:entry-atr pos))))))
      (let ((stop (max (:trailing-stop pos) new-stop)))
        (set! (:extreme-rate pos) extreme)
        (set! (:trailing-stop pos) stop)
        (cond ((<= current-rate stop) :stop-loss)
              ((and (= (:phase pos) :active) (>= current-rate (:take-profit pos)))
               :take-profit))))))

;; ── P&L ─────────────────────────────────────────────────────────────

(define (return-pct pos current-rate)
  "Current return as fraction of source deployed.
   One formula: (target-value-in-source + reclaimed - fees) / source-amount - 1.
   No match on direction."
  (if (<= (:source-amount pos) 0.0) 0.0
    (let ((target-value (* (:target-held pos) (/ 1.0 current-rate))))
      ;; target-value converts held target back to source units at current rate
      ;; wait — rate is source/target, so target→source = target * rate? No.
      ;; rate = source_per_target. 1 target = rate source units.
      ;; So target-value = target-held * rate (not 1/rate).
      ;; Example: rate=87000 USDC/WBTC. 0.01 WBTC = 870 USDC.
      (let ((target-in-source (* (:target-held pos) current-rate)))
        (- (/ (+ target-in-source (:source-reclaimed pos) (- (:total-fees pos)))
              (:source-amount pos))
           1.0)))))

;; ── Sizing ──────────────────────────────────────────────────────────

(define (position-size band-edge risk-mult max-single-position)
  "Half-Kelly, modulated by risk, capped at max-single-position."
  (min (* (/ band-edge 2.0) risk-mult)
       max-single-position))

;; ── Cooldown ────────────────────────────────────────────────────────

(define (market-moved? current-rate last-exit-rate last-exit-atr k-stop)
  "Has the rate moved enough since the last exit to justify re-entry?"
  (or (= last-exit-rate 0)
      (> (/ (abs (- current-rate last-exit-rate)) last-exit-rate)
         (* k-stop last-exit-atr))))

;; ── What positions do NOT do ────────────────────────────────────────
;; - Do NOT decide entry (that's the desk manager + treasury)
;; - Do NOT assess portfolio risk (that's the risk branch)
;; - Do NOT record themselves (that's the ledger)
;; - Each position is independent. Aggregate exposure is risk's concern.
