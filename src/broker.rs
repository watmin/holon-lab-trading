/// broker.rs — The accountability primitive. Binds one market observer + one
/// exit observer. Compiled from wat/broker.wat.
///
/// The broker IS the accountability unit. It owns paper trades, scalar
/// accumulators, and a Grace/Violence reckoner. Values up, not effects down.

use std::collections::{HashMap, VecDeque};

use holon::kernel::scalar::ScalarEncoder;
use holon::kernel::vector::Vector;
use holon::memory::{OnlineSubspace, ReckConfig, Reckoner};

use crate::distances::Distances;
use crate::engram_gate::{check_engram_gate, EngramGateState};
use crate::enums::{Direction, Outcome};
use crate::simulation;
use crate::newtypes::Price;
use crate::paper_entry::PaperEntry;
use crate::scalar_accumulator::ScalarAccumulator;
use crate::to_f64;

/// Accumulated history for a runner paper. Created when a paper signals Grace.
/// Stores per-candle data for deferred batch training of the exit observer.
#[derive(Clone)]
pub struct RunnerHistory {
    pub thoughts: Vec<Vector>,
    pub distances: Vec<Distances>,
    pub prices: Vec<f64>,
}

/// What a broker produces when a paper resolves or signals.
/// Facts, not mutations. Collected from parallel tick, applied sequentially.
#[derive(Clone)]
pub struct Resolution {
    /// Which broker produced this.
    pub broker_slot_idx: usize,
    /// The composed thought (market + exit) that was tested.
    pub composed_thought: Vector,
    /// The raw market thought (for market observer learning).
    pub market_thought: Vector,
    /// The exit observer's own encoded facts (for exit observer learning).
    /// Proposal 026: exit learns from exit_thought, not composed.
    pub exit_thought: Vector,
    /// What the market observer predicted.
    pub prediction: Direction,
    /// Grace or Violence.
    pub outcome: Outcome,
    /// How much value (excursion or stop distance).
    pub amount: f64,
    /// Hindsight optimal distances.
    pub optimal_distances: Distances,
    /// Paper details for diagnostics.
    pub entry_price: f64,
    pub extreme: f64,
    pub excursion: f64,
    pub trail_distance: f64,
    pub stop_distance: f64,
    pub duration: usize,
    /// Did the trail cross before resolution?
    pub was_runner: bool,
    /// Deferred batch training data for the exit observer.
    /// Each entry: (thought_at_candle, optimal_distances_at_candle, weight).
    /// Empty for non-runner resolutions.
    pub exit_batch: Vec<(Vector, Distances, f64)>,
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
    /// For the market observer — the anomaly it predicted on.
    /// Proposal 024: market observer learns from the anomaly, not composed thought.
    pub market_thought: Vector,
    /// For the exit observer — its own encoded facts, NOT the composition.
    /// Proposal 026: exit observer learns from exit_thought only.
    pub exit_thought: Vector,
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
    /// Current active direction — the broker's stance. None = cold start.
    pub active_direction: Option<Direction>,
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
    /// Cached edge value — updated in propose() from the curve at THIS conviction.
    pub cached_edge: f64,
    /// Default trail/stop distances — the tier 3 fallback.
    pub default_distances: Distances,
    /// Running average paper duration (candles). Self-assessment vocab.
    pub avg_paper_duration: f64,
    /// Running average excursion. Self-assessment vocab.
    pub avg_excursion: f64,
    /// Last trail distance used. Self-assessment vocab.
    pub last_trail: f64,
    /// Last stop distance used. Self-assessment vocab.
    pub last_stop: f64,
    /// Count of resolved sides (for running average computation).
    pub resolution_count: usize,
    /// Monotonic counter for paper IDs.
    pub next_paper_id: usize,
    /// Per-runner accumulated history for deferred batch training.
    pub runner_histories: HashMap<usize, RunnerHistory>,
    /// The broker's noise-stripped composed thought from the last propose().
    /// Proposal 024: the broker predicts on and learns from the same anomaly.
    pub last_composed_anomaly: Option<Vector>,
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
            active_direction: None,
            papers: VecDeque::new(),
            scalar_accums,
            good_state_subspace: OnlineSubspace::new(dims, 4),
            recalib_wins: 0,
            recalib_total: 0,
            last_recalib_count: 0,
            cached_edge: 0.0,
            default_distances,
            avg_paper_duration: 0.0,
            avg_excursion: 0.0,
            last_trail: 0.0,
            last_stop: 0.0,
            resolution_count: 0,
            next_paper_id: 0,
            runner_histories: HashMap::new(),
            last_composed_anomaly: None,
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

