use holon::Vector;
use crate::journal::{Outcome, Prediction};

// ─── Exit observation ───────────────────────────────────────────────────────

/// Snapshot of position state for deferred exit expert learning.
/// Resolves after exit_horizon candles: did holding improve the position?
pub struct ExitObservation {
    pub thought: Vector,
    pub pos_id: usize,
    pub snapshot_pnl: f64,
    pub snapshot_candle: usize,
}

// ─── Pending entry ───────────────────────────────────────────────────────────

pub struct Pending {
    pub candle_idx:    usize,
    pub year:          i32,
    pub tht_vec:       Vector,

    // ── Prediction (what the experts said) ────────────────────────────
    pub tht_pred:      Prediction,
    pub raw_meta_dir:  Option<Outcome>,  // un-flipped direction (for auto calibration)
    pub meta_dir:      Option<Outcome>,
    pub was_flipped:   bool,             // true if flip was active when this entry was created
    pub meta_conviction: f64,
    pub position_frac: Option<f64>,
    pub observer_vecs:   Vec<Vector>,       // per-observer thought vectors
    pub observer_preds:  Vec<Prediction>,   // per-observer predictions at entry time
    pub mgr_thought:     Option<Vector>,    // complete manager thought (delta-enriched) for learning
    pub fact_labels:   Vec<String>,      // thought facts present at this candle

    // ── Learning (event-driven, first crossing only) ─────────────────
    pub first_outcome: Option<Outcome>, // set on first threshold crossing; drives learning
    pub outcome_pct:   f64,             // price change at first crossing (for DB)

    // ── Accounting (pure measurement, no hallucination) ──────────────
    pub entry_price:       f64,
    pub max_favorable:     f64,    // best price move in our direction
    pub max_adverse:       f64,    // worst price move against us (negative)
    pub peak_abs_pct:      f64,    // max |price change| seen while pending
    pub crossing_candle:   Option<usize>, // candle index when threshold first crossed
    pub path_candles:      usize,  // candles elapsed since entry

    // ── Trade management (the enterprise) ────────────────────────────
    pub trailing_stop:     f64,    // current stop level (pct from entry, starts negative)
    pub exit_reason:       Option<ExitReason>, // why the trade closed
    pub exit_pct:          f64,    // actual exit price change (for P&L)

    // ── Treasury allocation ──────────────────────────────────────────
    pub deployed_usd:      f64,    // capital reserved from treasury for this position
}

#[derive(Clone, Copy, PartialEq)]
pub enum ExitReason {
    ThresholdCrossing,   // legacy: exit at first threshold crossing
    TrailingStop,        // stop loss hit (including raised stops)
    TakeProfit,          // target reached
    HorizonExpiry,       // ran out of time
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
    pub direction:      Outcome,    // Buy (long WBTC) or Sell (back to USDC)

    // Capital
    pub usdc_deployed:  f64,        // USDC spent to enter
    pub wbtc_held:      f64,        // WBTC currently held in this position
    pub usdc_reclaimed: f64,        // USDC recovered from partial exits

    // Management
    pub phase:          PositionPhase,
    pub trailing_stop:  f64,        // absolute price level
    pub take_profit:    f64,        // absolute price level (first target)
    pub high_water:     f64,        // highest price seen since entry

    // Accounting
    pub total_fees:     f64,        // cumulative fees paid (entry + partials + exit)
    pub candles_held:   usize,      // how long this position has been open
}

impl ManagedPosition {
    pub fn new(
        id: usize,
        candle_idx: usize,
        entry_price: f64,
        entry_atr: f64,
        direction: Outcome,
        usdc_deployed: f64,
        wbtc_received: f64,
        entry_fee: f64,
        k_stop: f64,
        k_tp: f64,
    ) -> Self {
        // BUY: stop below entry, TP above. SELL: stop above, TP below.
        let (stop, tp, hw) = match direction {
            Outcome::Buy => (
                entry_price * (1.0 - k_stop * entry_atr),
                entry_price * (1.0 + k_tp * entry_atr),
                entry_price,
            ),
            _ => (
                entry_price * (1.0 + k_stop * entry_atr), // stop ABOVE for sell
                entry_price * (1.0 - k_tp * entry_atr),   // TP BELOW for sell
                entry_price,
            ),
        };
        Self {
            id,
            entry_candle: candle_idx,
            entry_price,
            entry_atr,
            direction,
            usdc_deployed,
            wbtc_held: wbtc_received,
            usdc_reclaimed: 0.0,
            phase: PositionPhase::Active,
            trailing_stop: stop,
            take_profit: tp,
            high_water: hw,
            total_fees: entry_fee,
            candles_held: 0,
        }
    }

    /// Update position with current price. Returns exit signal if triggered.
    /// Handles both BUY (long WBTC) and SELL (short WBTC / long USDC) positions.
    pub fn tick(&mut self, current_price: f64, k_trail: f64) -> Option<PositionExit> {
        self.candles_held += 1;

        if self.phase == PositionPhase::Closed { return None; }

        match self.direction {
            Outcome::Buy => {
                // BUY: profit when price goes UP
                if current_price > self.high_water {
                    self.high_water = current_price;
                }
                // Trail stop upward
                let new_stop = self.high_water * (1.0 - k_trail * self.entry_atr);
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
            _ => {
                // SELL: profit when price goes DOWN
                if current_price < self.high_water {
                    self.high_water = current_price; // "high water" is actually low water for sells
                }
                // Trail stop downward
                let new_stop = self.high_water * (1.0 + k_trail * self.entry_atr);
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

    /// Current unrealized P&L in USDC
    pub fn unrealized_pnl(&self, current_price: f64) -> f64 {
        match self.direction {
            Outcome::Buy => {
                // BUY: we hold WBTC, value = wbtc × price
                let wbtc_value = self.wbtc_held * current_price;
                wbtc_value - self.usdc_deployed + self.usdc_reclaimed - self.total_fees
            }
            _ => {
                // SELL: we sold WBTC for USDC. Profit if price dropped.
                // We deployed usdc_deployed worth of WBTC at entry_price.
                // If price dropped, buying back costs less → profit.
                let buyback_cost = self.wbtc_held * current_price; // cost to buy back remaining WBTC
                self.usdc_reclaimed - buyback_cost - self.total_fees
            }
        }
    }

    /// Current return as fraction of deployed capital
    pub fn return_pct(&self, current_price: f64) -> f64 {
        if self.usdc_deployed <= 0.0 { return 0.0; }
        match self.direction {
            Outcome::Buy => {
                let wbtc_value = self.wbtc_held * current_price;
                (wbtc_value + self.usdc_reclaimed - self.total_fees) / self.usdc_deployed - 1.0
            }
            _ => {
                // SELL: profit = (entry_price - current_price) / entry_price
                // Simplified: we deployed USDC equivalent, price moved
                let price_change = (self.entry_price - current_price) / self.entry_price;
                price_change - self.total_fees / self.usdc_deployed
            }
        }
    }
}

#[derive(Clone, Copy, PartialEq)]
pub enum PositionExit {
    StopLoss,
    TakeProfit,
}
