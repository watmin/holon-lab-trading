;; ── treasury.wat — the root of the enterprise ──────────────────────
;;
;; The treasury holds assets. It executes swaps. It tracks alpha.
;; It subscribes to the manager's decisions, filtered by risk approval.
;;
;; The treasury is pure accounting. It does not think. It does not predict.
;; It counts. It swaps. It records. It measures alpha.

;; ── Subscriptions ───────────────────────────────────────────────────
;;
;; The treasury's filter is the enterprise's final gate:
;; manager decision + risk approval + band validation + conviction check.
;;
;; (subscribe "treasury" → "manager"
;;   :filter (and (band-valid?)
;;                (conviction-in-band?)
;;                (risk-allows?)
;;                (market-moved-since-exit?))
;;   :process (execute-swap))

;; ── State ───────────────────────────────────────────────────────────
;;
;; (treasury
;;   :balances   (map asset → amount)     ; available to deploy
;;   :deployed   (map asset → amount)     ; claimed by open positions
;;   :positions  (list managed-position)  ; independently managed
;;   :alpha      f64                      ; cumulative trading value vs inaction
;;   :fees-paid  f64                      ; total venue costs
;;   :snapshot   (map asset → amount))    ; counterfactual baseline

;; ── Operations ──────────────────────────────────────────────────────
;;
;; (swap treasury from-asset to-asset amount price fee-rate)
;;   → (from-spent to-received)
;;   Side effect: updates balances, records fee
;;
;; (claim treasury asset amount)
;;   → moves available → deployed (position owns it)
;;
;; (release treasury asset amount)
;;   → moves deployed → available (position done)
;;
;; (snapshot treasury)
;;   → saves current balances + deployed as counterfactual
;;
;; (total-value treasury prices)
;;   → sum of all assets at current prices

;; ── Alpha ───────────────────────────────────────────────────────────
;;
;; Before each swap: snapshot.
;; After: alpha = total-value(actual) - total-value(snapshot-at-current-prices)
;; Positive alpha = this swap was better than inaction.
;; The risk manager reads this. The ledger records this.

;; ── Portfolio seeding ───────────────────────────────────────────────
;;
;; Initial state: 50/50 split between base asset and quote asset.
;; "I don't know which way the market will go — hold both."
;; Both BUY (add to quote) and SELL (back to base) positions can
;; open from candle 1. The seed ratio is a starting condition.
;; The enterprise evolves the allocation through trading.

;; ── What the treasury does NOT do ───────────────────────────────────
;;
;; - Does NOT predict direction (that's the market manager)
;; - Does NOT assess risk (that's the risk manager)
;; - Does NOT manage positions (that's the position lifecycle)
;; - Does NOT decide WHEN to trade (that's the band + filter)
;; - It executes. It counts. It measures alpha.
