/// Broker — the accountability unit binding one market observer to one exit observer.

use std::collections::VecDeque;

use holon::kernel::vector::Vector;
use holon::memory::{OnlineSubspace, ReckConfig, Reckoner};

use crate::distances::Distances;
use crate::engram_gate::{check_engram_gate, EngramGateState};
use crate::enums::{Direction, Outcome, Prediction};
use crate::log_entry::LogEntry;
use crate::paper_entry::PaperEntry;
use crate::scalar_accumulator::ScalarAccumulator;

/// What a broker produces when a paper resolves.
#[derive(Clone, Debug)]
pub struct Resolution {
    pub broker_slot_idx: usize,
    pub composed_thought: Vector,
    pub direction: Direction,
    pub outcome: Outcome,
    pub amount: f64,
    pub optimal_distances: Distances,
}

/// What the broker returns for observers to learn from.
#[derive(Clone, Debug)]
pub struct PropagationFacts {
    pub market_idx: usize,
    pub exit_idx: usize,
    pub direction: Direction,
    pub composed_thought: Vector,
    pub optimal: Distances,
    pub weight: f64,
}

/// The broker struct — accountability unit.
pub struct Broker {
    pub observer_names: Vec<String>,
    pub slot_idx: usize,
    pub exit_count: usize,
    pub reckoner: Reckoner,
    pub noise_subspace: OnlineSubspace,
    pub cumulative_grace: f64,
    pub cumulative_violence: f64,
    pub trade_count: usize,
    pub papers: VecDeque<PaperEntry>,
    pub scalar_accums: Vec<ScalarAccumulator>,
    pub good_state_subspace: OnlineSubspace,
    pub engram_gate_state: EngramGateState,
}

