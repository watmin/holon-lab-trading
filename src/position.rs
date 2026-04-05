use holon::Vector;
use crate::journal::{Label, Prediction};
use crate::treasury::Asset;

/// ATR multiplier for trailing stop distance. Not a price, not a percentage.
#[derive(Clone, Copy)]
pub struct TrailFactor(pub f64);

// ─── Exit observation ───────────────────────────────────────────────────────

/// Snapshot of position state for deferred exit expert learning.
/// Resolves after exit_horizon candles: did holding improve the position?
pub struct ExitObservation {
    pub thought: Vector,
    pub pos_id: usize,
    pub snapshot_pnl: f64,
    pub snapshot_candle: usize,
}

// ─── Crossing snapshot ──────────────────────────────────────────────────────
/// Data captured at the moment of first threshold crossing.
/// Bundled with the outcome label so crossing data lives with the event.
pub struct CrossingSnapshot {
    pub label:    Label,   // the outcome (Buy/Sell)
    pub pct:      f64,     // price change at crossing
    pub candles:  usize,   // candles elapsed since entry at crossing
    pub ts:       String,  // timestamp at crossing
    pub price:    f64,     // candle close at crossing
}

// ─── Pending entry ───────────────────────────────────────────────────────────

// rune:forge(aspirational) — Pending has 17 fields; 5 mutated post-construction
// (crossing, max_favorable, max_adverse, exit_reason, exit_pct).
// Split into PendingEntry + PendingOutcome would improve value/place distinction.
// Low risk: mutations are in the learning loop (infrequent, per-entry).
pub struct Pending {
    pub candle_idx:    usize,
    pub tht_vec:       Vector,

    // ── Prediction (what the observers said) ────────────────────────
    pub tht_pred:      Prediction,
    pub meta_dir:      Option<Label>,   // manager's direction call
    pub high_conviction:   bool,             // true if conviction >= threshold
    pub meta_conviction: f64,
    pub position_frac: Option<f64>,
    pub observer_vecs:   Vec<Vector>,       // per-observer thought vectors
    pub observer_preds:  Vec<Prediction>,   // per-observer predictions at entry time
    pub mgr_thought:     Option<Vector>,    // complete manager thought (delta-enriched) for learning

    // ── Learning (event-driven, first crossing only) ─────────────────
    pub crossing: Option<CrossingSnapshot>, // set on first threshold crossing; drives learning

    // ── Accounting (pure measurement, no hallucination) ──────────────
    pub entry_price:       f64,
    pub entry_ts:          String,  // timestamp at entry (for ledger)
    pub entry_atr:         f64,    // ATR at entry (for threshold scaling)
    pub max_favorable:     f64,    // best price move in our direction
    pub max_adverse:       f64,    // worst price move against us (negative)

    // ── Trade management (the enterprise) ────────────────────────────
    pub exit_reason:       Option<ExitReason>, // why the trade closed
    pub exit_pct:          f64,    // actual exit price change (for P&L)

    // ── Dual-sided excursion (proposal 006) ──────────────────────────
    pub dual: DualExcursion,     // both sides tracked independently
}

// rune:reap(aspirational) — TrailingStop and TakeProfit are matched in ledger display
// but only HorizonExpiry is constructed. Wire when pending entries resolve at position
// exit rather than at horizon — requires linking Pending to ManagedPosition lifecycle.
pub enum ExitReason {
    TrailingStop,        // stop loss hit (including raised stops)
    TakeProfit,          // target reached
    HorizonExpiry,       // safety valve — queue cleanup, not an exit strategy
}

// ─── Position Entry ─────────────────────────────────────────────────────────
// All parameters needed to open a position, bundled into a struct.
// Token-to-token: source is what we sell, target is what we receive.

pub struct PositionEntry {
    pub id:              usize,
    pub candle_idx:      usize,
    pub source_asset:    Asset,
    pub target_asset:    Asset,
    pub source_amount:   f64,       // units of source spent
    pub target_received: f64,       // units of target received from swap
    pub entry_rate:      f64,       // source_per_target at entry
    pub entry_atr:       f64,       // ATR at entry (scales stop/TP in rate space)
    pub entry_fee:       f64,       // fee in source units
    pub k_stop:          f64,
    pub k_tp:            f64,
}

// ─── Managed Position ────────────────────────────────────────────────────────
// A swap with its own lifecycle. Token-to-token.
// Rate = source_per_target. Rate going up is ALWAYS good.
// One formula for stop, TP, trailing, P&L. No match on direction.

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum PositionPhase {
    Active,         // initial position, stop + TP active
    Runner,         // capital reclaimed, riding house money
    Closed,         // fully exited
}

