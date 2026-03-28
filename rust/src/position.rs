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
