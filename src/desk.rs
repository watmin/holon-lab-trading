//! A Desk is a business unit within the enterprise.
//!
//! Each desk looks at the market through its own time scale (window size),
//! runs its own set of observers, maintains its own pending positions,
//! and builds its own paper trail. The treasury reads the paper trails
//! and allocates capital to desks whose traders prove edge.
//!
//! Desks don't know about each other. The treasury sees everything.

use std::collections::VecDeque;

use holon::{VectorManager, Vector};

use crate::journal::{Journal, Outcome, Prediction};
use crate::thought::{ThoughtEncoder, ThoughtVocab, IndicatorStreams};
use crate::db::Candle;

/// One observer within a desk.
pub struct Observer {
    pub name: &'static str,
    pub profile: &'static str,
    pub journal: Journal,
    pub resolved: VecDeque<(f64, bool)>,
    pub recalib_total: u32,
    pub recalib_wins: u32,
    pub last_recalib_count: u64,
    pub good_state_subspace: holon::memory::OnlineSubspace,
}

/// A desk-local pending entry. Lightweight — just enough for learning.
pub struct DeskPending {
    pub candle_idx: usize,
    pub thought: Vector,
    pub prediction: Prediction,
    pub first_outcome: Option<Outcome>,
    pub outcome_pct: f64,
}

/// A resolved desk prediction — returned to the main loop for DB logging.
pub struct DeskResolved {
    pub desk_name: String,
    pub candle_idx: usize,
    pub conviction: f64,
    pub direction: Option<Outcome>,   // flipped
    pub outcome: Outcome,
    pub correct: bool,
    pub gross_pct: f64,
    pub window: usize,
    pub horizon: usize,
}

/// A desk's configuration — its identity.
pub struct DeskConfig {
    pub name: String,
    pub window: usize,
    pub horizon: usize,
    pub observer_names: Vec<&'static str>,
}

/// A desk's live state — its memory.
pub struct Desk {
    pub config: DeskConfig,
    pub thought_encoder: ThoughtEncoder,
    pub thought_streams: IndicatorStreams,
    pub generalist: Journal,
    pub observers: Vec<Observer>,
    pub pending: VecDeque<DeskPending>,

    // Paper trail: predictions + outcomes, regardless of capital deployment.
    pub resolved_preds: VecDeque<(f64, bool)>,
    pub conviction_history: VecDeque<f64>,
    pub flip_threshold: f64,

    // Curve state: does this desk have proven edge?
    pub curve_valid: bool,
    pub cached_curve_a: f64,
    pub cached_curve_b: f64,

    // Stats
    pub encode_count: usize,
    pub labeled_count: usize,
    pub noise_count: usize,
}

impl Desk {
    pub fn new(config: DeskConfig, dims: usize, recalib_interval: usize, vm: &VectorManager) -> Self {
        let vocab = ThoughtVocab::new(vm);
        let thought_streams = IndicatorStreams::new(dims, config.window);
        let thought_encoder = ThoughtEncoder::new(vocab);

        // Leak formatted names to get 'static lifetimes. Fine for small N desks.
        let gen_name: &'static str = Box::leak(format!("{}-generalist", config.name).into_boxed_str());
        let generalist = Journal::new(gen_name, dims, recalib_interval);

        let observers: Vec<Observer> = config.observer_names.iter().map(|&profile| {
            let observer_name: &'static str = Box::leak(format!("{}-{}", config.name, profile).into_boxed_str());
            Observer {
                name: profile,
                profile,
                journal: Journal::new(observer_name, dims, recalib_interval),
                resolved: VecDeque::new(),
                recalib_total: 0,
                recalib_wins: 0,
                last_recalib_count: 0,
                good_state_subspace: holon::memory::OnlineSubspace::new(dims, 8),
            }
        }).collect();

        Self {
            config,
            thought_encoder,
            thought_streams,
            generalist,
            observers,
            pending: VecDeque::new(),
            resolved_preds: VecDeque::new(),
            conviction_history: VecDeque::new(),
            flip_threshold: 0.0,
            curve_valid: false,
            cached_curve_a: 0.0,
            cached_curve_b: 0.0,
            encode_count: 0,
            labeled_count: 0,
            noise_count: 0,
        }
    }

    /// The window this desk uses to slice candle history.
    pub fn window(&self) -> usize {
        self.config.window
    }

    /// The horizon this desk uses for trade resolution.
    pub fn horizon(&self) -> usize {
        self.config.horizon
    }

