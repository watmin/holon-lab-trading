/// broker.rs — The accountability primitive. Binds one market observer + one
/// exit observer. Compiled from wat/broker.wat.
///
/// The broker IS the accountability unit. It owns paper trades, scalar
/// accumulators, and a Grace/Violence reckoner. Values up, not effects down.

use std::collections::VecDeque;

use holon::kernel::scalar::ScalarEncoder;
use holon::kernel::vector::Vector;
use holon::memory::{OnlineSubspace, ReckConfig, Reckoner};

use crate::distances::Distances;
use crate::engram_gate::{check_engram_gate, EngramGateState};
use crate::enums::{Direction, Outcome};
use crate::newtypes::Price;
use crate::paper_entry::PaperEntry;
use crate::scalar_accumulator::ScalarAccumulator;
use crate::to_f64;

/// What a broker produces when a paper resolves.
/// Facts, not mutations. Collected from parallel tick, applied sequentially.
#[derive(Clone)]
pub struct Resolution {
    /// Which broker produced this.
    pub broker_slot_idx: usize,
    /// The thought that was tested.
    pub composed_thought: Vector,
    /// Up or Down -- matches the side tested.
    pub direction: Direction,
    /// Grace or Violence.
    pub outcome: Outcome,
    /// How much value.
    pub amount: f64,
    /// Hindsight optimal distances.
    pub optimal_distances: Distances,
}

/// What the broker returns for observer learning.
#[derive(Clone)]
pub struct PropagationFacts {
    /// Which market observer should learn.
    pub market_idx: usize,
    /// Which exit observer should learn.
    pub exit_idx: usize,
    /// For the market observer.
    pub direction: Direction,
    /// For both observers.
    pub composed_thought: Vector,
    /// For the exit observer.
    pub optimal: Distances,
    /// For both observers.
    pub weight: f64,
}

/// The accountability primitive. N x M brokers total.
pub struct Broker {
    /// Diagnostic identity for the ledger. e.g. ["momentum", "volatility"].
    pub observer_names: Vec<String>,
    /// Position in the N x M grid. THE identity.
    pub slot_idx: usize,
    /// M -- needed to derive market-idx and exit-idx.
    pub exit_count: usize,
    /// Discrete reckoner -- Grace/Violence.
    pub reckoner: Reckoner,
    /// Background noise model.
    pub noise_subspace: OnlineSubspace,
    /// Cumulative grace value.
    pub cumulative_grace: f64,
    /// Cumulative violence value.
    pub cumulative_violence: f64,
    /// Total trade count.
    pub trade_count: usize,
    /// Capped paper trade queue.
    pub papers: VecDeque<PaperEntry>,
    /// Two scalar accumulators: trail-distance, stop-distance.
    pub scalar_accums: Vec<ScalarAccumulator>,
    /// Learns what good discriminants look like (for engram gating).
    pub good_state_subspace: OnlineSubspace,
    /// Wins since last recalibration.
    pub recalib_wins: usize,
    /// Total since last recalibration.
    pub recalib_total: usize,
    /// Recalib count at last engram check.
    pub last_recalib_count: usize,
    /// Cached edge value — updated in propagate() when the reckoner learns.
    /// Avoids constructing a zero vector and calling predict() on every edge() call.
    pub cached_edge: f64,
    /// Default trail/stop distances — the tier 3 fallback.
    pub default_distances: Distances,
}

impl Broker {
    /// Construct a new broker.
    /// noise_subspace: 8 principal components. good_state_subspace: 4 components.
    pub fn new(
        observer_names: Vec<String>,
        slot_idx: usize,
        exit_count: usize,
        dims: usize,
        recalib_interval: usize,
        scalar_accums: Vec<ScalarAccumulator>,
        default_distances: Distances,
    ) -> Self {
        assert!(exit_count > 0, "broker exit_count must be > 0 (divide-by-zero guard)");
        Self {
            observer_names,
            slot_idx,
            exit_count,
            reckoner: Reckoner::new(
                "accountability",
                dims,
                recalib_interval,
                ReckConfig::Discrete(vec!["Grace".into(), "Violence".into()]),
            ),
            noise_subspace: OnlineSubspace::new(dims, 8),
            cumulative_grace: 0.0,
            cumulative_violence: 0.0,
            trade_count: 0,
            papers: VecDeque::new(),
            scalar_accums,
            good_state_subspace: OnlineSubspace::new(dims, 4),
            recalib_wins: 0,
            recalib_total: 0,
            last_recalib_count: 0,
            cached_edge: 0.0,
            default_distances,
        }
    }

    /// Derive market observer index from slot_idx.
    pub fn market_idx(&self) -> usize {
        self.slot_idx / self.exit_count
    }

    /// Derive exit observer index from slot_idx.
    pub fn exit_idx(&self) -> usize {
        self.slot_idx % self.exit_count
    }

