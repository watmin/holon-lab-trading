//! A Desk is a business unit within the enterprise.
//!
//! Each desk looks at the market through its own time scale (window size),
//! runs its own set of expert traders, maintains its own pending positions,
//! and builds its own paper trail. The treasury reads the paper trails
//! and allocates capital to desks whose traders prove edge.
//!
//! Desks don't know about each other. The treasury sees everything.

use std::collections::VecDeque;

use holon::{VectorManager, Vector};

use crate::journal::{Journal, Outcome, Prediction};
use crate::thought::{ThoughtEncoder, ThoughtVocab, IndicatorStreams};
use crate::position::{Pending, ExitReason};
use crate::db::Candle;

/// One expert trader within a desk.
pub struct Expert {
    pub name: &'static str,
    pub profile: &'static str,
    pub journal: Journal,
    pub resolved: VecDeque<(f64, bool)>,
    pub recalib_total: u32,
    pub recalib_wins: u32,
    pub last_recalib_count: u64,
    pub good_state_subspace: holon::memory::OnlineSubspace,
}

/// A desk's configuration — its identity.
pub struct DeskConfig {
    pub name: String,
    pub window: usize,
    pub horizon: usize,
    pub expert_profiles: Vec<&'static str>,
}

/// A desk's live state — its memory.
pub struct Desk {
    pub config: DeskConfig,
    pub thought_encoder: ThoughtEncoder,
    pub thought_streams: IndicatorStreams,
    pub generalist: Journal,
    pub experts: Vec<Expert>,
    pub pending: VecDeque<Pending>,

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

        let generalist = Journal::new(
            &format!("{}-generalist", config.name),
            dims,
            recalib_interval,
        );

        let experts: Vec<Expert> = config.expert_profiles.iter().map(|&profile| {
            Expert {
                name: profile,
                profile,
                journal: Journal::new(
                    &format!("{}-{}", config.name, profile),
                    dims,
                    recalib_interval,
                ),
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
            experts,
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
        let expert_vecs: Vec<Vector> = self.config.expert_profiles.iter()
            .map(|&profile| {
                self.thought_encoder.encode_view(
                    candles, &self.thought_streams, 0, 0, vm, None, None, profile,
                ).thought
            })
            .collect();
        (full.thought, full.fact_labels, expert_vecs)
    }

    /// Predict direction from a thought vector using the generalist.
    pub fn predict(&self, thought: &Vector) -> Prediction {
        self.generalist.predict(thought)
    }

    /// Decay all journals by one step.
    pub fn decay(&mut self, rate: f64) {
        self.generalist.decay(rate);
        for expert in &mut self.experts {
            expert.journal.decay(rate);
        }
    }
}