pub struct ManagedPosition {
    pub id:             usize,
    pub entry_candle:   usize,
    pub source_asset:   Asset,
    pub target_asset:   Asset,
    pub source_amount:  f64,        // units of source spent to enter
    pub target_held:    f64,        // units of target currently held
    pub source_reclaimed: f64,      // units of source recovered from partial exits
    pub entry_rate:     f64,        // source_per_target at entry
    pub entry_atr:      f64,        // ATR at entry — scales stop/TP

    // Management — all in rate space (source_per_target)
    pub phase:          PositionPhase,
    pub trailing_stop:  f64,        // absolute rate level
    pub take_profit:    f64,        // absolute rate level (first target)
    pub extreme_rate:   f64,        // best rate in our favor (always highest)

    // Accounting
    pub max_adverse:    f64,        // worst return (negative fraction)
    pub total_fees:     f64,        // cumulative fees (in source units)
    pub candles_held:   usize,
}

impl ManagedPosition {
    /// Construct from a swap. One formula for stop/TP.
    /// Rate going up = profit. Stop below entry. TP above entry.
    pub fn new(entry: PositionEntry) -> Self {
        let rate = entry.entry_rate;
        let atr = entry.entry_atr;
        let stop = rate * (1.0 - entry.k_stop * atr);
        let tp = rate * (1.0 + entry.k_tp * atr);

        Self {
            id: entry.id,
            entry_candle: entry.candle_idx,
            source_asset: entry.source_asset,
            target_asset: entry.target_asset,
            source_amount: entry.source_amount,
            target_held: entry.target_received,
            source_reclaimed: 0.0,
            entry_rate: rate,
            entry_atr: atr,
            phase: PositionPhase::Active,
            trailing_stop: stop,
            take_profit: tp,
            extreme_rate: rate,
            max_adverse: 0.0,
            total_fees: entry.entry_fee,
            candles_held: 0,
        }
    }

    /// Update position with current rate. Returns exit signal if triggered.
    /// Rate = source_per_target. Rate going up is always good.
    /// One formula. No match on direction.
    pub fn tick(&mut self, current_rate: f64, k_trail: TrailFactor) -> Option<PositionExit> {
        self.candles_held += 1;
        if self.phase == PositionPhase::Closed { return None; }

        // Track worst excursion
        let ret = self.return_pct(current_rate);
        if ret < self.max_adverse { self.max_adverse = ret; }

        // Rate going up = profit. Track extreme. Trail stop upward.
        if current_rate > self.extreme_rate {
            self.extreme_rate = current_rate;
        }
        let new_stop = self.extreme_rate * (1.0 - k_trail.0 * self.entry_atr);
        if new_stop > self.trailing_stop {
            self.trailing_stop = new_stop;
        }

        // Stop: rate fell below trailing stop
        if current_rate <= self.trailing_stop {
            return Some(PositionExit::StopLoss);
        }
        // TP: rate rose above target
        if self.phase == PositionPhase::Active && current_rate >= self.take_profit {
            return Some(PositionExit::TakeProfit);
        }

        None
    }

    /// Current return as fraction of source deployed.
    /// target_held * current_rate = target value in source units.
    /// One formula. No match on direction.
    pub fn return_pct(&self, current_rate: f64) -> f64 {
        if self.source_amount <= 0.0 { return 0.0; }
        let target_in_source = self.target_held * current_rate;
        (target_in_source + self.source_reclaimed - self.total_fees) / self.source_amount - 1.0
    }
}

#[derive(Clone, Copy, PartialEq, Debug)]
pub enum PositionExit {
    StopLoss,
    TakeProfit,
}

// ─── Outcome-based labeling ─────────────────────────────────────────────────
// See wat/exit/observer.wat: classify-dual-excursion.
// See docs/proposals/2026/04/006-co-learning-honest/RESOLUTION.md.

/// The classified outcome: Win or Loss. No third state.
/// Win: buy was better (buy_grace > sell_grace).
/// Loss: sell was better (sell_grace > buy_grace).
/// Weight = |buy_grace - sell_grace| — how decisively one side won.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Outcome {
    Win { weight: f64 },
    Loss { weight: f64 },
}