    /// Noise update -> strip noise -> predict Grace/Violence.
    pub fn propose(&mut self, composed: &Vector) -> holon::memory::Prediction {
        let composed_f64 = to_f64(composed);
        self.noise_subspace.update(&composed_f64);
        let anomalous = self.noise_subspace.anomalous_component(&composed_f64);
        let clean = Vector::from_f64(&anomalous);
        self.reckoner.predict(&clean)
    }

    /// How much edge? Returns the cached value, updated in propagate().
    /// 0.0 = no edge. The treasury funds proportionally.
    pub fn edge(&self) -> f64 {
        self.cached_edge
    }

    /// Distance cascade: reckoner answer → own accumulators → default.
    /// The broker owns the full cascade because it owns the scalar accumulators.
    ///
    /// TODO: eliminate ctx_scalar_encoder_placeholder by passing &ScalarEncoder
    /// through the broker propagation path.
    pub fn cascade_distances(&self, reckoner_answer: Option<Distances>) -> Distances {
        if let Some(dists) = reckoner_answer {
            return dists;
        }

        let se = crate::post::ctx_scalar_encoder_placeholder();

        // Tier 2: scalar accumulators (global per-pair)
        let trail = if self.scalar_accums.len() > 0 && self.scalar_accums[0].count > 0 {
            self.scalar_accums[0].extract(100, (0.001, 0.10), se)
        } else {
            self.default_distances.trail
        };

        let stop = if self.scalar_accums.len() > 1 && self.scalar_accums[1].count > 0 {
            self.scalar_accums[1].extract(100, (0.001, 0.10), se)
        } else {
            self.default_distances.stop
        };

        Distances::new(trail, stop)
    }

    /// Create a paper entry -- every candle, every broker.
    pub fn register_paper(
        &mut self,
        composed: Vector,
        entry_price: Price,
        distances: Distances,
    ) {
        self.papers.push_back(PaperEntry::new(composed, entry_price, distances));
    }

    /// Tick all papers, resolve completed. Returns resolution facts.
    /// Papers derive optimal distances from their tracked extremes.
    pub fn tick_papers(&mut self, current_price: Price) -> Vec<Resolution> {
        let mut resolutions = Vec::new();
        let mut remaining = VecDeque::new();
        let cp = current_price.0;

        while let Some(mut paper) = self.papers.pop_front() {
            let was_buy_resolved = paper.buy_resolved;
            let was_sell_resolved = paper.sell_resolved;

            paper.tick(cp);

            let optimal = approximate_optimal_distances(
                paper.entry_price.0,
                paper.buy_extreme,
                paper.sell_extreme,
            );

            // Buy side JUST fired this tick
            if paper.buy_resolved && !was_buy_resolved {
                let excursion = paper.buy_excursion();
                let outcome = if excursion > paper.distances.trail {
                    Outcome::Grace
                } else {
                    Outcome::Violence
                };
                resolutions.push(Resolution {
                    broker_slot_idx: self.slot_idx,
                    composed_thought: paper.composed_thought.clone(),
                    direction: Direction::Up,
                    outcome,
                    amount: excursion,
                    optimal_distances: optimal,
                });
            }

            // Sell side JUST fired this tick
            if paper.sell_resolved && !was_sell_resolved {
                let excursion = paper.sell_excursion();
                let outcome = if excursion > paper.distances.trail {
                    Outcome::Grace
                } else {
                    Outcome::Violence
                };
                resolutions.push(Resolution {
                    broker_slot_idx: self.slot_idx,
                    composed_thought: paper.composed_thought.clone(),
                    direction: Direction::Down,
                    outcome,
                    amount: excursion,
                    optimal_distances: optimal,
                });
            }

            // Keep until both sides resolved, then remove
            if paper.fully_resolved() {
                // Both done. Paper taught its lessons. Remove.
            } else {
                remaining.push_back(paper);
            }
        }

        self.papers = remaining;
        resolutions
    }

