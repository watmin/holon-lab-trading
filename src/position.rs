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
    pub fact_labels:   Vec<String>,      // thought facts present at this candle

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

    // ── Treasury allocation ──────────────────────────────────────────
    pub deployed_usd:      f64,    // capital reserved from treasury for this position
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

#[derive(Clone, Copy, PartialEq)]
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

#[derive(Clone, Copy, PartialEq)]
pub enum PositionExit {
    StopLoss,
    TakeProfit,
}