// ─── Dual-sided excursion ───────────────────────────────────────────────────
// Both sides played from the same candle. No prediction decides the label.
// The market decides. See wat/exit/observer.wat: dual-excursion.
//
// Crutches: k_stop, k_tp, k_trail are magic numbers. The trailing stop
// parameters determine when each side resolves. Better than a horizon timer —
// the market's movement triggers resolution — but still parameters we chose.
// Future: the exit observer's curve learns the optimal multipliers.

/// Dual-sided excursion state for one pending entry.
/// Tracks buy-side and sell-side independently. Each resolves organically
/// when its trailing stop or take-profit fires.
pub struct DualExcursion {
    // ── Buy side (rate going up is favorable) ──
    pub buy_mfe: f64,           // max favorable excursion (positive)
    pub buy_mae: f64,           // max adverse excursion (negative)
    pub buy_extreme: f64,       // best rate in buy direction
    pub buy_trail_stop: f64,    // trailing stop level
    pub buy_resolved: bool,
    // ── Sell side (rate going down is favorable) ──
    pub sell_mfe: f64,          // max favorable excursion (positive, inverted)
    pub sell_mae: f64,          // max adverse excursion (negative, inverted)
    pub sell_extreme: f64,      // best rate in sell direction (lowest)
    pub sell_trail_stop: f64,   // trailing stop level
    pub sell_resolved: bool,
    // ── Entry context ──
    pub entry_rate: f64,
    pub entry_atr: f64,
}

impl DualExcursion {
    /// Create a new dual excursion from entry rate and ATR.
    /// Both sides start at zero excursion. Stops computed from ATR.
    pub fn new(entry_rate: f64, entry_atr: f64, k_stop: f64) -> Self {
        Self {
            buy_mfe: 0.0, buy_mae: 0.0,
            buy_extreme: entry_rate,
            buy_trail_stop: entry_rate * (1.0 - k_stop * entry_atr),
            buy_resolved: false,
            sell_mfe: 0.0, sell_mae: 0.0,
            sell_extreme: entry_rate,
            sell_trail_stop: entry_rate * (1.0 + k_stop * entry_atr),
            sell_resolved: false,
            entry_rate, entry_atr,
        }
    }

    /// Tick both sides with current price. Each resolves independently.
    /// Buy: rate up = favorable. Sell: rate down = favorable.
    pub fn tick(&mut self, current_rate: f64, k_trail: f64, k_tp: f64) {
        let entry = self.entry_rate;
        let atr = self.entry_atr;

        // ── Buy side ──
        if !self.buy_resolved {
            let buy_move = current_rate - entry;
            self.buy_mfe = self.buy_mfe.max(buy_move);
            self.buy_mae = self.buy_mae.min(buy_move);
            // Trail upward
            if current_rate > self.buy_extreme { self.buy_extreme = current_rate; }
            let trail = self.buy_extreme * (1.0 - k_trail * atr);
            if trail > self.buy_trail_stop { self.buy_trail_stop = trail; }
            // Resolve
            if current_rate <= self.buy_trail_stop {
                self.buy_resolved = true;
            } else if current_rate >= entry * (1.0 + k_tp * atr) {
                self.buy_resolved = true;
            }
        }

        // ── Sell side ──
        if !self.sell_resolved {
            let sell_move = entry - current_rate;
            self.sell_mfe = self.sell_mfe.max(sell_move);
            self.sell_mae = self.sell_mae.min(sell_move);
            // Trail downward
            if current_rate < self.sell_extreme { self.sell_extreme = current_rate; }
            let trail = self.sell_extreme * (1.0 + k_trail * atr);
            if trail < self.sell_trail_stop { self.sell_trail_stop = trail; }
            // Resolve
            if current_rate >= self.sell_trail_stop {
                self.sell_resolved = true;
            } else if current_rate <= entry * (1.0 - k_tp * atr) {
                self.sell_resolved = true;
            }
        }
    }

    /// Are both sides resolved?
    pub fn both_resolved(&self) -> bool {
        self.buy_resolved && self.sell_resolved
    }