    /// Predict Grace/Violence on the composed thought.
    /// Proposal 024: noise subspace learns the background, anomalous_component
    /// strips it. The reckoner predicts on the anomaly. The anomaly is stored
    /// for aligned learning in propagate().
    /// Updates cached_edge from the curve at THIS conviction.
    pub fn propose(&mut self, composed: &Vector) -> holon::memory::Prediction {
        let composed_f64 = to_f64(composed);
        self.noise_subspace.update(&composed_f64);

        // Strip noise — predict on the anomaly
        let anomalous = self.noise_subspace.anomalous_component(&composed_f64);
        let anomaly = Vector::from_f64(&anomalous);
        let pred = self.reckoner.predict(&anomaly);
        self.cached_edge = self.reckoner.accuracy_at(pred.conviction).unwrap_or(0.0);

        // Store for aligned learning in propagate()
        self.last_composed_anomaly = Some(anomaly);

        pred
    }

    /// How much edge? Accuracy at the conviction of the last proposal.
    /// 0.0 = curve not valid or no conviction. The treasury funds proportionally.
    pub fn edge(&self) -> f64 {
        self.cached_edge
    }

    /// Distance cascade: reckoner answer -> own accumulators -> default.
    /// The broker owns the full cascade because it owns the scalar accumulators.
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

    /// Create a paper entry — every candle, every broker.
    /// Takes the market observer's prediction, raw market thought, and exit thought.
    /// Proposal 026: exit_thought stored on paper for aligned exit observer learning.
    pub fn register_paper(
        &mut self,
        composed: Vector,
        market_thought: Vector,
        exit_thought: Vector,
        prediction: Direction,
        entry_price: Price,
        distances: Distances,
    ) {
        let paper_id = self.next_paper_id;
        self.next_paper_id += 1;
        self.papers.push_back(PaperEntry::new(
            paper_id,
            composed,
            market_thought,
            exit_thought,
            prediction,
            entry_price,
            distances,
        ));
    }

    /// Close all runners — direction flipped. Force-resolve all signaled papers.
    /// Returns runner resolutions for exit batch training + market second teaching.
    pub fn close_all_runners(&mut self, current_price: Price) -> Vec<Resolution> {
        let mut resolutions = Vec::new();
        let mut remaining = VecDeque::new();
        let _cp = current_price.0;

        while let Some(mut paper) = self.papers.pop_front() {
            if paper.signaled && !paper.resolved {
                // Force-resolve the runner at current price
                paper.resolved = true;
                let optimal = simulation::compute_optimal_distances(
                    &paper.price_history, paper.prediction,
                );
                let exit_batch = if let Some(history) = self.runner_histories.remove(&paper.paper_id) {
                    compute_exit_batch(&history, paper.prediction)
                } else {
                    Vec::new()
                };

                resolutions.push(Resolution {
                    broker_slot_idx: self.slot_idx,
                    composed_thought: paper.composed_thought.clone(),
                    market_thought: paper.market_thought.clone(),
                    exit_thought: paper.exit_thought.clone(),
                    prediction: paper.prediction,
                    outcome: Outcome::Grace,
                    amount: paper.excursion(),
                    optimal_distances: optimal,
                    entry_price: paper.entry_price.0,
                    extreme: paper.extreme,
                    excursion: paper.excursion(),
                    trail_distance: paper.distances.trail,
                    stop_distance: paper.distances.stop,
                    duration: paper.age,
                    was_runner: true,
                    exit_batch,
                });
            } else if !paper.resolved {
                // Non-runner papers survive the flip (they'll hit stop naturally)
                remaining.push_back(paper);
            }
            // Resolved papers (stop-fired) are already removed normally
        }

        self.papers = remaining;
        resolutions
    }

