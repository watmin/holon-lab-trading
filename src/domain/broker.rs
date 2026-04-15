/// broker.rs — The accountability primitive. Binds one market observer +
/// one position observer. The broker owns the game — gate 4, anxiety
/// atoms, exit/hold decisions. The treasury owns papers and capital.

use crate::types::enums::{Direction, Outcome};

/// The accountability primitive. N x M brokers total.
pub struct Broker {
    /// Diagnostic identity for the ledger. e.g. ["momentum", "volatility"].
    pub observer_names: Vec<String>,
    /// Position in the N x M grid. THE identity.
    pub slot_idx: usize,
    /// M — needed to derive market-idx and position-idx.
    pub position_count: usize,
    /// Total resolved positions.
    pub trade_count: usize,
    /// Count of Grace outcomes.
    pub grace_count: usize,
    /// Count of Violence outcomes.
    pub violence_count: usize,
    /// Grace rate — grace_count / trade_count.
    pub expected_value: f64,
    /// Current active direction — the broker's stance. None = cold start.
    pub active_direction: Option<Direction>,
}

impl Broker {
    pub fn new(
        observer_names: Vec<String>,
        slot_idx: usize,
        position_count: usize,
    ) -> Self {
        assert!(position_count > 0, "broker position_count must be > 0");
        Self {
            observer_names,
            slot_idx,
            position_count,
            trade_count: 0,
            grace_count: 0,
            violence_count: 0,
            expected_value: 0.0,
            active_direction: None,
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
    /// After warm-up, open only when grace rate > 0.5.
    pub fn gate_open(&self) -> bool {
        let cold_start = self.grace_count < 50 || self.violence_count < 50;
        cold_start || self.expected_value > 0.5
    }

    /// The broker learns from a resolution. Updates counts and grace rate.
    pub fn record_outcome(&mut self, outcome: Outcome) {
        match outcome {
            Outcome::Grace => self.grace_count += 1,
            Outcome::Violence => self.violence_count += 1,
        }
        self.trade_count += 1;
        self.expected_value = self.grace_count as f64 / self.trade_count as f64;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_broker() -> Broker {
        Broker::new(
            vec!["momentum".into(), "volatility".into()],
            0,
            2,
        )
    }

    #[test]
    fn test_broker_new() {
        let broker = make_broker();
        assert_eq!(broker.slot_idx, 0);
        assert_eq!(broker.position_count, 2);
        assert_eq!(broker.trade_count, 0);
        assert_eq!(broker.grace_count, 0);
        assert_eq!(broker.violence_count, 0);
        assert_eq!(broker.expected_value, 0.0);
    }

    #[test]
    fn test_market_position_idx() {
        let broker = Broker::new(vec!["a".into(), "b".into()], 5, 3);
        assert_eq!(broker.market_idx(), 1);  // 5 / 3
        assert_eq!(broker.position_idx(), 2); // 5 % 3
    }

    #[test]
    fn test_gate_cold_start_always_open() {
        let broker = make_broker();
        assert!(broker.gate_open());
    }

    #[test]
    fn test_gate_closed_low_grace() {
        let mut broker = make_broker();
        broker.grace_count = 50;
        broker.violence_count = 200;
        broker.trade_count = 250;
        broker.expected_value = 0.2;
        assert!(!broker.gate_open());
    }

    #[test]
    fn test_gate_open_high_grace() {
        let mut broker = make_broker();
        broker.grace_count = 60;
        broker.violence_count = 60;
        broker.trade_count = 120;
        broker.expected_value = 0.5;
        // 0.5 is NOT > 0.5, so gate is closed unless cold start
        assert!(!broker.gate_open());
        broker.expected_value = 0.51;
        assert!(broker.gate_open());
    }

    #[test]
    fn test_record_outcome() {
        let mut broker = make_broker();
        broker.record_outcome(Outcome::Grace);
        assert_eq!(broker.grace_count, 1);
        assert_eq!(broker.trade_count, 1);
        assert_eq!(broker.expected_value, 1.0);

        broker.record_outcome(Outcome::Violence);
        assert_eq!(broker.violence_count, 1);
        assert_eq!(broker.trade_count, 2);
        assert_eq!(broker.expected_value, 0.5);
    }
}
