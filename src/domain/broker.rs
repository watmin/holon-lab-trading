/// broker.rs — The accountability primitive. Binds one market observer + one
/// exit observer. Compiled from wat/broker.wat.
///
/// The broker IS the accountability unit. It owns paper trades, scalar
/// accumulators, and a Grace/Violence reckoner. Values up, not effects down.

use std::collections::{HashMap, VecDeque};

use holon::kernel::scalar::ScalarEncoder;
use holon::kernel::vector::Vector;

use crate::types::distances::Distances;
use crate::types::enums::{Direction, Outcome};
use crate::domain::simulation;
use crate::types::newtypes::Price;
use crate::trades::paper_entry::PaperEntry;
use crate::learning::scalar_accumulator::ScalarAccumulator;

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
    /// Each entry: (thought_at_candle, optimal_distances_at_candle, actual_distances_at_candle, weight).
    /// Empty for non-runner resolutions.
    pub exit_batch: Vec<(Vector, Distances, Distances, f64)>,
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

/// Rolling window size for journey grading (Proposal 043).
pub const JOURNEY_WINDOW: usize = 200;

/// The accountability primitive. N x M brokers total.
pub struct Broker {
    /// Diagnostic identity for the ledger. e.g. ["momentum", "volatility"].
    pub observer_names: Vec<String>,
    /// Position in the N x M grid. THE identity.
    pub slot_idx: usize,
    /// M -- needed to derive market-idx and exit-idx.
    pub exit_count: usize,
    /// Cumulative grace value (weighted).
    pub cumulative_grace: f64,
    /// Cumulative violence value (weighted).
    pub cumulative_violence: f64,
    /// Total trade count.
    pub trade_count: usize,
    /// Count of Grace outcomes.
    pub grace_count: usize,
    /// Count of Violence outcomes.
    pub violence_count: usize,
    /// Current active direction — the broker's stance. None = cold start.
    pub active_direction: Option<Direction>,
    /// Capped paper trade queue.
    pub papers: VecDeque<PaperEntry>,
    /// Two scalar accumulators: trail-distance, stop-distance.
    pub scalar_accums: Vec<ScalarAccumulator>,
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
    /// EMA of net dollars per Grace paper (Proposal 035).
    pub avg_grace_net: f64,
    /// EMA of net dollars per Violence paper (Proposal 035).
    pub avg_violence_net: f64,
    /// Expected value: grace_rate * avg_grace_net + (1-grace_rate) * avg_violence_net.
    pub expected_value: f64,
    /// Venue fee per swap (fraction, e.g. 0.0010).
    pub swap_fee: f64,
    /// Rolling window of error ratios for journey grading (Proposal 043).
    /// Replaces EMA — per-broker, median threshold, finite memory.
    pub journey_errors: VecDeque<f64>,
}

