/// LogEntry — the glass box. What happened. Compiled from wat/log-entry.wat.
///
/// Seven variants. The enterprise's output stream.

use crate::types::distances::Distances;
use crate::types::enums::{Outcome, Prediction};
use crate::types::newtypes::{Amount, TradeId};

use holon::kernel::vector::Vector;

/// Seven variants. Each function returns its log entries as values.
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
        amount_reserved: Amount,
    },
    ProposalRejected {
        broker_slot_idx: usize,
        reason: String,
    },
    TradeSettled {
        trade_id: TradeId,
        outcome: Outcome,
        amount: Amount,
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
    /// Telemetry — CloudWatch-style metrics. One row per metric per candle.
    Telemetry {
        namespace: String,
        id: String,
        dimensions: String,
        timestamp_ns: u64,
        metric_name: String,
        metric_value: f64,
        metric_unit: String,
    },
    /// Regime observer snapshot — emitted by regime observer threads every candle.
    RegimeObserverSnapshot {
        candle: usize,
        regime_idx: usize,
        lens: String,
        us_elapsed: u64,
        thought_ast: String,
        fact_count: usize,
    },
    /// Observer snapshot — emitted by observer threads every N candles.
    ObserverSnapshot {
        candle: usize,
        observer_idx: usize,
        lens: String,
        disc_strength: f64,
        conviction: f64,
        experience: f64,
        resolved: usize,
        recalib_count: usize,
        recalib_wins: usize,
        recalib_total: usize,
        last_prediction: String,
        us_elapsed: u64,
        thought_ast: String,
        fact_count: usize,
    },
    /// Paper detail — the full story of a resolved paper.
    PaperDetail {
        broker_slot_idx: usize,
        outcome: Outcome,
        entry_price: f64,
        extreme: f64,
        excursion: f64,
        trail_distance: f64,
        stop_distance: f64,
        optimal_trail: f64,
        optimal_stop: f64,
        duration: usize,
        was_runner: bool,
    },
    /// Phase snapshot — emitted by broker slot 0 every 100 candles.
    PhaseSnapshot {
        candle: usize,
        close: f64,
        phase_label: String,
        phase_direction: String,
        phase_duration: usize,
        phase_count: usize,
        phase_history_len: usize,
    },
    /// Broker snapshot — emitted by broker threads every N candles.
    BrokerSnapshot {
        candle: usize,
        broker_slot_idx: usize,
        grace_count: usize,
        violence_count: usize,
        paper_count: usize,
        expected_value: f64,
        fact_count: usize,
        thought_ast: String,
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
            amount_reserved: Amount(100.0),
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
            amount: Amount(50.0),
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
            observers_updated: 1,
        };
        match entry {
            LogEntry::Propagated { observers_updated, .. } => {
                assert!(observers_updated <= 2, "at most 2 observers (market + exit)");
            }
            _ => panic!("Expected Propagated"),
        }
    }
}