    /// Tick all papers, resolve completed. Returns two vecs:
    /// - market_signals: for market observer learning (Grace or Violence)
    /// - runner_resolutions: for exit observer + broker learning (runner finished)
    pub fn tick_papers(&mut self, current_price: Price) -> (Vec<Resolution>, Vec<Resolution>) {
        let mut market_signals = Vec::new();
        let mut runner_resolutions = Vec::new();
        let mut remaining = VecDeque::new();
        let cp = current_price.0;

        while let Some(mut paper) = self.papers.pop_front() {
            let was_signaled = paper.signaled;
            let was_resolved = paper.resolved;

            paper.tick(cp);

            // Paper just signaled this tick (Grace — trail crossed for first time)
            if paper.signaled && !was_signaled {
                let optimal = approximate_optimal_distances(
                    paper.entry_price.0,
                    paper.extreme,
                    paper.prediction,
                );
                market_signals.push(Resolution {
                    broker_slot_idx: self.slot_idx,
                    composed_thought: paper.composed_thought.clone(),
                    market_thought: paper.market_thought.clone(),
                    exit_thought: paper.exit_thought.clone(),
                    prediction: paper.prediction,
                    outcome: Outcome::Grace,
                    amount: paper.excursion(),
                    optimal_distances: optimal,
                    entry_price: paper.entry_price.0,
                    extreme: paper.extreme,
                    excursion: paper.excursion(),
                    trail_distance: paper.distances.trail,
                    stop_distance: paper.distances.stop,
                    duration: paper.age,
                    was_runner: true,
                    exit_batch: Vec::new(),
                });
                // Create runner history — accumulation starts now
                self.runner_histories.insert(paper.paper_id, RunnerHistory {
                    thoughts: Vec::new(),
                    distances: Vec::new(),
                    prices: Vec::new(),
                });
            }

            // Accumulate history for active runners.
            // Proposal 024: store the broker's noise-stripped anomaly for aligned
            // exit observer batch training. Falls back to composed_thought if no
            // anomaly stored (should not happen — propose() runs before tick_papers).
            if paper.signaled && !paper.resolved {
                if let Some(history) = self.runner_histories.get_mut(&paper.paper_id) {
                    let thought_for_history = self.last_composed_anomaly
                        .as_ref()
                        .unwrap_or(&paper.composed_thought)
                        .clone();
                    history.thoughts.push(thought_for_history);
                    history.distances.push(paper.distances);
                    history.prices.push(cp);
                }
            }

            // Paper resolved this tick
            if paper.resolved && !was_resolved {
                let optimal = approximate_optimal_distances(
                    paper.entry_price.0,
                    paper.extreme,
                    paper.prediction,
                );

                if !paper.signaled {
                    // Violence — stop fired before trail crossed
                    market_signals.push(Resolution {
                        broker_slot_idx: self.slot_idx,
                        composed_thought: paper.composed_thought.clone(),
                        market_thought: paper.market_thought.clone(),
                        exit_thought: paper.exit_thought.clone(),
                        prediction: paper.prediction,
                        outcome: Outcome::Violence,
                        amount: paper.distances.stop,
                        optimal_distances: optimal,
                        entry_price: paper.entry_price.0,
                        extreme: paper.extreme,
                        excursion: paper.excursion(),
                        trail_distance: paper.distances.trail,
                        stop_distance: paper.distances.stop,
                        duration: paper.age,
                        was_runner: false,
                        exit_batch: Vec::new(),
                    });
                } else {
                    // Runner finished — compute exit batch from accumulated history
                    let exit_batch = if let Some(history) = self.runner_histories.remove(&paper.paper_id) {
                        compute_exit_batch(&history, paper.prediction)
                    } else {
                        Vec::new()
                    };

                    // Runner finished — trail fired after signal
                    runner_resolutions.push(Resolution {
                        broker_slot_idx: self.slot_idx,
                        composed_thought: paper.composed_thought.clone(),
                        market_thought: paper.market_thought.clone(),
                        exit_thought: paper.exit_thought.clone(),
                        prediction: paper.prediction,
                        outcome: Outcome::Grace,
                        amount: paper.excursion(),
                        optimal_distances: optimal,
                        entry_price: paper.entry_price.0,
                        extreme: paper.extreme,
                        excursion: paper.excursion(),
                        trail_distance: paper.distances.trail,
                        stop_distance: paper.distances.stop,
                        duration: paper.age,
                        was_runner: true,
                        exit_batch,
                    });
                }

                // Update self-assessment running averages
                self.resolution_count += 1;
                let n = self.resolution_count as f64;
                let excursion = paper.excursion();
                self.avg_paper_duration += (paper.age as f64 - self.avg_paper_duration) / n;
                self.avg_excursion += (excursion - self.avg_excursion) / n;
                self.last_trail = paper.distances.trail;
                self.last_stop = paper.distances.stop;
            }

            // Keep until resolved, then remove
            if paper.resolved {
                // Paper done. Remove.
            } else {
                remaining.push_back(paper);
            }
        }

        self.papers = remaining;
        (market_signals, runner_resolutions)
    }

