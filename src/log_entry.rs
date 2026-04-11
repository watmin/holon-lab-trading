/// LogEntry — the glass box. What happened. Compiled from wat/log-entry.wat.
///
/// Six variants. The enterprise's output stream.

use crate::distances::Distances;
use crate::enums::{Outcome, Prediction};
use crate::newtypes::TradeId;

use holon::kernel::vector::Vector;

/// Six variants. Each function returns its log entries as values.
#[derive(Clone, Debug)]
pub enum LogEntry {
    ProposalSubmitted {
        broker_slot_idx: usize,
        composed_thought: Vector,
        distances: Distances,
    },
    ProposalFunded {
        trade_id: TradeId,
        broker_slot_idx: usize,
        amount_reserved: f64,
    },
    ProposalRejected {
        broker_slot_idx: usize,
        reason: String,
    },
    TradeSettled {
        trade_id: TradeId,
        outcome: Outcome,
        amount: f64,
        duration: usize,
        prediction: Prediction,
    },
    PaperResolved {
        broker_slot_idx: usize,
        outcome: Outcome,
        optimal_distances: Distances,
    },
    Propagated {
        broker_slot_idx: usize,
        observers_updated: usize,
    },
    Diagnostic {
        candle: usize,
        throughput: f64,
        cache_hits: usize,
        cache_misses: usize,
        cache_size: usize,
        equity: f64,
        // Per-candle timing breakdown (microseconds)
        us_settle: u64,
        us_tick: u64,
        us_observers: u64,
        us_grid: u64,
        us_brokers: u64,
        us_propagate: u64,
        us_triggers: u64,
        us_fund: u64,
        us_total: u64,
        // Counts
        num_settlements: usize,
        num_resolutions: usize,
        num_active_trades: usize,
    },
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_proposal_submitted() {
        let entry = LogEntry::ProposalSubmitted {
            broker_slot_idx: 0,
            composed_thought: Vector::zeros(4096),
            distances: Distances::new(0.02, 0.05),
        };
        match entry {
            LogEntry::ProposalSubmitted { broker_slot_idx, .. } => {
                assert_eq!(broker_slot_idx, 0);
            }
            _ => panic!("Expected ProposalSubmitted"),
        }
    }

    #[test]
    fn test_proposal_funded() {
        let entry = LogEntry::ProposalFunded {
            trade_id: TradeId(1),
            broker_slot_idx: 2,
            amount_reserved: 100.0,
        };
        match entry {
            LogEntry::ProposalFunded { trade_id, .. } => {
                assert_eq!(trade_id, TradeId(1));
            }
            _ => panic!("Expected ProposalFunded"),
        }
    }

    #[test]
    fn test_proposal_rejected() {
        let entry = LogEntry::ProposalRejected {
            broker_slot_idx: 3,
            reason: "edge below venue cost".into(),
        };
        match entry {
            LogEntry::ProposalRejected { reason, .. } => {
                assert_eq!(reason, "edge below venue cost");
            }
            _ => panic!("Expected ProposalRejected"),
        }
    }

    #[test]
    fn test_trade_settled() {
        let entry = LogEntry::TradeSettled {
            trade_id: TradeId(5),
            outcome: Outcome::Grace,
            amount: 50.0,
            duration: 10,
            prediction: Prediction::Discrete {
                scores: vec![("Grace".into(), 0.7), ("Violence".into(), 0.3)],
                conviction: 0.7,
            },
        };
        match entry {
            LogEntry::TradeSettled { outcome, duration, .. } => {
                assert_eq!(outcome, Outcome::Grace);
                assert_eq!(duration, 10);
            }
            _ => panic!("Expected TradeSettled"),
        }
    }

    #[test]
    fn test_paper_resolved() {
        let entry = LogEntry::PaperResolved {
            broker_slot_idx: 1,
            outcome: Outcome::Violence,
            optimal_distances: Distances::new(0.02, 0.05),
        };
        match entry {
            LogEntry::PaperResolved { outcome, .. } => {
                assert_eq!(outcome, Outcome::Violence);
            }
            _ => panic!("Expected PaperResolved"),
        }
    }

    #[test]
    fn test_propagated() {
        let entry = LogEntry::Propagated {
            broker_slot_idx: 4,
            observers_updated: 2,
        };
        match entry {
            LogEntry::Propagated { observers_updated, .. } => {
                assert_eq!(observers_updated, 2);
            }
            _ => panic!("Expected Propagated"),
        }
    }
}
