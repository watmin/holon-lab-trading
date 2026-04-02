use holon::Vector;
use crate::journal::{Direction, Label, Prediction};

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

    // ── Prediction (what the experts said) ────────────────────────────
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

#[derive(Clone, Copy, PartialEq)]
pub enum ExitReason {
    // rune:reap(aspirational) — TrailingStop and TakeProfit are matched in ledger display
    // but only HorizonExpiry is constructed. Wire when pending entries resolve at position
    // exit rather than at horizon — requires linking Pending to ManagedPosition lifecycle.
    TrailingStop,        // stop loss hit (including raised stops)
    TakeProfit,          // target reached
    HorizonExpiry,       // safety valve — queue cleanup, not an exit strategy
}

// ─── Position Entry ─────────────────────────────────────────────────────────
// All parameters needed to open a position, bundled into a struct so that
// 10 bare f64/usize params can't be silently swapped at the call site.

pub struct PositionEntry {
    pub id:              usize,
    pub candle_idx:      usize,
    pub entry_price:     f64,
    pub entry_atr:       f64,
    pub direction:       Direction,
    pub base_deployed:   f64,
    pub quote_received:  f64,
    pub entry_fee:       f64,
    pub k_stop:          f64,
    pub k_tp:            f64,
}

// ─── Managed Position ────────────────────────────────────────────────────────
// A real WBTC holding with its own lifecycle. Not binary — fractional.
// Entered, managed each candle, partially exited, runner, final exit.

#[derive(Clone, Copy, PartialEq)]
pub enum PositionPhase {
    Active,         // initial position, stop + TP active
    Runner,         // capital reclaimed, riding house money
    Closed,         // fully exited
}

pub struct ManagedPosition {
    pub id:             usize,      // unique position identifier
    pub entry_candle:   usize,
    pub entry_price:    f64,
    pub entry_atr:      f64,        // ATR at entry — scales stop/TP
    pub direction:      Direction,    // Buy (long WBTC) or Sell (back to USDC)

    // Capital
    pub base_deployed:  f64,        // USDC spent to enter
    pub quote_held:      f64,        // WBTC currently held in this position
    pub base_reclaimed: f64,        // USDC recovered from partial exits

    // Management
    pub phase:          PositionPhase,
    pub trailing_stop:  f64,        // absolute price level
    pub take_profit:    f64,        // absolute price level (first target)
    pub extreme_price:  f64,        // best price in our favor (high for longs, low for shorts)

    // Accounting
    pub max_adverse:    f64,        // worst return against us (negative fraction)
    pub total_fees:     f64,        // cumulative fees paid (entry + partials + exit)
    pub candles_held:   usize,      // how long this position has been open
}

impl ManagedPosition {
    /// Construct a managed position from a PositionEntry struct.
    /// Named fields prevent silent parameter swaps between bare f64 values.
    pub fn new(entry: PositionEntry) -> Self {
        // BUY: stop below entry, TP above. SELL: stop above, TP below.
        let (stop, tp, hw) = match entry.direction {
            Direction::Long => (
                entry.entry_price * (1.0 - entry.k_stop * entry.entry_atr),
                entry.entry_price * (1.0 + entry.k_tp * entry.entry_atr),
                entry.entry_price,
            ),
            Direction::Short => (
                entry.entry_price * (1.0 + entry.k_stop * entry.entry_atr), // stop ABOVE for sell
                entry.entry_price * (1.0 - entry.k_tp * entry.entry_atr),   // TP BELOW for sell
                entry.entry_price,
            ),
        };
        Self {
            id: entry.id,
            entry_candle: entry.candle_idx,
            entry_price: entry.entry_price,
            entry_atr: entry.entry_atr,
            direction: entry.direction,
            base_deployed: entry.base_deployed,
            quote_held: entry.quote_received,
            base_reclaimed: 0.0,
            phase: PositionPhase::Active,
            trailing_stop: stop,
            take_profit: tp,
            extreme_price: hw,
            max_adverse: 0.0,
            total_fees: entry.entry_fee,
            candles_held: 0,
        }
    }

    /// Update position with current price. Returns exit signal if triggered.
    /// Handles both BUY (long WBTC) and SELL (short WBTC / long USDC) positions.
    pub fn tick(&mut self, current_price: f64, k_trail: TrailFactor) -> Option<PositionExit> {
        self.candles_held += 1;

        if self.phase == PositionPhase::Closed { return None; }

        // Track worst excursion against us
        let ret = self.return_pct(current_price);
        if ret < self.max_adverse { self.max_adverse = ret; }

        match self.direction {
            Direction::Long => {
                // BUY: profit when price goes UP
                if current_price > self.extreme_price {
                    self.extreme_price = current_price;
                }
                // Trail stop upward
                let new_stop = self.extreme_price * (1.0 - k_trail.0 * self.entry_atr);
                if new_stop > self.trailing_stop {
                    self.trailing_stop = new_stop;
                }
                // Stop: price fell below trailing stop
                if current_price <= self.trailing_stop {
                    return Some(PositionExit::StopLoss);
                }
                // TP: price rose above target
                if self.phase == PositionPhase::Active && current_price >= self.take_profit {
                    return Some(PositionExit::TakeProfit);
                }
            }
            Direction::Short => {
                // SELL: profit when price goes DOWN
                if current_price < self.extreme_price {
                    self.extreme_price = current_price;
                }
                // Trail stop downward
                let new_stop = self.extreme_price * (1.0 + k_trail.0 * self.entry_atr);
                if new_stop < self.trailing_stop {
                    self.trailing_stop = new_stop;
                }
                // Stop: price rose above trailing stop
                if current_price >= self.trailing_stop {
                    return Some(PositionExit::StopLoss);
                }
                // TP: price fell below target
                if self.phase == PositionPhase::Active && current_price <= self.take_profit {
                    return Some(PositionExit::TakeProfit);
                }
            }
        }

        None
    }

    /// Current return as fraction of deployed capital
    pub fn return_pct(&self, current_price: f64) -> f64 {
        if self.base_deployed <= 0.0 { return 0.0; }
        match self.direction {
            Direction::Long => {
                let wbtc_value = self.quote_held * current_price;
                (wbtc_value + self.base_reclaimed - self.total_fees) / self.base_deployed - 1.0
            }
            Direction::Short => {
                // SELL: profit = (entry_price - current_price) / entry_price
                // Simplified: we deployed USDC equivalent, price moved
                let price_change = (self.entry_price - current_price) / self.entry_price;
                price_change - self.total_fees / self.base_deployed
            }
        }
    }
}

#[derive(Clone, Copy, PartialEq)]
pub enum PositionExit {
    StopLoss,
    TakeProfit,
}