    /// The broker learns its OWN lessons and RETURNS what the observers need.
    /// Values up, not effects down.
    ///
    /// Proposal 024: the broker's reckoner learns from last_composed_anomaly
    /// (the noise-stripped thought from propose()) so prediction and learning
    /// are aligned. The `thought` parameter is the composed thought from the
    /// paper — used for observer propagation facts, not the broker's own learning.
    /// Proposal 026: `exit_thought` threaded through for exit observer learning.
    pub fn propagate(
        &mut self,
        thought: &Vector,
        market_thought: &Vector,
        exit_thought: &Vector,
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

        // Proposal 024: broker learns from its own anomaly (what it predicted on).
        // Falls back to the raw thought if no anomaly stored (cold start).
        let learn_thought = self.last_composed_anomaly.as_ref().unwrap_or(thought);

        // 1. Reckoner learns Grace/Violence — on the anomaly
        self.reckoner.observe(learn_thought, label, weight);

        // 2. Feed the internal curve
        let pred = self.reckoner.predict(learn_thought);
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

        // 5. Engram gate
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
            market_thought: market_thought.clone(),
            exit_thought: exit_thought.clone(),
            optimal: *optimal,
            weight,
        }
    }

    /// Number of active paper trades.
    pub fn paper_count(&self) -> usize {
        self.papers.len()
    }
}

/// Approximate optimal distances from tracked extreme (single-direction paper).
/// Uses the excursion as a proxy for what distance would have been ideal.
fn approximate_optimal_distances(
    entry: f64,
    extreme: f64,
    prediction: Direction,
) -> Distances {
    let excursion = match prediction {
        Direction::Up => ((extreme - entry) / entry).max(0.001),
        Direction::Down => ((entry - extreme) / entry).max(0.001),
    };
    let trail = (excursion * 0.5).max(0.001).min(0.10);
    // Stop is learned independently — near-zero bootstrap.
    // The simulation (compute_optimal_distances) teaches the real value.
    // This approximation doesn't have enough information to derive stop.
    let stop = 0.001;
    Distances::new(trail, stop)
}

