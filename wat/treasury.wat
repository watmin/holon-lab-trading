;; ── treasury.wat — the root of the enterprise ──────────────────────
;;
;; Pure accounting. Does not think. Does not predict.
;; Counts. Swaps. Records.

(require core/primitives)
(require core/structural)

;; ── State ───────────────────────────────────────────────────────────

(struct treasury
  balances            ; (map asset amount) — available to deploy
  deployed            ; (map asset amount) — claimed by open positions
  n-open              ; active position count
  max-positions
  max-utilization     ; max fraction of base asset deployed
  total-fees-paid
  total-slippage
  base-asset)         ; unit of account (e.g. "USDC")

;; ── Queries ─────────────────────────────────────────────────────────

(define (balance treasury asset)
  (get (:balances treasury) asset 0.0))

(define (deployed treasury asset)
  (get (:deployed treasury) asset 0.0))

(define (total treasury asset)
  (+ (balance treasury asset) (deployed treasury asset)))

(define (utilization treasury)
  (let ((total-base (total treasury (:base-asset treasury))))
    (if (<= total-base 0.0) 0.0
        (/ (deployed treasury (:base-asset treasury)) total-base))))

(define (allocatable treasury)
  (if (>= (:n-open treasury) (:max-positions treasury))
      0.0
      (let ((total-base (total treasury (:base-asset treasury)))
            (max-deploy (* total-base (:max-utilization treasury)))
            (deployed-base (deployed treasury (:base-asset treasury))))
        (min (max 0.0 (- max-deploy deployed-base))
             (balance treasury (:base-asset treasury))))))

(define (total-value treasury prices)
  "Sum all assets at current prices. Base asset = 1.0."
  (fold (lambda (sum asset)
          (+ sum (* (total treasury asset)
                    (get prices asset 1.0))))
        0.0
        (keys (:balances treasury))))

(define (price-map treasury asset-prices)
  "Build prices from (asset, price) pairs. Base asset always 1.0."
  (fold (lambda (prices pair)
          (assoc prices (first pair) (second pair)))
        {(:base-asset treasury) 1.0}
        asset-prices))

;; ── Mutations ───────────────────────────────────────────────────────

(define (deposit treasury asset amount)
  (update treasury :balances
    (assoc (:balances treasury) asset
           (+ (balance treasury asset) amount))))

(define (withdraw treasury asset amount)
  "Withdraw from available balance. Returns (treasury, actual-withdrawn).
   Cannot withdraw more than available. Cannot touch deployed."
  (let ((available (balance treasury asset))
        (actual    (min amount available)))
    (list (update treasury :balances
            (assoc (:balances treasury) asset (- available actual)))
          actual)))

(define (swap treasury from to amount-from price fee-rate)
  "Sell `from`, buy `to` at `price`, minus fees. Returns (treasury, spent, received)."
  (let ((spend     (min amount-from (balance treasury from)))
        (after-fee (* spend (- 1.0 fee-rate)))
        (received  (/ after-fee price))
        (fee       (* spend fee-rate)))
    (list
      (update treasury
        :balances        (assoc (:balances treasury)
                           from (- (balance treasury from) spend)
                           to   (+ (balance treasury to) received))
        :total-fees-paid (+ (:total-fees-paid treasury) fee))
      spend received)))

(define (claim treasury asset amount)
  "Move available → deployed. Returns (treasury, claimed)."
  (let ((claimed (min amount (balance treasury asset))))
    (list
      (update treasury
        :balances (assoc (:balances treasury) asset (- (balance treasury asset) claimed))
        :deployed (assoc (:deployed treasury) asset (+ (get (:deployed treasury) asset 0.0) claimed))
        :n-open   (+ (:n-open treasury) 1))
      claimed)))

(define (release treasury asset amount)
  "Move deployed → available. Returns treasury."
  (let ((released (min amount (get (:deployed treasury) asset 0.0))))
    (update treasury
      :deployed (assoc (:deployed treasury) asset (- (get (:deployed treasury) asset 0.0) released))
      :balances (assoc (:balances treasury) asset (+ (balance treasury asset) released))
      :n-open   (max 0 (- (:n-open treasury) 1)))))

(define (open-position treasury amount)
  "Reserve base asset. Returns (treasury, reserved)."
  (let ((reserved (min amount (allocatable treasury)))
        (base     (:base-asset treasury)))
    (list
      (update treasury
        :balances (assoc (:balances treasury) base (- (balance treasury base) reserved))
        :deployed (assoc (:deployed treasury) base (+ (get (:deployed treasury) base 0.0) reserved))
        :n-open   (+ (:n-open treasury) 1))
      reserved)))

(define (close-position treasury deployed-amount pnl fees slippage)
  "Close position. Return capital ± P&L. Returns treasury."
  (let ((returned (max 0.0 (- (+ deployed-amount pnl) fees slippage)))
        (base     (:base-asset treasury)))
    (update treasury
      :deployed        (assoc (:deployed treasury) base
                              (max 0.0 (- (get (:deployed treasury) base 0.0) deployed-amount)))
      :balances        (assoc (:balances treasury) base (+ (balance treasury base) returned))
      :n-open          (max 0 (- (:n-open treasury) 1))
      :total-fees-paid (+ (:total-fees-paid treasury) fees))))

;; ── Execution gate ──────────────────────────────────────────────────
;;
;; The treasury's final gate before acting (all 8 must hold):
;; (and (= asset-mode "hold")                          ; 1. hold mode
;;      (!= (phase portfolio) :observe)                ; 2. past observe period
;;      (curve-valid? manager)                         ; 3. conviction-accuracy curve exists
;;      (in-proven-band? meta-conviction)              ; 4. conviction in proven band
;;      (market-moved-since-exit?)                     ; 5. cooldown satisfied
;;      (risk-allows?)                                 ; 6. cached-risk-mult > 0.3
;;      (or (= meta-dir :buy) (= meta-dir :sell))     ; 7. manager has a directional opinion
;;      (> expected-move (* 2.0 fee-rate)))            ; 8. profitability gate

;; rune:scry(aspirational) — alpha tracking not yet implemented.
;; Snapshot before each swap, compare actual vs counterfactual inaction.

;; ── What the treasury does NOT do ───────────────────────────────────
;; - Does NOT predict direction (that's the manager)
;; - Does NOT assess risk (that's the risk branch)
;; - Does NOT manage positions (that's the position lifecycle)
;; - Does NOT decide WHEN to trade (that's the band + filter)
;; - It executes. It counts.
