;; ── treasury.wat — the root of the enterprise ──────────────────────
;;
;; Pure accounting. Does not think. Does not predict.
;; Counts. Swaps. Records. Measures alpha.

(require core/structural)

;; ── State ───────────────────────────────────────────────────────────

(struct treasury
  balances            ; (map asset amount) — available to deploy
  deployed            ; (map asset amount) — claimed by open positions
  n-open              ; active position count
  max-positions       ; capacity limit
  max-utilization     ; max fraction of base asset deployed
  total-fees-paid     ; cumulative venue costs
  total-slippage      ; cumulative slippage costs
  base-asset)         ; quote currency for P&L (e.g. "USDC")

;; ── Operations ──────────────────────────────────────────────────────

;; (define (swap treasury from to amount price fee-rate)
;;   "Convert between assets. Updates balances, records fee."
;;   → (from-spent to-received))

;; (define (claim treasury asset amount)
;;   "Move available → deployed. Position owns it."
;;   (update treasury :balances  (- (:balances treasury asset) amount))
;;   (update treasury :deployed  (+ (:deployed treasury asset) amount)))

;; (define (release treasury asset amount)
;;   "Move deployed → available. Position done."
;;   (update treasury :deployed  (- (:deployed treasury asset) amount))
;;   (update treasury :balances  (+ (:balances treasury asset) amount)))

;; (define (allocatable treasury)
;;   "How much base asset can be deployed to a new position?"
;;   (if (>= (:n-open treasury) (:max-positions treasury))
;;       0.0
;;       (max 0.0 (- (* (total (:base-asset treasury)) (:max-utilization treasury))
;;                    (:deployed treasury (:base-asset treasury))))))

;; (define (total-value treasury prices)
;;   "Sum of all assets at current prices."
;;   (apply + (map (lambda (asset) (* (+ (balance asset) (deployed asset))
;;                                    (price-of asset prices)))
;;                 (keys (:balances treasury)))))

;; ── Execution gate ──────────────────────────────────────────────────
;;
;; The treasury's filter is the enterprise's final gate:
;; (and (band-valid?)
;;      (conviction-in-band?)
;;      (risk-allows?)
;;      (market-moved-since-exit?))

;; ── Portfolio seeding ───────────────────────────────────────────────
;;
;; rune:scry(stale-spec) — originally specified 50/50 split between base
;; and quote asset. Implementation seeds 100% in base asset (USDC).
;; The enterprise starts fully in cash and builds exposure through trading.

;; ── What the treasury does NOT do ───────────────────────────────────
;; - Does NOT predict direction (that's the manager)
;; - Does NOT assess risk (that's the risk branch)
;; - Does NOT manage positions (that's the position lifecycle)
;; - Does NOT decide WHEN to trade (that's the band + filter)
;; - It executes. It counts.
