/// broker.rs — The accountability primitive. Binds one market observer + one
/// position observer. Compiled from wat/broker.wat.
///
/// The broker IS the accountability unit. It owns scalar accumulators and a
/// Grace/Violence reckoner. The treasury owns papers now. Values up, not
/// effects down.

use holon::kernel::scalar::ScalarEncoder;
use holon::kernel::vector::Vector;

use crate::types::distances::Distances;
use crate::types::enums::{Direction, Outcome};
use crate::learning::scalar_accumulator::ScalarAccumulator;

/// What the broker returns for observer learning.
#[derive(Clone)]
pub struct PropagationFacts {
    /// Which market observer should learn.
    pub market_idx: usize,
    /// Which position observer should learn.
    pub position_idx: usize,
    /// For the market observer.
    pub direction: Direction,
    /// For both observers.
    pub composed_thought: Vector,
    /// For the market observer — the anomaly it predicted on.
    /// Proposal 024: market observer learns from the anomaly, not composed thought.
    pub market_thought: Vector,
    /// For the position observer — its own encoded facts, NOT the composition.
    /// Proposal 026: position observer learns from position_thought only.
    pub position_thought: Vector,
    /// For the position observer.
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
    /// M -- needed to derive market-idx and position-idx.
    pub position_count: usize,
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
    /// Scalar accumulator for trail-distance.
    pub trail_accum: ScalarAccumulator,
    /// Scalar accumulator for stop-distance.
    pub stop_accum: ScalarAccumulator,
    /// Default trail/stop distances — the tier 3 fallback.
    pub default_distances: Distances,
    /// Count of resolved sides (for running average computation).
    pub resolution_count: usize,
    /// EMA of net dollars per Grace paper (Proposal 035).
    pub avg_grace_net: f64,
    /// EMA of net dollars per Violence paper (Proposal 035).
    pub avg_violence_net: f64,
    /// Expected value: grace_rate * avg_grace_net + (1-grace_rate) * avg_violence_net.
    pub expected_value: f64,
    /// Venue fee per swap (fraction, e.g. 0.0010).
    pub swap_fee: f64,
}

impl Broker {
    /// Construct a new broker. Proposal 035: no reckoner, no noise subspace.
    /// Pure accounting + gate + log.
    pub fn new(
        observer_names: Vec<String>,
        slot_idx: usize,
        position_count: usize,
        trail_accum: ScalarAccumulator,
        stop_accum: ScalarAccumulator,
        default_distances: Distances,
        swap_fee: f64,
    ) -> Self {
        assert!(position_count > 0, "broker position_count must be > 0 (divide-by-zero guard)");
        Self {
            observer_names,
            slot_idx,
            position_count,
            cumulative_grace: 0.0,
            cumulative_violence: 0.0,
            trade_count: 0,
            grace_count: 0,
            violence_count: 0,
            active_direction: None,
            trail_accum,
            stop_accum,
            default_distances,
            resolution_count: 0,
            avg_grace_net: 0.0,
            avg_violence_net: 0.0,
            expected_value: 0.0,
            swap_fee,
        }
    }

    /// Derive market observer index from slot_idx.
    pub fn market_idx(&self) -> usize {
        self.slot_idx / self.position_count
    }

    /// Derive position observer index from slot_idx.
    pub fn position_idx(&self) -> usize {
        self.slot_idx % self.position_count
    }

    /// Is the gate open? During cold start (< 50 of either outcome), always open.
    /// After warm-up, open only when expected value is positive.
    // rune:reap(scaffolding) — awaiting Phase 5 treasury. The gate controls funded proposals.
    pub fn gate_open(&self) -> bool {
        let cold_start = self.grace_count < 50 || self.violence_count < 50;
        cold_start || self.expected_value > 0.0
    }