    /// Has this desk proven its edge? The treasury checks this.
    pub fn has_proven_edge(&self) -> bool {
        self.curve_valid
    }

    /// Encode a candle window into a thought vector using this desk's encoder.
    pub fn encode(
        &self,
        candles: &[Candle],
        vm: &VectorManager,
    ) -> (Vector, Vec<String>, Vec<Vector>) {
        let full = self.thought_encoder.encode_view(
            candles, &self.thought_streams, 0, 0, vm, None, None, "full",
        );
        let observer_vecs: Vec<Vector> = self.config.observer_names.iter()
            .map(|&profile| {
                self.thought_encoder.encode_view(
                    candles, &self.thought_streams, 0, 0, vm, None, None, profile,
                ).thought
            })
            .collect();
        (full.thought, full.fact_labels, observer_vecs)
    }

    /// Predict direction from a thought vector using the generalist.
    pub fn predict(&self, thought: &Vector) -> Prediction {
        self.generalist.predict(thought)
    }

    /// Decay all journals by one step.
    pub fn decay(&mut self, rate: f64) {
        self.generalist.decay(rate);
        for observer in &mut self.observers {
            observer.journal.decay(rate);
        }
    }

    /// Buffer a prediction for future learning.
    pub fn buffer_prediction(&mut self, candle_idx: usize, thought: Vector, prediction: Prediction) {
        self.pending.push_back(DeskPending {
            candle_idx,
            thought,
            prediction,
            first_outcome: None,
            outcome_pct: 0.0,
        });
    }

    /// Event-driven learning: scan pending entries, learn on first threshold crossing.
    /// Then expire entries past horizon. Returns resolved predictions for DB logging.
    pub fn learn_and_resolve(
        &mut self,
        current_candle_idx: usize,
        candles: &[Candle],
        move_threshold: f64,
        atr_multiplier: f64,
    ) -> Vec<DeskResolved> {
        let mut resolved = Vec::new();

        // Phase 1: scan for threshold crossings (learning)
        let current_price = candles[current_candle_idx].close;
        for entry in self.pending.iter_mut() {
            if entry.first_outcome.is_some() { continue; }
            let entry_price = candles[entry.candle_idx].close;
            let pct = (current_price - entry_price) / entry_price;

            let thresh = if atr_multiplier > 0.0 {
                atr_multiplier * candles[entry.candle_idx].atr_r
            } else {
                move_threshold
            };

            let outcome = if pct > thresh { Some(Outcome::Buy) }
                          else if pct < -thresh { Some(Outcome::Sell) }
                          else { None };

            if let Some(o) = outcome {
                entry.first_outcome = Some(o);
                entry.outcome_pct = pct;
                self.generalist.observe(&entry.thought, o, 1.0);
            }
        }

        // Phase 2: expire entries past horizon
        let horizon = self.config.horizon;
        while let Some(front) = self.pending.front() {
            if current_candle_idx - front.candle_idx < horizon { break; }
            let entry = self.pending.pop_front().unwrap();
            let final_out = entry.first_outcome.unwrap_or(Outcome::Noise);

            match final_out {
                Outcome::Noise => self.noise_count += 1,
                _ => {
                    self.labeled_count += 1;
                    if let Some(pred_dir) = entry.prediction.direction {
                        let flipped = match pred_dir {
                            Outcome::Buy => Outcome::Sell,
                            Outcome::Sell => Outcome::Buy,
                            Outcome::Noise => Outcome::Noise,
                        };
                        let correct = flipped == final_out;
                        self.resolved_preds.push_back((entry.prediction.conviction, correct));
                        if self.resolved_preds.len() > 5000 {
                            self.resolved_preds.pop_front();
                        }

                        resolved.push(DeskResolved {
                            desk_name: self.config.name.clone(),
                            candle_idx: entry.candle_idx,
                            conviction: entry.prediction.conviction,
                            direction: Some(flipped),
                            outcome: final_out,
                            correct,
                            gross_pct: entry.outcome_pct,
                            window: self.config.window,
                            horizon: self.config.horizon,
                        });
                    }
                }
            }
        }

        resolved
    }

    /// Rolling accuracy from resolved predictions.
    pub fn rolling_accuracy(&self, window: usize) -> f64 {
        if self.resolved_preds.is_empty() { return 0.5; }
        let recent: Vec<&(f64, bool)> = self.resolved_preds.iter().rev().take(window).collect();
        if recent.is_empty() { return 0.5; }
        recent.iter().filter(|(_, correct)| *correct).count() as f64 / recent.len() as f64
    }
}
