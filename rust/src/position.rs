use holon::Vector;
use crate::journal::{Outcome, Prediction};

// ─── Pending entry ───────────────────────────────────────────────────────────

pub struct Pending {
    pub candle_idx:    usize,
    pub year:          i32,
    pub vis_vec:       Vector,
    pub tht_vec:       Vector,

    // ── Prediction (what the experts said) ────────────────────────────
    pub vis_pred:      Prediction,
    pub tht_pred:      Prediction,
    pub raw_meta_dir:  Option<Outcome>,  // un-flipped direction (for auto calibration)
    pub meta_dir:      Option<Outcome>,
    pub was_flipped:   bool,             // true if flip was active when this entry was created
    pub meta_conviction: f64,
    pub position_frac: Option<f64>,
    pub expert_vecs:   Vec<Vector>,       // per-expert thought vectors
    pub expert_preds:  Vec<Prediction>,   // per-expert predictions at entry time
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
            trailing_stop: entry_price * (1.0 - k_stop * entry_atr),
            take_profit: entry_price * (1.0 + k_tp * entry_atr),
            high_water: entry_price,
            total_fees: entry_fee,
            candles_held: 0,
        }
    }

    /// Update position with current price. Returns exit signal if triggered.
    pub fn tick(&mut self, current_price: f64, k_trail: f64) -> Option<PositionExit> {
        self.candles_held += 1;

        if self.phase == PositionPhase::Closed { return None; }

        // Update high water mark
        if current_price > self.high_water {
            self.high_water = current_price;
        }

        // Raise trailing stop
        let new_stop = self.high_water * (1.0 - k_trail * self.entry_atr);
        if new_stop > self.trailing_stop {
            self.trailing_stop = new_stop;
        }

        // Check stop loss
        if current_price <= self.trailing_stop {
            return Some(PositionExit::StopLoss);
        }

        // Check take profit (only in Active phase — runners don't have TP)
        if self.phase == PositionPhase::Active && current_price >= self.take_profit {
            return Some(PositionExit::TakeProfit);
        }

        None
    }

    /// Current unrealized P&L in USDC
    pub fn unrealized_pnl(&self, current_price: f64) -> f64 {
        let wbtc_value = self.wbtc_held * current_price;
        wbtc_value - self.usdc_deployed + self.usdc_reclaimed - self.total_fees
    }

    /// Current return as fraction of deployed capital
    pub fn return_pct(&self, current_price: f64) -> f64 {
        if self.usdc_deployed <= 0.0 { return 0.0; }
        let wbtc_value = self.wbtc_held * current_price;
        (wbtc_value + self.usdc_reclaimed - self.total_fees) / self.usdc_deployed - 1.0
    }
}

#[derive(Clone, Copy, PartialEq)]
pub enum PositionExit {
    StopLoss,
    TakeProfit,
}