    /// Distance cascade: reckoner answer -> own accumulators -> default.
    /// The broker owns the full cascade because it owns the scalar accumulators.
    pub fn cascade_distances(&self, reckoner_answer: Option<Distances>, se: &ScalarEncoder) -> Distances {
        if let Some(dists) = reckoner_answer {
            return dists;
        }

        // Tier 2: scalar accumulators (global per-pair)
        let trail = if self.trail_accum.count > 0 {
            self.trail_accum.extract(100, (0.001, 0.10), se)
        } else {
            self.default_distances.trail
        };

        let stop = if self.stop_accum.count > 0 {
            self.stop_accum.extract(100, (0.001, 0.10), se)
        } else {
            self.default_distances.stop
        };

        Distances::new(trail, stop)
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
        position_thought: &Vector,
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
        self.resolution_count += 1;

        // 2. Scalar accumulators learn -- trail and stop distances
        self.trail_accum.observe(optimal.trail, outcome, weight, scalar_encoder);
        self.stop_accum.observe(optimal.stop, outcome, weight, scalar_encoder);

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
            position_idx: self.position_idx(),
            direction,
            composed_thought: thought.clone(),
            market_thought: market_thought.clone(),
            position_thought: position_thought.clone(),
            optimal: *optimal,
            weight,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use holon::kernel::scalar::ScalarEncoder;
    use holon::kernel::vector_manager::VectorManager;
    use crate::types::enums::ScalarEncoding;

    const DIMS: usize = 4096;

    fn make_broker() -> Broker {
        Broker::new(
            vec!["momentum".into(), "volatility".into()],
            0, // slot_idx
            2, // position_count
            ScalarAccumulator::new("trail-distance", ScalarEncoding::Log, DIMS),
            ScalarAccumulator::new("stop-distance", ScalarEncoding::Log, DIMS),
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
        assert_eq!(broker.position_count, 2);
        assert_eq!(broker.trade_count, 0);
        assert!((broker.cumulative_grace - 0.0).abs() < 1e-10);
        assert!((broker.cumulative_violence - 0.0).abs() < 1e-10);
        assert!((broker.avg_grace_net - 0.0).abs() < 1e-10);
        assert!((broker.avg_violence_net - 0.0).abs() < 1e-10);
        assert!((broker.expected_value - 0.0).abs() < 1e-10);
    }

    #[test]
    fn test_market_position_idx() {
        let broker = Broker::new(
            vec!["a".into(), "b".into()],
            5, 3,
            ScalarAccumulator::new("trail-distance", ScalarEncoding::Log, DIMS),
            ScalarAccumulator::new("stop-distance", ScalarEncoding::Log, DIMS),
            Distances::new(0.015, 0.030),
            0.0010,
        );
        assert_eq!(broker.market_idx(), 1);
        assert_eq!(broker.position_idx(), 2);
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
    fn test_propagate_updates_track_record() {
        let mut broker = make_broker();
        let thought = random_vector("thought");
        let se = ScalarEncoder::new(DIMS);
        let optimal = Distances::new(0.03, 0.06);

        let market_thought = random_vector("market");
        let position_thought = random_vector("exit");
        let facts = broker.propagate(
            &thought,
            &market_thought,
            &position_thought,
            Outcome::Grace,
            1.0,
            Direction::Up,
            &optimal,
            &se,
        );

        assert_eq!(broker.trade_count, 1);
        assert!((broker.cumulative_grace - 1.0).abs() < 1e-10);
        assert_eq!(facts.market_idx, 0);
        assert_eq!(facts.position_idx, 0);
        assert_eq!(facts.direction, Direction::Up);
    }

    #[test]
    fn test_propagate_violence_updates_violence() {
        let mut broker = make_broker();
        let thought = random_vector("thought");
        let se = ScalarEncoder::new(DIMS);
        let optimal = Distances::new(0.03, 0.06);

        let market_thought = random_vector("market");
        let position_thought = random_vector("exit");
        broker.propagate(
            &thought,
            &market_thought,
            &position_thought,
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
        let position_thought = random_vector("exit");
        broker.propagate(
            &thought,
            &market_thought,
            &position_thought,
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
        let position_thought = random_vector("exit");
        broker.propagate(
            &thought,
            &market_thought,
            &position_thought,
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
        let position_thought = random_vector("exit");

        // Two Grace propagations — EMA should blend
        broker.propagate(&thought, &market_thought, &position_thought,
            Outcome::Grace, 0.05, Direction::Up, &optimal, &se);
        let first = broker.avg_grace_net;

        broker.propagate(&thought, &market_thought, &position_thought,
            Outcome::Grace, 0.05, Direction::Up, &optimal, &se);
        let second = broker.avg_grace_net;

        // Second should be closer to the true value (EMA converging)
        assert!(second > first);
    }

    #[test]
    fn test_scalar_accums_named() {
        let broker = make_broker();
        assert_eq!(broker.trail_accum.name, "trail-distance");
        assert_eq!(broker.stop_accum.name, "stop-distance");
    }
}