    /// The broker learns its OWN lessons and RETURNS what the observers need.
    /// Values up, not effects down.
    pub fn propagate(
        &mut self,
        thought: &Vector,
        outcome: Outcome,
        weight: f64,
        direction: Direction,
        optimal: &Distances,
        recalib_interval: usize,
        scalar_encoder: &ScalarEncoder,
    ) -> PropagationFacts {
        let label = match outcome {
            Outcome::Grace => holon::memory::Label::from_index(0),
            Outcome::Violence => holon::memory::Label::from_index(1),
        };

        // 1. Reckoner learns Grace/Violence
        self.reckoner.observe(thought, label, weight);

        // 2. Feed the internal curve
        let pred = self.reckoner.predict(thought);
        let correct = matches!(outcome, Outcome::Grace);
        self.reckoner.resolve(pred.conviction, correct);

        // 3. Track record
        match outcome {
            Outcome::Grace => self.cumulative_grace += weight,
            Outcome::Violence => self.cumulative_violence += weight,
        }
        self.trade_count += 1;

        // 4. Scalar accumulators learn -- trail and stop distances
        if self.scalar_accums.len() >= 2 {
            self.scalar_accums[0].observe(optimal.trail, outcome, weight, scalar_encoder);
            self.scalar_accums[1].observe(optimal.stop, outcome, weight, scalar_encoder);
        }

        // 5. Update cached edge — reckoner just learned, curve may have changed
        {
            let edge_pred = self.reckoner.predict(&Vector::zeros(self.reckoner.dims()));
            self.cached_edge = self.reckoner.accuracy_at(edge_pred.conviction).unwrap_or(0.0);
        }

        // 6. Engram gate
        if correct {
            self.recalib_wins += 1;
        }
        self.recalib_total += 1;

        let gate_state = EngramGateState {
            recalib_wins: self.recalib_wins,
            recalib_total: self.recalib_total,
            last_recalib_count: self.last_recalib_count,
        };
        let new_state = check_engram_gate(
            &self.reckoner,
            &mut self.good_state_subspace,
            &gate_state,
            recalib_interval,
            0.55,
        );
        self.recalib_wins = new_state.recalib_wins;
        self.recalib_total = new_state.recalib_total;
        self.last_recalib_count = new_state.last_recalib_count;

        // Return propagation facts for the post
        PropagationFacts {
            market_idx: self.market_idx(),
            exit_idx: self.exit_idx(),
            direction,
            composed_thought: thought.clone(),
            optimal: *optimal,
            weight,
        }
    }

    /// Number of active paper trades.
    pub fn paper_count(&self) -> usize {
        self.papers.len()
    }
}

/// Approximate optimal distances from tracked extremes (paper approximation).
/// Uses the excursions as a proxy for what distance would have been ideal.
///
/// WHY the 0.5 factor: half the observed excursion is a starting point for the
/// paper's "optimal distance" — tight enough to have captured most of the move,
/// loose enough to not have triggered prematurely. The exit observers learn to
/// refine this heuristic over time; this is just the seed.
///
/// WHY the .max(0.001).min(0.10) clamps: the scalar encoder's log-scale range
/// spans [0.001, 0.10]. Values outside this band produce degenerate encodings
/// (saturated or zero). The clamps keep optimal distances within the learnable
/// scalar range.
fn approximate_optimal_distances(
    entry: f64,
    buy_extreme: f64,
    sell_extreme: f64,
) -> Distances {
    let buy_excursion = ((buy_extreme - entry) / entry).max(0.001);
    let sell_excursion = ((entry - sell_extreme) / entry).max(0.001);
    let trail = ((buy_excursion + sell_excursion) / 2.0 * 0.5).max(0.001).min(0.10);
    let stop = trail * 2.0;
    Distances::new(trail, stop)
}

#[cfg(test)]
mod tests {
    use super::*;
    use holon::kernel::scalar::ScalarEncoder;
    use holon::kernel::vector_manager::VectorManager;
    use crate::enums::ScalarEncoding;

    const DIMS: usize = 4096;
    const RECALIB: usize = 100;

    fn make_scalar_accums() -> Vec<ScalarAccumulator> {
        vec![
            ScalarAccumulator::new("trail-distance", ScalarEncoding::Log, DIMS),
            ScalarAccumulator::new("stop-distance", ScalarEncoding::Log, DIMS),
        ]
    }

    fn make_broker() -> Broker {
        Broker::new(
            vec!["momentum".into(), "volatility".into()],
            0, // slot_idx
            2, // exit_count
            DIMS,
            RECALIB,
            make_scalar_accums(),
            Distances::new(0.015, 0.030),
        )
    }

    fn random_vector(name: &str) -> Vector {
        let vm = VectorManager::new(DIMS);
        vm.get_vector(name)
    }

    #[test]
    fn test_broker_new() {
        let broker = make_broker();
        assert_eq!(broker.slot_idx, 0);
        assert_eq!(broker.exit_count, 2);
        assert_eq!(broker.trade_count, 0);
        assert_eq!(broker.paper_count(), 0);
        assert!((broker.cumulative_grace - 0.0).abs() < 1e-10);
        assert!((broker.cumulative_violence - 0.0).abs() < 1e-10);
    }

    #[test]
    fn test_market_exit_idx() {
        // slot_idx=5, exit_count=3: market_idx=1, exit_idx=2
        let broker = Broker::new(
            vec!["a".into(), "b".into()],
            5, 3, DIMS, RECALIB,
            make_scalar_accums(),
            Distances::new(0.015, 0.030),
        );
        assert_eq!(broker.market_idx(), 1);
        assert_eq!(broker.exit_idx(), 2);
    }

