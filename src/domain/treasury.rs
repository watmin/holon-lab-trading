/// treasury.rs — The bank. Headless. Blind to strategy.
/// Validates arithmetic. Enforces deadlines. Distributes yield.
///
/// Implements the types from Proposal 055: Treasury-Driven Resolution.
/// Papers don't move capital. Real positions do. The deadline IS the clock.

use std::collections::HashMap;

/// The lifecycle of a position — paper or real.
/// One enum, not bool + Option.
#[derive(Debug, Clone, PartialEq)]
pub enum PositionState {
    /// Open, clock ticking.
    Active,
    /// Exited profitably. Residue is the profit after fees.
    Grace { residue: f64 },
    /// Deadline hit, reclaimed.
    Violence,
}

/// A paper position — fixed $10,000 reference. Proof of thoughts.
/// No capital moves. Always issued. The cost is computation (lab)
/// or gas (Solana).
#[derive(Debug, Clone)]
pub struct PaperPosition {
    pub paper_id: u64,
    /// Broker slot index — who owns this paper.
    pub owner: usize,
    /// What was borrowed (e.g. "USDC").
    pub from_asset: String,
    /// What was acquired (e.g. "WBTC").
    pub to_asset: String,
    /// Units of from_asset borrowed. Always 10_000.0 for papers.
    pub amount: f64,
    /// Units of to_asset after entry fee.
    pub units_acquired: f64,
    /// Exchange rate at entry.
    pub entry_price: f64,
    /// Candle index at entry.
    pub entry_candle: usize,
    /// entry_candle + N — the clock.
    pub deadline: usize,
    /// Lifecycle state.
    pub state: PositionState,
}

/// A real position — actual capital. Requires proven record.
/// Treasury moves balances. Distinct type, distinct issuance.
#[derive(Debug, Clone)]
pub struct RealPosition {
    pub position_id: u64,
    /// Broker slot index — who owns this position.
    pub owner: usize,
    /// What was borrowed (e.g. "USDC").
    pub from_asset: String,
    /// What was acquired (e.g. "WBTC").
    pub to_asset: String,
    /// Actual capital borrowed — variable, not fixed.
    pub amount: f64,
    /// Units of to_asset after entry fee.
    pub units_acquired: f64,
    /// Exchange rate at entry.
    pub entry_price: f64,
    /// Candle index at entry.
    pub entry_candle: usize,
    /// entry_candle + N — the clock.
    pub deadline: usize,
    /// Lifecycle state — same state machine as paper.
    pub state: PositionState,
}

/// The proposer's track record. The gate reads this to decide trust.
/// Expectancy derivable at query time, not stored.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct ProposerRecord {
    pub papers_submitted: usize,
    pub papers_survived: usize,
    pub papers_failed: usize,
    pub total_grace_residue: f64,
    pub total_violence_loss: f64,
}

/// Broker proposes an exit. Treasury validates the arithmetic.
#[derive(Debug, Clone)]
pub struct ExitProposal {
    pub paper_id: u64,
    pub current_price: f64,
}

/// Treasury's response to a resolution event.
/// Pushed down to brokers through their pipe.
#[derive(Debug, Clone, PartialEq)]
pub enum TreasuryVerdict {
    Grace { paper_id: u64, residue: f64 },
    Violence { paper_id: u64 },
}

/// The treasury — the bank. Headless. Blind to strategy.
/// Validates arithmetic. Enforces deadlines. Distributes yield.
#[derive(Debug)]
pub struct Treasury {
    /// All papers — the source of truth.
    pub papers: HashMap<u64, PaperPosition>,
    /// All real positions.
    pub real_positions: HashMap<u64, RealPosition>,
    /// Proposer records — the gate.
    pub proposer_records: HashMap<usize, ProposerRecord>,
    /// Asset balances.
    pub balances: HashMap<String, f64>,
    /// Next paper ID to issue.
    pub next_paper_id: u64,
    /// Next real position ID to issue.
    pub next_position_id: u64,
    /// Entry fee rate (e.g. 0.0035 for 0.35%).
    pub entry_fee: f64,
    /// Exit fee rate (e.g. 0.0035 for 0.35%).
    pub exit_fee: f64,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn proposer_record_default_is_all_zeros() {
        let record = ProposerRecord::default();
        assert_eq!(record.papers_submitted, 0);
        assert_eq!(record.papers_survived, 0);
        assert_eq!(record.papers_failed, 0);
        assert_eq!(record.total_grace_residue, 0.0);
        assert_eq!(record.total_violence_loss, 0.0);
    }

    #[test]
    fn position_state_starts_active() {
        let state = PositionState::Active;
        assert_eq!(state, PositionState::Active);
    }

    #[test]
    fn paper_position_can_be_constructed() {
        let paper = PaperPosition {
            paper_id: 0,
            owner: 0,
            from_asset: "USDC".to_string(),
            to_asset: "WBTC".to_string(),
            amount: 10_000.0,
            units_acquired: 0.1108,
            entry_price: 90_000.0,
            entry_candle: 100,
            deadline: 388,
            state: PositionState::Active,
        };
        assert_eq!(paper.paper_id, 0);
        assert_eq!(paper.amount, 10_000.0);
        assert_eq!(paper.state, PositionState::Active);
    }

    #[test]
    fn conservation_papers_dont_move_capital() {
        // Construct a treasury with known balances.
        let mut treasury = Treasury {
            papers: HashMap::new(),
            real_positions: HashMap::new(),
            proposer_records: HashMap::new(),
            balances: HashMap::from([
                ("USDC".to_string(), 100_000.0),
                ("WBTC".to_string(), 1.0),
            ]),
            next_paper_id: 0,
            next_position_id: 0,
            entry_fee: 0.0035,
            exit_fee: 0.0035,
        };

        let balance_before = treasury.balances["USDC"];

        // Issue a paper — this should NOT move capital.
        let paper_id = treasury.next_paper_id;
        treasury.next_paper_id += 1;

        let amount = 10_000.0;
        let price = 90_000.0;
        let fee = amount * treasury.entry_fee;
        let units = (amount - fee) / price;

        let paper = PaperPosition {
            paper_id,
            owner: 0,
            from_asset: "USDC".to_string(),
            to_asset: "WBTC".to_string(),
            amount,
            units_acquired: units,
            entry_price: price,
            entry_candle: 0,
            deadline: 288,
            state: PositionState::Active,
        };
        treasury.papers.insert(paper_id, paper);
        treasury
            .proposer_records
            .entry(0)
            .or_default()
            .papers_submitted += 1;

        // Balance unchanged — papers don't move capital.
        let balance_after = treasury.balances["USDC"];
        assert_eq!(
            balance_before, balance_after,
            "Papers must not move capital"
        );
    }
}
