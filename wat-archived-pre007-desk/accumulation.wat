;; ── accumulation.wat — the accumulation model ───────────────────────
;;
;; The enterprise finds good deals between two assets.
;; Every winning trade deposits residue on one side of the pair.
;; Every candle is a chance to accumulate.
;;
;; Generic over any pair: (A, B) = (usdc, wbtc) | (gold, sol) | (eth, silver).
;; The enterprise bets: "I can swap A for B now and get a better deal than waiting."
;;
;; The mechanism (same in both directions):
;;   1. Deploy source → swap to target at current rate
;;   2. If target appreciates against source: recover principal, keep residue
;;   3. If target depreciates: stop loss, eat the bounded loss
;;   4. Recovered principal recycles into the next trade
;;   5. Residue accumulates on the winning side
;;
;; A Buy: swap A → B. B appreciates → recover A, accumulate B residue.
;; A Sell: swap B → A. A appreciates → recover B, accumulate A residue.
;; Both directions accumulate. The prediction picks which side to fish.
;;
;; One action per candle. A concurrent buy and sell is architecturally
;; impossible — the enterprise produces one prediction, takes one action.
;; Constant accumulation. Every winning trade grows one side of the pair.

(require core/structural)
(require position)
(require treasury)

;; ── The pair ───────────────────────────────────────────────────────
;;
;; A desk trades one pair: (asset-a, asset-b).
;; Neither asset has a fixed role. On any given trade:
;;   source = what you deploy (risk)
;;   target = what you receive (potential accumulation)
;;
;; A Buy trade: A is source, B is target. Bet: B will appreciate vs A.
;; A Sell trade: B is source, A is target. Bet: A will appreciate vs B.
;;
;; The observer predicts which direction offers the better deal NOW.
;; The desk acts on it. The treasury manages both balances.

;; ── Position lifecycle ─────────────────────────────────────────────
;;
;; Identical in both directions. Source/target swap roles, logic stays the same.
;; position.wat already defines rate = source/target. Rate up = profit.
;;
;; Phase 1: ACTIVE — principal at risk.
;;   Entry: swap source-amount of source → target at market rate.
;;   Stop: rate drops below trailing stop → exit everything.
;;     Action: swap all target-held → source. Loss = source-amount - recovered.
;;     The loss is bounded by the stop distance.
;;   Take-profit: rate rises above TP level → principal recovery.
;;     Action: swap exactly source-amount worth of target → source.
;;       target-to-swap = source-amount / (current-rate * (1 - fee-rate))
;;       residue = target-held - target-to-swap
;;     The position splits:
;;       - source-amount returns to treasury (recycled for next trade)
;;       - residue stays as target in the treasury (accumulated)
;;     Phase transitions to :runner if residue > 0.
;;
;; Phase 2: RUNNER — house money only, zero cost basis.
;;   The residue rides with a trailing stop. No principal at risk.
;;   Stop: rate drops below runner trailing stop → harvest.
;;     Action: residue is already in target. Position closes. No swap.
;;     The target was accumulated at principal recovery time.
;;   The runner trailing stop is wider than active (patience for house money).
;;
;; Phase 3: CLOSED — position complete.
;;   Accumulated = residue from principal recovery (in target asset).
;;   Cost = fees + slippage. Principal was recovered.

;; ── Principal recovery ─────────────────────────────────────────────
;;
;; The critical swap. When take-profit fires:
;;
;; (define (recover-principal pos current-rate fee-rate)
;;   "Swap just enough target to recover the original source-amount.
;;    Returns (target-to-swap, residue, source-recovered)."
;;   (let* ((gross-need   (/ (:source-amount pos) current-rate))
;;          (with-fee     (/ gross-need (- 1.0 fee-rate)))  ; extra to cover fee
;;          (to-swap      (min with-fee (:target-held pos)))
;;          (source-back  (* to-swap current-rate (- 1.0 fee-rate)))
;;          (residue      (- (:target-held pos) to-swap)))
;;     (list to-swap residue source-back)))
;;
;; After recovery:
;;   - source-reclaimed += source-back (should be ≈ source-amount)
;;   - target-held = residue (house money)
;;   - phase = :runner
;;
;; The residue is the fish. The source-amount is the line, reeled back in.

;; ── Accumulation accounting ────────────────────────────────────────
;;
;; The treasury holds both assets in :balances. Accumulated residue
;; lands in :balances like any other funds — it IS real balance.
;; A separate ledger tracks the accumulation history:
;;
;; (struct accumulation-ledger
;;   total-accumulated     ; (map asset amount) — lifetime harvest per asset
;;   trade-count           ; total trades opened (both directions)
;;   recovery-count        ; trades where principal was recovered
;;   loss-count            ; trades stopped out at a loss
;;   total-lost            ; (map asset amount) — lifetime loss per asset
;;   total-fees-paid)      ; lifetime fees across all trades
;;
;; The success metric: residue accumulated per unit risked.
;;
;; (define (accumulation-rate ledger asset)
;;   "Lifetime residue per trade for this asset."
;;   (/ (get (:total-accumulated ledger) asset 0.0)
;;      (max 1 (:trade-count ledger))))

;; ── Kelly under accumulation ───────────────────────────────────────
;;
;; The Kelly question: how much source to deploy per trade?
;; Downside: bounded by stop-loss (fraction of source-amount).
;; Upside: residue deposited as target.
;;
;; (define (accumulation-kelly win-rate avg-residue-frac avg-loss-frac)
;;   "Kelly fraction for the accumulation model.
;;    win-rate: fraction of trades reaching principal recovery.
;;    avg-residue-frac: average residue as fraction of source deployed (the gain).
;;    avg-loss-frac: average stop-loss as fraction of source deployed (the cost)."
;;   (/ (- (* win-rate avg-residue-frac) (* (- 1.0 win-rate) avg-loss-frac))
;;      avg-residue-frac))

;; ── What accumulation does NOT change ──────────────────────────────
;; - Observer predictions (they still predict direction — which side is the deal?)
;; - Manager aggregation (panel of opinions, same encoding)
;; - Risk gating (portfolio health still matters)
;; - Position mechanics (rate = source/target, one formula both directions)
;;
;; What it DOES change:
;; - The reward signal: accumulation rate, not P&L
;; - Take-profit action: principal recovery, not full exit
;; - Sell signals: real trades (accumulate the other side), not silence
;; - Success: both sides of the pair grow over time

;; ── Pair agnosticism ───────────────────────────────────────────────
;;
;; The enterprise operates on (A, B) pairs. The names don't matter.
;;
;; (usdc, wbtc)   — accumulate BTC when right, accumulate USDC when right
;; (gold, sol)    — accumulate SOL or gold, whichever the deal favors
;; (eth, silver)  — accumulate silver or ETH, same mechanism
;; (usd, amzn)    — accumulate shares or cash, market decides
;;
;; The candle stream provides the exchange rate between A and B.
;; The observers predict rate movement. The desk picks the direction.
;; The treasury manages both sides. Residue accumulates on the winning side.
;;
;; One structure. Any pair. Both directions. Constant accumulation.