    /// Classify: which side experienced more grace?
    /// Returns Some(Outcome) if both sides resolved, None otherwise.
    pub fn classify(&self) -> Option<Outcome> {
        if !self.both_resolved() { return None; }
        let buy_grace = self.buy_mfe - self.buy_mae.abs();
        let sell_grace = self.sell_mfe - self.sell_mae.abs();
        let gap = (buy_grace - sell_grace).abs().max(0.01);
        if buy_grace > sell_grace {
            Some(Outcome::Win { weight: gap })   // Buy was better
        } else {
            Some(Outcome::Loss { weight: gap })  // Sell was better
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_entry(rate: f64, atr: f64, k_stop: f64, k_tp: f64) -> PositionEntry {
        PositionEntry {
            id: 1,
            candle_idx: 0,
            source_asset: Asset::new("USDC"),
            target_asset: Asset::new("WBTC"),
            source_amount: 1000.0,
            target_received: 1000.0 / rate,
            entry_rate: rate,
            entry_atr: atr,
            entry_fee: 1.0,
            k_stop,
            k_tp,
        }
    }

    #[test]
    fn new_creates_with_correct_stop_trail_tp() {
        let rate = 50000.0;
        let atr = 0.01;  // 1% normalized ATR
        let k_stop = 2.0;
        let k_tp = 3.0;
        let pos = ManagedPosition::new(make_entry(rate, atr, k_stop, k_tp));

        let expected_stop = rate * (1.0 - k_stop * atr);
        let expected_tp = rate * (1.0 + k_tp * atr);

        assert_eq!(pos.entry_rate, rate);
        assert!((pos.trailing_stop - expected_stop).abs() < 1e-6);
        assert!((pos.take_profit - expected_tp).abs() < 1e-6);
        assert_eq!(pos.phase, PositionPhase::Active);
        assert_eq!(pos.extreme_rate, rate);
        assert_eq!(pos.candles_held, 0);
    }

    #[test]
    fn tick_returns_none_when_no_trigger() {
        let mut pos = ManagedPosition::new(make_entry(50000.0, 0.01, 2.0, 3.0));
        // Price moves slightly up but not to TP
        let result = pos.tick(50500.0, TrailFactor(1.5));
        assert_eq!(result, None);
        assert_eq!(pos.candles_held, 1);
    }

    #[test]
    fn tick_returns_stop_loss_when_stop_triggered() {
        let mut pos = ManagedPosition::new(make_entry(50000.0, 0.01, 2.0, 3.0));
        // Stop is at 50000 * (1 - 2*0.01) = 49000
        let result = pos.tick(48000.0, TrailFactor(1.5));
        assert_eq!(result, Some(PositionExit::StopLoss));
    }

    #[test]
    fn tick_returns_take_profit_when_tp_triggered() {
        let mut pos = ManagedPosition::new(make_entry(50000.0, 0.01, 2.0, 3.0));
        // TP is at 50000 * (1 + 3*0.01) = 51500
        let result = pos.tick(52000.0, TrailFactor(1.5));
        assert_eq!(result, Some(PositionExit::TakeProfit));
    }

    #[test]
    fn trailing_stop_ratchets_upward() {
        let mut pos = ManagedPosition::new(make_entry(50000.0, 0.01, 2.0, 3.0));
        let initial_stop = pos.trailing_stop;

        // Price rises but not to TP
        pos.tick(50800.0, TrailFactor(1.5));
        // New extreme is 50800, new stop = 50800 * (1 - 1.5*0.01) = 50038
        assert!(pos.trailing_stop > initial_stop);
        assert!((pos.extreme_rate - 50800.0).abs() < 1e-6);
    }

    #[test]
    fn return_pct_positive_when_rate_rises() {
        let entry = make_entry(50000.0, 0.01, 2.0, 3.0);
        let source_amount = entry.source_amount;
        let target_held = entry.target_received;
        let fee = entry.entry_fee;
        let pos = ManagedPosition::new(entry);

        // Rate goes up 10%: 55000
        let ret = pos.return_pct(55000.0);
        // target_held * 55000 / source_amount - 1 (minus fees)
        let expected = (target_held * 55000.0 + 0.0 - fee) / source_amount - 1.0;
        assert!((ret - expected).abs() < 1e-10);
        assert!(ret > 0.0);
    }

    #[test]
    fn return_pct_negative_when_rate_falls() {
        let pos = ManagedPosition::new(make_entry(50000.0, 0.01, 2.0, 3.0));
        let ret = pos.return_pct(45000.0);
        assert!(ret < 0.0);
    }

    #[test]
    fn return_pct_symmetric_with_entry() {
        let pos = ManagedPosition::new(make_entry(50000.0, 0.01, 2.0, 3.0));
        // At entry rate, return should be slightly negative (due to entry fee)
        let ret = pos.return_pct(50000.0);
        // fee is 1.0 on 1000.0 source, so ~ -0.001
        assert!(ret < 0.0);
        assert!(ret > -0.01); // small
    }

}
