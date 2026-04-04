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

    // ── Incremental simulation state ─────────────────────────────────
    // Avoids replaying full close history each candle.
    // Initialized at entry: extreme = entry_price, trail = initial stop.
    pub sim_extreme:       f64,    // best rate seen since entry
    pub sim_trail:         f64,    // current trailing stop level
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
// Pure simulation of a hypothetical position for learning labels.
// See wat/market/observer.wat: simulate-outcome, classify-outcome.
// See docs/proposals/2026/04/004-learning-pipeline/RESOLUTION.md.

/// The raw result of simulating a position forward through candle history.
/// Every position eventually resolves — the trailing stop guarantees it.
/// No horizon. No expiry. The ring buffer bounds memory.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum SimResult {
    /// Take-profit reached. weight = grace (how far past TP).
    TakeProfit { grace: f64 },
    /// Stop-loss hit. weight = violence (actual_loss / stop_distance).
    StopLoss { violence: f64 },
}

/// The classified outcome: Win or Loss. No third state.
/// The noise subspace learns from ALL thoughts every candle (background model).
/// The journal learns only from resolved positions (Win/Loss).
/// Weight = residual_norm × grace/violence (continuous, not gated).
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Outcome {
    /// TP reached. Weight = residual_norm × grace.
    Win { weight: f64 },
    /// Stop hit. Weight = residual_norm × violence.
    Loss { weight: f64 },
}

/// Simulate a hypothetical position from `entry_idx` forward through `closes`.
/// Pure function: no mutation, no side effects.
///
/// `closes`: slice of close prices (or 1/close for Sell direction).
///           Index 0 = the entry candle. Index 1..N = subsequent candles.
/// `entry_atr`: ATR at entry (normalized, e.g. 0.01 = 1%).
///
/// Returns Some(SimResult) if the position resolved, None if more candles needed.
/// Every position eventually resolves — the trailing stop guarantees it.
/// No horizon. No expiry. The pending ring buffer bounds memory.
pub fn simulate_outcome(
    closes: &[f64],
    entry_atr: f64,
    k_stop: f64,
    k_tp: f64,
    k_trail: f64,
) -> Option<SimResult> {
    if closes.len() < 2 { return None; }

    let entry_rate = closes[0];
    let stop_level = entry_rate * (1.0 - k_stop * entry_atr);
    let tp_level = entry_rate * (1.0 + k_tp * entry_atr);

    let mut extreme = entry_rate;
    let mut trail = stop_level;

    for &rate in &closes[1..] {
        if rate > extreme { extreme = rate; }
        let new_trail = extreme * (1.0 - k_trail * entry_atr);
        if new_trail > trail { trail = new_trail; }

        if rate <= trail {
            let actual_loss = (entry_rate - rate) / entry_rate;
            let stop_dist = k_stop * entry_atr;
            let violence = actual_loss / stop_dist;
            return Some(SimResult::StopLoss { violence });
        }

        if rate >= tp_level {
            let grace = (extreme - tp_level) / tp_level;
            return Some(SimResult::TakeProfit { grace });
        }
    }

    None // not yet resolved
}

/// Incremental simulation: check ONE new close against stored (extreme, trail).
/// Returns Some(SimResult) if resolved, None if still pending.
/// Updates extreme/trail in place via the returned SimState.
/// O(1) per candle instead of O(age).
pub struct SimState {
    pub extreme: f64,
    pub trail: f64,
}

pub fn tick_sim(
    current_rate: f64,
    entry_rate: f64,
    entry_atr: f64,
    k_stop: f64,
    k_tp: f64,
    k_trail: f64,
    state: &mut SimState,
) -> Option<SimResult> {
    if current_rate > state.extreme { state.extreme = current_rate; }
    let new_trail = state.extreme * (1.0 - k_trail * entry_atr);
    if new_trail > state.trail { state.trail = new_trail; }

    let tp_level = entry_rate * (1.0 + k_tp * entry_atr);

    if current_rate <= state.trail {
        let actual_loss = (entry_rate - current_rate) / entry_rate;
        let stop_dist = k_stop * entry_atr;
        let violence = actual_loss / stop_dist;
        return Some(SimResult::StopLoss { violence });
    }

    if current_rate >= tp_level {
        let grace = (state.extreme - tp_level) / tp_level;
        return Some(SimResult::TakeProfit { grace });
    }

    None
}

/// Initialize a SimState for a new pending entry.
pub fn init_sim_state(entry_rate: f64, entry_atr: f64, k_stop: f64) -> SimState {
    SimState {
        extreme: entry_rate,
        trail: entry_rate * (1.0 - k_stop * entry_atr),
    }
}

