;; ── position.wat ───────────────────────────────────────────────────
;;
;; A position is a managed allocation from the treasury.
;; Not a binary swap — a fraction of capital with its own lifecycle.
;;
;; Entry → Management → Partial exit → Runner → Final exit
;;
;; Each position tracks:
;;   - entry price, entry time, allocated USDC, received WBTC
;;   - ATR at entry (sets stop/TP scale)
;;   - trailing stop (rises with favorable movement)
;;   - take profit target
;;   - partial exit status (capital reclaimed? running on house money?)
;;   - current P&L

;; ── Lifecycle ──────────────────────────────────────────────────────
;;
;; 1. ENTRY: manager says BUY with conviction in proven band.
;;    Treasury allocates fraction of available USDC (Kelly from band accuracy).
;;    Swap USDC → WBTC at current price minus fee.
;;
;; 2. MANAGEMENT (every candle while position is open):
;;    - Update trailing stop: max(trailing_stop, current_price - trail_distance)
;;    - trail_distance = K_trail × ATR_at_entry
;;    - Check stop: if current_price <= trailing_stop → exit
;;    - Check take profit: if current_price >= entry_price × (1 + K_tp × ATR_at_entry) → partial exit
;;
;; 3. PARTIAL EXIT (first target hit):
;;    - Sell enough WBTC to reclaim: entry_usdc + swap_fees + min_profit
;;    - Remaining WBTC = house money. Free ride.
;;    - Trailing stop continues on the runner.
;;
;; 4. RUNNER (after partial exit):
;;    - Only the trailing stop manages this position.
;;    - The runner can ride indefinitely.
;;    - When trailing stop hits → final exit. All WBTC → USDC.
;;
;; 5. FINAL EXIT:
;;    - Swap remaining WBTC → USDC.
;;    - Record in ledger: entry, exits, fees, P&L, hold duration.

;; ── Risk rejection ─────────────────────────────────────────────────
;;
;; Before opening a position, the risk manager checks:
;;   (> (expected-move atr horizon) (* 2 swap-fee))
;; "Is the expected price movement larger than the round-trip cost?"
;; If not, reject. The trade can't cover its fees.

;; ── Sizing ─────────────────────────────────────────────────────────
;;
;; fraction = (band_edge / 2) × risk_multiplier
;; band_edge = 3% (proven band conviction edge)
;; risk_multiplier = min residual ratio across risk branches
;; Bounded by:
;;   - max single position: max_single_position (CLI arg, default 20%)
;;   - risk gate: risk branches modulate via residual ratio
;;   - fee gate: expected_move > 2 × fee_rate

;; ── Cooldown ───────────────────────────────────────────────────────
;;
;; After a position is stopped out, the manager waits N candles before
;; opening a new position in the same direction. Prevents oscillation.
;; N = derived from the band's hold duration distribution, not hardcoded.
;; Starting value: the horizon (36 candles).

;; ── Multiple positions ─────────────────────────────────────────────
;;
;; The treasury can have multiple open positions simultaneously.
;; Each entered at a different time, different price, different ATR.
;; Each managed independently. The aggregate WBTC exposure is the
;; sum of all open positions' WBTC balances.
;;
;; The risk manager sees aggregate exposure and can:
;;   - Reject new positions if total deployment > max_utilization
;;   - Reduce sizing if correlation between positions is high
;;   - Force close if aggregate drawdown exceeds threshold