impl Broker {
    pub fn new(
        observers: Vec<String>,
        slot_idx: usize,
        exit_count: usize,
        dims: usize,
        recalib_interval: usize,
        scalar_accums: Vec<ScalarAccumulator>,
    ) -> Self {
        Self {
            observer_names: observers,
            slot_idx,
            exit_count,
            reckoner: Reckoner::new(
                &format!("broker-{}", slot_idx),
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
            engram_gate_state: EngramGateState::new(),
        }
    }

    /// Strip noise from the broker's perspective.
    fn strip_noise(&self, thought: &Vector) -> Vector {
        let f64_data = thought.to_f64();
        let anomalous = self.noise_subspace.anomalous_component(&f64_data);
        Vector::from_f64(&anomalous)
    }

    /// Propose: noise update -> strip noise -> predict Grace/Violence.
    pub fn propose(&mut self, composed: &Vector) -> Prediction {
        self.noise_subspace.update(&composed.to_f64());
        let stripped = self.strip_noise(composed);
        let pred = self.reckoner.predict(&stripped);

        // Convert to enterprise Prediction
        Prediction::Discrete {
            scores: pred
                .scores
                .iter()
                .map(|ls| {
                    let name = self
                        .reckoner
                        .label_name(ls.label)
                        .unwrap_or("?")
                        .to_string();
                    (name, ls.cosine)
                })
                .collect(),
            conviction: pred.conviction,
        }
    }

    /// Edge: how much edge does this broker have?
    pub fn edge(&self) -> f64 {
        let pred = self.reckoner.predict(&Vector::zeros(self.reckoner.dims()));
        let conviction = pred.conviction;
        if self.reckoner.total_updates() >= 50 {
            if let Some(acc) = self.reckoner.accuracy_at(conviction) {
                (acc - 0.5).max(0.0) * 2.0
            } else {
                0.0
            }
        } else {
            0.0
        }
    }

    /// Register a paper entry.
    pub fn register_paper(
        &mut self,
        composed: Vector,
        entry_price: f64,
        distances: Distances,
    ) {
        let paper = PaperEntry::new(composed, entry_price, distances);
        self.papers.push_back(paper);
        // Cap at 100
        while self.papers.len() > 100 {
            self.papers.pop_front();
        }
    }

    /// Tick all papers, resolve completed ones.
    pub fn tick_papers(&mut self, current_price: f64) -> (Vec<Resolution>, Vec<LogEntry>) {
        let slot = self.slot_idx;
        let mut resolutions = Vec::new();
        let mut logs = Vec::new();
        let mut kept = VecDeque::new();

        while let Some(mut paper) = self.papers.pop_front() {
            paper.tick(current_price);
            if paper.is_resolved() {
                let entry = paper.entry_price;
                let dists = paper.distances.clone();

                // Buy side resolution
                let buy_pnl = paper.buy_pnl();
                let buy_outcome = if buy_pnl > 0.0 {
                    Outcome::Grace
                } else {
                    Outcome::Violence
                };
                let buy_optimal = Distances::new(
                    ((paper.buy_extreme - entry) / entry).abs(),
                    dists.stop,
                    dists.tp,
                    dists.runner_trail,
                );
                resolutions.push(Resolution {
                    broker_slot_idx: slot,
                    composed_thought: paper.composed_thought.clone(),
                    direction: Direction::Up,
                    outcome: buy_outcome.clone(),
                    amount: buy_pnl.abs(),
                    optimal_distances: buy_optimal.clone(),
                });

                // Sell side resolution
                let sell_pnl = paper.sell_pnl();
                let sell_outcome = if sell_pnl > 0.0 {
                    Outcome::Grace
                } else {
                    Outcome::Violence
                };
                let sell_optimal = Distances::new(
                    ((entry - paper.sell_extreme) / entry).abs(),
                    dists.stop,
                    dists.tp,
                    dists.runner_trail,
                );
                resolutions.push(Resolution {
                    broker_slot_idx: slot,
                    composed_thought: paper.composed_thought.clone(),
                    direction: Direction::Down,
                    outcome: sell_outcome.clone(),
                    amount: sell_pnl.abs(),
                    optimal_distances: sell_optimal.clone(),
                });

                // Log entries
                logs.push(LogEntry::PaperResolved {
                    broker_slot_idx: slot,
                    outcome: buy_outcome,
                    optimal_distances: buy_optimal,
                });
                logs.push(LogEntry::PaperResolved {
                    broker_slot_idx: slot,
                    outcome: sell_outcome,
                    optimal_distances: sell_optimal,
                });
            } else {
                kept.push_back(paper);
            }
        }

        self.papers = kept;
        (resolutions, logs)
    }

    /// Paper count.
    pub fn paper_count(&self) -> usize {
        self.papers.len()
    }

    /// Propagate a resolved outcome through the broker.
    /// Returns (logs, PropagationFacts).
    pub fn propagate(
        &mut self,
        thought: &Vector,
        outcome: &Outcome,
        weight: f64,
        direction: &Direction,
        optimal: &Distances,
    ) -> (Vec<LogEntry>, PropagationFacts) {
        let stripped = self.strip_noise(thought);

        // Learn Grace/Violence
        let label_idx = match outcome {
            Outcome::Grace => 0,
            Outcome::Violence => 1,
        };
        let label = holon::memory::Label::from_index(label_idx);
        self.reckoner.observe(&stripped, label, weight);

        // Feed the curve
        let pred = self.reckoner.predict(&stripped);
        let conviction = pred.conviction;
        let correct = *outcome == Outcome::Grace;
        self.reckoner.resolve(conviction, correct);

        // Update track record
        match outcome {
            Outcome::Grace => self.cumulative_grace += weight,
            Outcome::Violence => self.cumulative_violence += weight,
        }

        // Update scalar accumulators
        let dist_vals = [optimal.trail, optimal.stop, optimal.tp, optimal.runner_trail];
        for (acc, &dist_val) in self.scalar_accums.iter_mut().zip(dist_vals.iter()) {
            acc.observe(dist_val, outcome, weight);
        }

        // Engram gate
        check_engram_gate(
            &self.reckoner,
            &mut self.good_state_subspace,
            &mut self.engram_gate_state,
            outcome,
        );

        // Derive market_idx and exit_idx from slot_idx
        let market_idx = self.slot_idx / self.exit_count;
        let exit_idx = self.slot_idx % self.exit_count;

        self.trade_count += 1;

        let facts = PropagationFacts {
            market_idx,
            exit_idx,
            direction: direction.clone(),
            composed_thought: thought.clone(),
            optimal: optimal.clone(),
            weight,
        };

        let logs = vec![LogEntry::Propagated {
            broker_slot_idx: self.slot_idx,
            observers_updated: 2,
        }];

        (logs, facts)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::enums::ScalarEncoding;

    fn make_test_broker() -> Broker {
        let accums = vec![
            ScalarAccumulator::new("trail", ScalarEncoding::Log, 4096),
            ScalarAccumulator::new("stop", ScalarEncoding::Log, 4096),
            ScalarAccumulator::new("tp", ScalarEncoding::Log, 4096),
            ScalarAccumulator::new("runner", ScalarEncoding::Log, 4096),
        ];
        Broker::new(
            vec!["momentum".into(), "volatility".into()],
            0,
            4,
            4096,
            500,
            accums,
        )
    }

    #[test]
    fn test_broker_construct() {
        let b = make_test_broker();
        assert_eq!(b.slot_idx, 0);
        assert_eq!(b.exit_count, 4);
        assert_eq!(b.trade_count, 0);
        assert_eq!(b.cumulative_grace, 0.0);
        assert_eq!(b.cumulative_violence, 0.0);
        assert_eq!(b.papers.len(), 0);
    }

    #[test]
    fn test_propose_returns_prediction() {
        let mut b = make_test_broker();
        let composed = Vector::zeros(4096);
        let pred = b.propose(&composed);
        match pred {
            Prediction::Discrete { scores, .. } => {
                // Should have Grace and Violence labels
                assert!(scores.len() <= 2);
            }
            _ => panic!("Expected Discrete prediction"),
        }
    }
}