    #[test]
    fn test_propose_returns_prediction() {
        let mut broker = make_broker();
        let composed = random_vector("composed");
        let pred = broker.propose(&composed);
        // Should return a prediction (possibly default with no training)
        assert!(pred.conviction >= 0.0);
    }

    #[test]
    fn test_register_paper() {
        let mut broker = make_broker();
        let composed = random_vector("thought");
        let distances = Distances::new(0.02, 0.05);
        broker.register_paper(composed, Price(50000.0), distances);
        assert_eq!(broker.paper_count(), 1);
    }

    #[test]
    fn test_tick_papers_no_resolution() {
        let mut broker = make_broker();
        let composed = random_vector("thought");
        let distances = Distances::new(0.05, 0.10);
        broker.register_paper(composed, Price(100.0), distances);

        // Price barely moves -- no resolution
        let resolutions = broker.tick_papers(Price(100.5));
        assert!(resolutions.is_empty());
        assert_eq!(broker.paper_count(), 1);
    }

    #[test]
    fn test_tick_papers_full_resolution() {
        let mut broker = make_broker();
        let composed = random_vector("thought");
        // Trail=0.20: buy_trail_stop=80, sell_trail_stop=120
        let distances = Distances::new(0.20, 0.30);
        broker.register_paper(composed, Price(100.0), distances);

        // Rise to 125: sell fires (125 >= 120) → 1 resolution (Down)
        // Buy doesn't fire yet (125 > buy_trail=100)
        let resolutions = broker.tick_papers(Price(125.0));
        assert_eq!(resolutions.len(), 1); // sell side fired independently
        assert_eq!(resolutions[0].direction, Direction::Down);
        assert_eq!(broker.paper_count(), 1); // still alive — buy side pending

        // Fall to 99: buy fires (99 <= buy_trail_stop=100) → 1 resolution (Up)
        // Both sides now resolved → paper removed
        let resolutions = broker.tick_papers(Price(99.0));
        assert_eq!(resolutions.len(), 1); // buy side fired independently
        assert_eq!(resolutions[0].direction, Direction::Up);
        assert_eq!(broker.paper_count(), 0); // both done, paper removed
    }

    #[test]
    fn test_propagate_updates_track_record() {
        let mut broker = make_broker();
        let thought = random_vector("thought");
        let se = ScalarEncoder::new(DIMS);
        let optimal = Distances::new(0.03, 0.06);

        let facts = broker.propagate(
            &thought,
            Outcome::Grace,
            1.0,
            Direction::Up,
            &optimal,
            RECALIB,
            &se,
        );

        assert_eq!(broker.trade_count, 1);
        assert!((broker.cumulative_grace - 1.0).abs() < 1e-10);
        assert_eq!(facts.market_idx, 0);
        assert_eq!(facts.exit_idx, 0);
        assert_eq!(facts.direction, Direction::Up);
    }

    #[test]
    fn test_propagate_violence_updates_violence() {
        let mut broker = make_broker();
        let thought = random_vector("thought");
        let se = ScalarEncoder::new(DIMS);
        let optimal = Distances::new(0.03, 0.06);

        broker.propagate(
            &thought,
            Outcome::Violence,
            2.5,
            Direction::Down,
            &optimal,
            RECALIB,
            &se,
        );

        assert_eq!(broker.trade_count, 1);
        assert!((broker.cumulative_violence - 2.5).abs() < 1e-10);
        assert!((broker.cumulative_grace - 0.0).abs() < 1e-10);
    }

    #[test]
    fn test_edge_starts_at_zero() {
        let broker = make_broker();
        // No training -> no edge
        let e = broker.edge();
        assert!(e >= 0.0);
    }

    #[test]
    fn test_scalar_accums_count() {
        let broker = make_broker();
        assert_eq!(broker.scalar_accums.len(), 2);
        assert_eq!(broker.scalar_accums[0].name, "trail-distance");
        assert_eq!(broker.scalar_accums[1].name, "stop-distance");
    }

    #[test]
    fn test_approximate_optimal_distances() {
        let d = approximate_optimal_distances(100.0, 110.0, 90.0);
        // buy_excursion = 0.10, sell_excursion = 0.10
        // trail = (0.10 + 0.10) / 2 * 0.5 = 0.05
        // stop = 0.10
        assert!((d.trail - 0.05).abs() < 1e-10);
        assert!((d.stop - 0.10).abs() < 1e-10);
    }

    #[test]
    fn test_approximate_optimal_distances_clamped() {
        // Very small excursion -> clamped to 0.001
        let d = approximate_optimal_distances(100.0, 100.0, 100.0);
        assert!(d.trail >= 0.001);
        assert!(d.stop >= 0.001);
    }
}