/// Compute deferred batch training data for the exit observer from a runner's history.
/// Uses a suffix-max (or suffix-min for Down) pass to find the optimal trail distance
/// at each candle in O(n).
fn compute_exit_batch(
    history: &RunnerHistory,
    prediction: Direction,
) -> Vec<(Vector, Distances, f64)> {
    let n = history.prices.len();
    if n == 0 {
        return Vec::new();
    }

    // Compute the optimal stop for the whole runner — one simulation call.
    // The stop is a property of the full trade, not per-candle.
    let runner_optimal = simulation::compute_optimal_distances(&history.prices, prediction);
    let optimal_stop = runner_optimal.stop;

    // Suffix extremum pass — O(n)
    let mut suffix_ext = vec![0.0f64; n];
    suffix_ext[n - 1] = history.prices[n - 1];
    for i in (0..n - 1).rev() {
        suffix_ext[i] = match prediction {
            Direction::Up => history.prices[i].max(suffix_ext[i + 1]),
            Direction::Down => history.prices[i].min(suffix_ext[i + 1]),
        };
    }

    let mut batch = Vec::new();
    let mut last_optimal_trail = f64::NAN;

    for k in 0..n {
        let price_k = history.prices[k];
        if price_k == 0.0 {
            continue;
        }

        // Optimal trail: how far price moved in the predicted direction from candle k
        let optimal_trail = match prediction {
            Direction::Up => ((suffix_ext[k] - price_k) / price_k).max(0.001).min(0.10),
            Direction::Down => ((price_k - suffix_ext[k]) / price_k).max(0.001).min(0.10),
        };

        // Only train when the optimal changed meaningfully (>10% relative change).
        // If the answer is the same candle over candle, there's nothing to learn.
        let changed = last_optimal_trail.is_nan()
            || ((optimal_trail - last_optimal_trail).abs() / last_optimal_trail.max(0.001)) > 0.10;

        if !changed {
            continue;
        }
        last_optimal_trail = optimal_trail;

        let optimal = Distances::new(optimal_trail, optimal_stop);

        // Weight: the residue this optimal distance would capture
        let weight = optimal_trail;

        batch.push((history.thoughts[k].clone(), optimal, weight));
    }

    batch
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
        assert!(pred.conviction >= 0.0);
    }

    #[test]
    fn test_register_paper() {
        let mut broker = make_broker();
        let composed = random_vector("thought");
        let market_thought = random_vector("market");
        let exit_thought = random_vector("exit");
        let distances = Distances::new(0.02, 0.05);
        broker.register_paper(composed, market_thought, exit_thought, Direction::Up, Price(50000.0), distances);
        assert_eq!(broker.paper_count(), 1);
    }

    #[test]
    fn test_tick_papers_no_resolution() {
        let mut broker = make_broker();
        let composed = random_vector("thought");
        let market_thought = random_vector("market");
        let exit_thought = random_vector("exit");
        let distances = Distances::new(0.05, 0.10);
        broker.register_paper(composed, market_thought, exit_thought, Direction::Up, Price(100.0), distances);

        // Price barely moves -- no resolution
        let (market_signals, runner_resolutions) = broker.tick_papers(Price(100.5));
        assert!(market_signals.is_empty());
        assert!(runner_resolutions.is_empty());
        assert_eq!(broker.paper_count(), 1);
    }

    #[test]
    fn test_tick_papers_violence() {
        let mut broker = make_broker();
        let composed = random_vector("thought");
        let market_thought = random_vector("market");
        let exit_thought = random_vector("exit");
        // Trail=0.05, Stop=0.10: stop_level=90
        let distances = Distances::new(0.05, 0.10);
        broker.register_paper(composed, market_thought, exit_thought, Direction::Up, Price(100.0), distances);

        // Price drops below stop → Violence
        let (market_signals, runner_resolutions) = broker.tick_papers(Price(89.0));
        assert_eq!(market_signals.len(), 1);
        assert_eq!(market_signals[0].outcome, Outcome::Violence);
        assert_eq!(market_signals[0].prediction, Direction::Up);
        assert!(runner_resolutions.is_empty());
        assert_eq!(broker.paper_count(), 0); // removed
    }

    #[test]
    fn test_tick_papers_grace_then_runner_resolution() {
        let mut broker = make_broker();
        let composed = random_vector("thought");
        let market_thought = random_vector("market");
        let exit_thought = random_vector("exit");
        // Trail=0.05, Stop=0.10
        let distances = Distances::new(0.05, 0.10);
        broker.register_paper(composed, market_thought, exit_thought, Direction::Up, Price(100.0), distances);

        // Price rises above entry + entry*trail = 105 → Grace signal
        let (market_signals, runner_resolutions) = broker.tick_papers(Price(110.0));
        assert_eq!(market_signals.len(), 1); // Grace signal
        assert_eq!(market_signals[0].outcome, Outcome::Grace);
        assert!(runner_resolutions.is_empty());
        assert_eq!(broker.paper_count(), 1); // still alive as runner

        // Price drops below trail_level: 110 - 110*0.05 = 104.5 → runner resolves
        let (market_signals, runner_resolutions) = broker.tick_papers(Price(104.0));
        assert!(market_signals.is_empty()); // already signaled
        assert_eq!(runner_resolutions.len(), 1);
        assert_eq!(runner_resolutions[0].outcome, Outcome::Grace);
        assert!(runner_resolutions[0].was_runner);
        assert_eq!(broker.paper_count(), 0); // removed
    }

    #[test]
    fn test_propagate_updates_track_record() {
        let mut broker = make_broker();
        let thought = random_vector("thought");
        let se = ScalarEncoder::new(DIMS);
        let optimal = Distances::new(0.03, 0.06);

        let market_thought = random_vector("market");
        let exit_thought = random_vector("exit");
        let facts = broker.propagate(
            &thought,
            &market_thought,
            &exit_thought,
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

        let market_thought = random_vector("market");
        let exit_thought = random_vector("exit");
        broker.propagate(
            &thought,
            &market_thought,
            &exit_thought,
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
    fn test_approximate_optimal_distances_up() {
        let d = approximate_optimal_distances(100.0, 110.0, Direction::Up);
        // excursion = 0.10, trail = 0.05, stop = 0.001 (bootstrap)
        assert!((d.trail - 0.05).abs() < 1e-10);
        assert!((d.stop - 0.001).abs() < 1e-10);
    }

    #[test]
    fn test_approximate_optimal_distances_down() {
        let d = approximate_optimal_distances(100.0, 90.0, Direction::Down);
        // excursion = 0.10, trail = 0.05, stop = 0.001 (bootstrap)
        assert!((d.trail - 0.05).abs() < 1e-10);
        assert!((d.stop - 0.001).abs() < 1e-10);
    }

    #[test]
    fn test_approximate_optimal_distances_clamped() {
        let d = approximate_optimal_distances(100.0, 100.0, Direction::Up);
        assert!(d.trail >= 0.001);
        assert!(d.stop >= 0.001);
    }
}
