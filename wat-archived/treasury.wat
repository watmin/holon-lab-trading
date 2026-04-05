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
  max-positions
  max-utilization     ; max fraction of total portfolio deployed
  total-fees-paid
  total-slippage)

;; ── Queries ─────────────────────────────────────────────────────────

(define (balance treasury asset)
  (get (:balances treasury) asset 0.0))

(define (deployed treasury asset)
  (get (:deployed treasury) asset 0.0))

(define (total treasury asset)
  (+ (balance treasury asset) (deployed treasury asset)))

(define (utilization treasury prices)
  "Portfolio utilization: fraction of total value currently deployed."
  (let ((total (total-value treasury prices)))
    (if (<= total 0.0) 0.0
        (/ (deployed-value treasury prices) total))))

(define (allocatable treasury asset prices n-open)
  "How many units of asset can be deployed? Uses portfolio-wide utilization.
   n-open is passed in — position counting is the enterprise's concern."
  (if (>= n-open (:max-positions treasury))
      0.0
      (let* ((portfolio-value (total-value treasury prices))
             (total-deployed  (deployed-value treasury prices))
             (deploy-room     (max 0.0 (- (* portfolio-value (:max-utilization treasury))
                                           total-deployed)))
             (asset-price     (get prices asset 1.0))
             (max-units       (/ deploy-room asset-price)))
        (min max-units (balance treasury asset)))))

(define (total-value treasury prices)
  "Sum all assets at current prices. Base asset = 1.0."
  (fold (lambda (sum asset)
          (+ sum (* (total treasury asset)
                    (get prices asset 1.0))))
        0.0
        (keys (:balances treasury))))

(define (price-map treasury asset-prices)
  "Build prices from (asset, price) pairs. All known assets default to 1.0."
  (let ((defaults (fold (lambda (m a) (assoc m a 1.0))
                        {}
                        (union (keys (:balances treasury))
                               (keys (:deployed treasury))))))
    (fold (lambda (prices pair)
            (assoc prices (first pair) (second pair)))
          defaults
          asset-prices)))

(define (deployed-value treasury prices)
  "Total deployed value in a common denomination."
  (fold (lambda (sum asset)
          (+ sum (* (deployed treasury asset)
                    (get prices asset 1.0))))
        0.0
        (keys (:deployed treasury))))

;; ── Construction ────────────────────────────────────────────────────

(define (new-treasury max-positions max-utilization)
  (treasury :balances {} :deployed {}
            :max-positions max-positions
            :max-utilization max-utilization
            :total-fees-paid 0.0 :total-slippage 0.0))

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
  "Move available → deployed. Returns (treasury, claimed).
   Does NOT modify position count — that's the enterprise's concern."
  (let ((claimed (min amount (balance treasury asset))))
    (list
      (update treasury
        :balances (assoc (:balances treasury) asset (- (balance treasury asset) claimed))
        :deployed (assoc (:deployed treasury) asset (+ (get (:deployed treasury) asset 0.0) claimed)))
      claimed)))

(define (release treasury asset amount)
  "Move deployed → available. Returns treasury.
   Does NOT modify position count — that's the enterprise's concern."
  (let ((released (min amount (get (:deployed treasury) asset 0.0))))
    (update treasury
      :deployed (assoc (:deployed treasury) asset (- (get (:deployed treasury) asset 0.0) released))
      :balances (assoc (:balances treasury) asset (+ (balance treasury asset) released)))))

;; open-position and close-position REMOVED.
;; Treasury capital moves exclusively through ManagedPosition lifecycle:
;;   swap (USDC→WBTC or WBTC→USDC) + claim (available→deployed) + release (deployed→available).
;; The pending entry path is for LEARNING only — no treasury movement.
;; See enterprise.wat steps 7-8 (position opening) and step 5 (position exit).

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