/// Classify a simulation result using the noise subspace as the tolerance boundary.
/// `residual_norm`: L2 norm of the thought after noise subtraction.
///                  High = unusual thought. Low = boring thought.
/// `threshold`: below this norm, the thought is boring → Noise regardless of sim result.
/// Convert a simulation result into a learning outcome.
/// Weight = residual_norm × grace/violence.
/// Boring thoughts (low residual) teach softly. Unusual thoughts teach hard.
/// No binary gate. Continuous weighting.
pub fn to_outcome(sim: SimResult, residual_norm: f64) -> Outcome {
    match sim {
        SimResult::TakeProfit { grace } => Outcome::Win { weight: residual_norm * grace.max(0.01) },
        SimResult::StopLoss { violence } => Outcome::Loss { weight: residual_norm * violence.max(0.01) },
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

    // ── simulate_outcome tests ──────────────────────────────────────────

    #[test]
    fn sim_tp_reached() {
        let closes = vec![50000.0, 50500.0, 51000.0, 51500.0, 52000.0];
        let result = simulate_outcome(&closes, 0.01, 2.0, 3.0, 1.5);
        match result {
            Some(SimResult::TakeProfit { grace }) => {
                assert!(grace >= 0.0, "grace should be non-negative");
            }
            other => panic!("expected TakeProfit, got {:?}", other),
        }
    }

    #[test]
    fn sim_stop_hit() {
        let closes = vec![50000.0, 49500.0, 48500.0];
        let result = simulate_outcome(&closes, 0.01, 2.0, 3.0, 1.5);
        match result {
            Some(SimResult::StopLoss { violence }) => {
                assert!(violence > 0.0, "violence should be positive");
            }
            other => panic!("expected StopLoss, got {:?}", other),
        }
    }

    #[test]
    fn sim_not_yet_resolved() {
        // Price stays flat — neither stop nor TP. Needs more candles.
        let closes = vec![50000.0, 50010.0, 49990.0, 50005.0];
        assert_eq!(simulate_outcome(&closes, 0.01, 2.0, 3.0, 1.5), None);
    }

    #[test]
    fn sim_single_candle_returns_none() {
        assert_eq!(simulate_outcome(&[50000.0], 0.01, 2.0, 3.0, 1.5), None);
    }

    #[test]
    fn sim_empty_returns_none() {
        assert_eq!(simulate_outcome(&[], 0.01, 2.0, 3.0, 1.5), None);
    }

    #[test]
    fn sim_trailing_stop_ratchets() {
        let closes = vec![50000.0, 50500.0, 51000.0, 50100.0, 50000.0];
        let result = simulate_outcome(&closes, 0.01, 2.0, 3.0, 1.5);
        match result {
            Some(SimResult::StopLoss { .. }) => {}
            other => panic!("expected StopLoss from trailing stop, got {:?}", other),
        }
    }

    #[test]
    fn sim_violence_proportional_to_gap() {
        let gentle = vec![50000.0, 49000.0];
        let violent = vec![50000.0, 47000.0];

        let g_violence = match simulate_outcome(&gentle, 0.01, 2.0, 3.0, 1.5) {
            Some(SimResult::StopLoss { violence }) => violence,
            other => panic!("expected StopLoss, got {:?}", other),
        };
        let v_violence = match simulate_outcome(&violent, 0.01, 2.0, 3.0, 1.5) {
            Some(SimResult::StopLoss { violence }) => violence,
            other => panic!("expected StopLoss, got {:?}", other),
        };

        assert!(v_violence > g_violence,
            "violent gap should have higher violence: {} vs {}", v_violence, g_violence);
    }

    // ── to_outcome tests ──────────────────────────────────────────

    #[test]
    fn outcome_win_weight_scales_by_residual_norm() {
        let outcome = to_outcome(SimResult::TakeProfit { grace: 0.2 }, 0.5);
        match outcome {
            Outcome::Win { weight } => assert!((weight - 0.1).abs() < 1e-10, "0.5 * 0.2 = 0.1"),
            _ => panic!("expected Win"),
        }
    }

    #[test]
    fn outcome_loss_weight_scales_by_residual_norm() {
        let outcome = to_outcome(SimResult::StopLoss { violence: 2.0 }, 0.3);
        match outcome {
            Outcome::Loss { weight } => assert!((weight - 0.6).abs() < 1e-10, "0.3 * 2.0 = 0.6"),
            _ => panic!("expected Loss"),
        }
    }

    #[test]
    fn outcome_boring_thought_teaches_softly() {
        let boring = to_outcome(SimResult::TakeProfit { grace: 0.2 }, 0.01);
        let unusual = to_outcome(SimResult::TakeProfit { grace: 0.2 }, 1.0);
        let w_boring = match boring { Outcome::Win { weight } => weight, _ => panic!() };
        let w_unusual = match unusual { Outcome::Win { weight } => weight, _ => panic!() };
        assert!(w_unusual > w_boring * 10.0, "unusual should teach much harder than boring");
    }

    #[test]
    fn outcome_min_weight_floor() {
        // Grace of 0.0 (barely tapped TP) should still have min weight
        let outcome = to_outcome(SimResult::TakeProfit { grace: 0.0 }, 0.5);
        match outcome {
            Outcome::Win { weight } => assert!(weight > 0.0, "min floor should prevent zero weight"),
            _ => panic!("expected Win"),
        }
    }
}