impl Broker {
    /// Construct a new broker. Proposal 035: no reckoner, no noise subspace.
    /// Pure accounting + gate + log.
    pub fn new(
        observer_names: Vec<String>,
        slot_idx: usize,
        exit_count: usize,
        scalar_accums: Vec<ScalarAccumulator>,
        default_distances: Distances,
        swap_fee: f64,
    ) -> Self {
        assert!(exit_count > 0, "broker exit_count must be > 0 (divide-by-zero guard)");
        Self {
            observer_names,
            slot_idx,
            exit_count,
            cumulative_grace: 0.0,
            cumulative_violence: 0.0,
            trade_count: 0,
            grace_count: 0,
            violence_count: 0,
            active_direction: None,
            papers: VecDeque::new(),
            scalar_accums,
            default_distances,
            avg_paper_duration: 0.0,
            avg_excursion: 0.0,
            last_trail: 0.0,
            last_stop: 0.0,
            resolution_count: 0,
            next_paper_id: 0,
            runner_histories: HashMap::new(),
            avg_grace_net: 0.0,
            avg_violence_net: 0.0,
            expected_value: 0.0,
            swap_fee,
            journey_errors: VecDeque::new(),
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

    /// Is the gate open? During cold start (< 50 of either outcome), always open.
    /// After warm-up, open only when expected value is positive.
    pub fn gate_open(&self) -> bool {
        let cold_start = self.grace_count < 50 || self.violence_count < 50;
        cold_start || self.expected_value > 0.0
    }

    /// Distance cascade: reckoner answer -> own accumulators -> default.
    /// The broker owns the full cascade because it owns the scalar accumulators.
    pub fn cascade_distances(&self, reckoner_answer: Option<Distances>) -> Distances {
        if let Some(dists) = reckoner_answer {
            return dists;
        }

        let se = crate::domain::lens::ctx_scalar_encoder_placeholder();

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
                    &paper.price_history, paper.prediction, self.swap_fee,
                );
                let exit_batch = if let Some(history) = self.runner_histories.remove(&paper.paper_id) {
                    compute_exit_batch(&history, paper.prediction, self.swap_fee)
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
            if paper.signaled && !paper.resolved {
                if let Some(history) = self.runner_histories.get_mut(&paper.paper_id) {
                    history.thoughts.push(paper.composed_thought.clone());
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
                        compute_exit_batch(&history, paper.prediction, self.swap_fee)
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
    /// Proposal 035: no reckoner. Pure accounting — dollar P&L, EMA, counts.
    /// Scalar accumulators still learn trail/stop distances.
    pub fn propagate(
        &mut self,
        thought: &Vector,
        market_thought: &Vector,
        exit_thought: &Vector,
        outcome: Outcome,
        weight: f64,
        direction: Direction,
        optimal: &Distances,
        scalar_encoder: &ScalarEncoder,
    ) -> PropagationFacts {
        // 1. Track record
        match outcome {
            Outcome::Grace => {
                self.cumulative_grace += weight;
                self.grace_count += 1;
            }
            Outcome::Violence => {
                self.cumulative_violence += weight;
                self.violence_count += 1;
            }
        }
        self.trade_count += 1;

        // 2. Scalar accumulators learn -- trail and stop distances
        if self.scalar_accums.len() >= 2 {
            self.scalar_accums[0].observe(optimal.trail, outcome, weight, scalar_encoder);
            self.scalar_accums[1].observe(optimal.stop, outcome, weight, scalar_encoder);
        }

        // 3. Dollar P&L computation and EMA update (Proposal 035)
        let reference = 10_000.0;
        let entry_fee = reference * self.swap_fee;
        let net = match outcome {
            Outcome::Grace => {
                let residue_usd = weight * reference; // weight IS excursion for Grace
                let exit_fee = (reference + residue_usd) * self.swap_fee;
                residue_usd - entry_fee - exit_fee
            }
            Outcome::Violence => {
                let loss_usd = weight * reference; // weight IS stop_distance for Violence
                let exit_fee = (reference - loss_usd) * self.swap_fee;
                -(loss_usd + entry_fee + exit_fee)
            }
        };
        let alpha = 0.038; // half-life ~50 papers
        match outcome {
            Outcome::Grace => {
                self.avg_grace_net = (1.0 - alpha) * self.avg_grace_net + alpha * net;
            }
            Outcome::Violence => {
                self.avg_violence_net = (1.0 - alpha) * self.avg_violence_net + alpha * net;
            }
        }
        let gr = if self.trade_count > 0 {
            self.grace_count as f64 / self.trade_count as f64
        } else {
            0.5
        };
        self.expected_value = gr * self.avg_grace_net + (1.0 - gr) * self.avg_violence_net;

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
    swap_fee: f64,
) -> Vec<(Vector, Distances, Distances, f64)> {
    let n = history.prices.len();
    if n == 0 {
        return Vec::new();
    }

    // Compute the optimal stop for the whole runner — one simulation call.
    // The stop is a property of the full trade, not per-candle.
    let runner_optimal = simulation::compute_optimal_distances(&history.prices, prediction, swap_fee);
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

        batch.push((history.thoughts[k].clone(), optimal, history.distances[k], weight));
    }

    batch
}

#[cfg(test)]
mod tests {
    use super::*;
    use holon::kernel::scalar::ScalarEncoder;
    use holon::kernel::vector_manager::VectorManager;
    use crate::types::enums::ScalarEncoding;

    const DIMS: usize = 4096;

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
            make_scalar_accums(),
            Distances::new(0.015, 0.030),
            0.0010, // swap_fee
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
        assert!((broker.avg_grace_net - 0.0).abs() < 1e-10);
        assert!((broker.avg_violence_net - 0.0).abs() < 1e-10);
        assert!((broker.expected_value - 0.0).abs() < 1e-10);
    }

    #[test]
    fn test_market_exit_idx() {
        let broker = Broker::new(
            vec!["a".into(), "b".into()],
            5, 3,
            make_scalar_accums(),
            Distances::new(0.015, 0.030),
            0.0010,
        );
        assert_eq!(broker.market_idx(), 1);
        assert_eq!(broker.exit_idx(), 2);
    }

    #[test]
    fn test_gate_open_cold_start() {
        let broker = make_broker();
        // Cold start — grace_count < 50, violence_count < 50
        assert!(broker.gate_open());
    }

    #[test]
    fn test_gate_open_negative_ev() {
        let mut broker = make_broker();
        // Simulate warm-up: 50+ of each
        broker.grace_count = 60;
        broker.violence_count = 60;
        broker.trade_count = 120;
        broker.expected_value = -5.0;
        assert!(!broker.gate_open());
    }

    #[test]
    fn test_gate_open_positive_ev() {
        let mut broker = make_broker();
        broker.grace_count = 60;
        broker.violence_count = 60;
        broker.trade_count = 120;
        broker.expected_value = 10.0;
        assert!(broker.gate_open());
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
            &se,
        );

        assert_eq!(broker.trade_count, 1);
        assert!((broker.cumulative_violence - 2.5).abs() < 1e-10);
        assert!((broker.cumulative_grace - 0.0).abs() < 1e-10);
    }

    #[test]
    fn test_dollar_pnl_grace() {
        let mut broker = make_broker();
        let thought = random_vector("thought");
        let se = ScalarEncoder::new(DIMS);
        let optimal = Distances::new(0.03, 0.06);

        // Grace with weight=0.05 (5% excursion), swap_fee=0.0010
        let market_thought = random_vector("market");
        let exit_thought = random_vector("exit");
        broker.propagate(
            &thought,
            &market_thought,
            &exit_thought,
            Outcome::Grace,
            0.05,
            Direction::Up,
            &optimal,
            &se,
        );

        // reference=10000, entry_fee=10, residue=500, exit_fee=(10500)*0.001=10.5
        // net = 500 - 10 - 10.5 = 479.5
        // avg_grace_net = 0.038 * 479.5 = 18.221
        assert!((broker.avg_grace_net - 0.038 * 479.5).abs() < 0.01);
        assert!(broker.avg_grace_net > 0.0);
    }

    #[test]
    fn test_dollar_pnl_violence() {
        let mut broker = make_broker();
        let thought = random_vector("thought");
        let se = ScalarEncoder::new(DIMS);
        let optimal = Distances::new(0.03, 0.06);

        // Violence with weight=0.03 (3% stop distance), swap_fee=0.0010
        let market_thought = random_vector("market");
        let exit_thought = random_vector("exit");
        broker.propagate(
            &thought,
            &market_thought,
            &exit_thought,
            Outcome::Violence,
            0.03,
            Direction::Down,
            &optimal,
            &se,
        );

        // reference=10000, entry_fee=10, loss=300, exit_fee=(9700)*0.001=9.7
        // net = -(300 + 10 + 9.7) = -319.7
        // avg_violence_net = 0.038 * (-319.7) = -12.1486
        assert!((broker.avg_violence_net - 0.038 * (-319.7)).abs() < 0.01);
        assert!(broker.avg_violence_net < 0.0);
    }

    #[test]
    fn test_ema_updates_correctly() {
        let mut broker = make_broker();
        let thought = random_vector("thought");
        let se = ScalarEncoder::new(DIMS);
        let optimal = Distances::new(0.03, 0.06);
        let market_thought = random_vector("market");
        let exit_thought = random_vector("exit");

        // Two Grace propagations — EMA should blend
        broker.propagate(&thought, &market_thought, &exit_thought,
            Outcome::Grace, 0.05, Direction::Up, &optimal, &se);
        let first = broker.avg_grace_net;

        broker.propagate(&thought, &market_thought, &exit_thought,
            Outcome::Grace, 0.05, Direction::Up, &optimal, &se);
        let second = broker.avg_grace_net;

        // Second should be closer to the true value (EMA converging)
        assert!(second > first);
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
