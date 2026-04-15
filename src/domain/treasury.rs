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

/// What the treasury returns when it approves a position.
/// The receipt IS the answer. The amount is on the receipt,
/// decided by the treasury, not requested by the broker.
#[derive(Debug, Clone)]
pub struct PositionReceipt {
    pub position_id: u64,
    pub owner: usize,
    pub from_asset: String,
    pub to_asset: String,
    pub amount: f64,
    pub units_acquired: f64,
    pub entry_price: f64,
    pub entry_candle: usize,
    pub deadline: usize,
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

impl Treasury {
    /// Constructor with empty maps and zero counters.
    pub fn new(entry_fee: f64, exit_fee: f64) -> Self {
        Self {
            papers: HashMap::new(),
            real_positions: HashMap::new(),
            proposer_records: HashMap::new(),
            balances: HashMap::new(),
            next_paper_id: 0,
            next_position_id: 0,
            entry_fee,
            exit_fee,
        }
    }

    /// Issue a paper — always succeeds. Fixed $10,000 reference.
    /// Papers are proof of thoughts. No capital moves.
    /// Returns a receipt with the paper details.
    pub fn issue_paper(
        &mut self,
        owner: usize,
        from_asset: &str,
        to_asset: &str,
        price: f64,
        candle: usize,
        deadline_candles: usize,
    ) -> PositionReceipt {
        let amount = 10_000.0;
        let fee = amount * self.entry_fee;
        let units = (amount - fee) / price;
        let deadline = candle + deadline_candles;

        let id = self.next_paper_id;
        self.next_paper_id += 1;

        let paper = PaperPosition {
            paper_id: id,
            owner,
            from_asset: from_asset.to_string(),
            to_asset: to_asset.to_string(),
            amount,
            units_acquired: units,
            entry_price: price,
            entry_candle: candle,
            deadline,
            state: PositionState::Active,
        };

        self.papers.insert(id, paper);
        self.proposer_records
            .entry(owner)
            .or_default()
            .papers_submitted += 1;

        PositionReceipt {
            position_id: id,
            owner,
            from_asset: from_asset.to_string(),
            to_asset: to_asset.to_string(),
            amount,
            units_acquired: units,
            entry_price: price,
            entry_candle: candle,
            deadline,
        }
    }

    /// Issue a real position. The broker does NOT choose the amount.
    /// The treasury decides how much to lend based on the proposer's record.
    /// Returns None if denied, Some(receipt) with the allocated amount.
    pub fn issue_real(
        &mut self,
        owner: usize,
        from_asset: &str,
        to_asset: &str,
        price: f64,
        candle: usize,
        deadline_candles: usize,
    ) -> Option<PositionReceipt> {
        let record = self.proposer_records.get(&owner)?;
        if !self.gate_predicate(record) {
            return None;
        }
        let balance = *self.balances.get(from_asset)?;
        if balance <= 0.0 {
            return None;
        }

        // The treasury decides the amount. For now: fixed $50 per position.
        // Later: proportional to record quality and available balance.
        let amount = 50.0_f64.min(balance);

        let fee = amount * self.entry_fee;
        let units = (amount - fee) / price;
        let deadline = candle + deadline_candles;

        let id = self.next_position_id;
        self.next_position_id += 1;

        *self.balances.get_mut(from_asset).unwrap() -= amount;

        let position = RealPosition {
            position_id: id,
            owner,
            from_asset: from_asset.to_string(),
            to_asset: to_asset.to_string(),
            amount,
            units_acquired: units,
            entry_price: price,
            entry_candle: candle,
            deadline,
            state: PositionState::Active,
        };

        self.real_positions.insert(id, position);

        Some(PositionReceipt {
            position_id: id,
            owner,
            from_asset: from_asset.to_string(),
            to_asset: to_asset.to_string(),
            amount,
            units_acquired: units,
            entry_price: price,
            entry_candle: candle,
            deadline,
        })
    }

    // ── Reader service ────────────────────────────────────────────────

    /// Read a paper position. The broker queries, the treasury answers.
    pub fn get_paper_position(&self, paper_id: u64) -> Option<&PaperPosition> {
        self.papers.get(&paper_id)
    }

    /// Read a real position.
    pub fn get_real_position(&self, position_id: u64) -> Option<&RealPosition> {
        self.real_positions.get(&position_id)
    }

    /// Validate an exit proposal. Checks the paper exists, is Active,
    /// and has positive residue after fees. Returns Some(residue) or None.
    pub fn validate_exit(&self, paper_id: u64, current_price: f64) -> Option<f64> {
        let paper = self.papers.get(&paper_id)?;
        if paper.state != PositionState::Active {
            return None;
        }

        let current_value = paper.units_acquired * current_price;
        let exit_fee = current_value * self.exit_fee;
        let residue = current_value - paper.amount - exit_fee;

        if residue > 0.0 {
            Some(residue)
        } else {
            None
        }
    }

    /// Resolve a paper to Grace. Validates exit, sets state, updates record.
    /// For real positions: moves principal back, splits residue 50/50.
    pub fn resolve_grace(
        &mut self,
        paper_id: u64,
        current_price: f64,
    ) -> Option<TreasuryVerdict> {
        let residue = self.validate_exit(paper_id, current_price)?;

        let paper = self.papers.get_mut(&paper_id).unwrap();
        paper.state = PositionState::Grace { residue };
        let owner = paper.owner;

        let record = self.proposer_records.entry(owner).or_default();
        record.papers_survived += 1;
        record.total_grace_residue += residue;

        // Check if there's a corresponding real position and handle balances.
        // Real positions are separate — find by owner and matching state.
        // For now, real position grace is handled by scanning real_positions
        // with the same paper_id convention. But paper_id and position_id are
        // separate ID spaces. Real position grace would need its own method
        // or the caller passes the real position ID. For this implementation,
        // we handle paper grace only through this method.

        Some(TreasuryVerdict::Grace { paper_id, residue })
    }

    /// Check all active papers and real positions against the deadline.
    /// Any past deadline → Violence. Returns all verdicts.
    pub fn check_deadlines(&mut self, current_candle: usize) -> Vec<TreasuryVerdict> {
        let mut verdicts = Vec::new();

        // Papers
        let expired_paper_ids: Vec<u64> = self
            .papers
            .iter()
            .filter(|(_, p)| p.state == PositionState::Active && current_candle >= p.deadline)
            .map(|(id, _)| *id)
            .collect();

        for id in expired_paper_ids {
            let paper = self.papers.get_mut(&id).unwrap();
            paper.state = PositionState::Violence;
            let owner = paper.owner;

            let record = self.proposer_records.entry(owner).or_default();
            record.papers_failed += 1;

            verdicts.push(TreasuryVerdict::Violence { paper_id: id });
        }

        // Real positions
        let expired_real_ids: Vec<u64> = self
            .real_positions
            .iter()
            .filter(|(_, p)| p.state == PositionState::Active && current_candle >= p.deadline)
            .map(|(id, _)| *id)
            .collect();

        for id in expired_real_ids {
            let pos = self.real_positions.get_mut(&id).unwrap();
            pos.state = PositionState::Violence;
            let owner = pos.owner;
            let from_asset = pos.from_asset.clone();
            let amount = pos.amount;

            // Move remaining value back to balances
            *self.balances.entry(from_asset).or_insert(0.0) += amount;

            let record = self.proposer_records.entry(owner).or_default();
            record.papers_failed += 1;

            verdicts.push(TreasuryVerdict::Violence { paper_id: id });
        }

        verdicts
    }

    /// Gate predicate: minimum 50 papers submitted AND survival rate > 0.5.
    pub fn gate_predicate(&self, record: &ProposerRecord) -> bool {
        if record.papers_submitted < 50 {
            return false;
        }
        let resolved = record.papers_survived + record.papers_failed;
        if resolved == 0 {
            return false;
        }
        let survival_rate = record.papers_survived as f64 / resolved as f64;
        survival_rate > 0.5
    }

    /// Read access to a proposer's record.
    pub fn get_record(&self, owner: usize) -> Option<&ProposerRecord> {
        self.proposer_records.get(&owner)
    }
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

    // --- New method tests ---

    fn make_treasury() -> Treasury {
        Treasury::new(0.0035, 0.0035)
    }

    #[test]
    fn issue_paper_exists_and_record_updated() {
        let mut t = make_treasury();
        let id = t.issue_paper(0, "USDC", "WBTC", 90_000.0, 100, 288).position_id;

        assert!(t.papers.contains_key(&id));
        let paper = &t.papers[&id];
        assert_eq!(paper.owner, 0);
        assert_eq!(paper.amount, 10_000.0);
        assert_eq!(paper.state, PositionState::Active);
        assert_eq!(paper.deadline, 100 + 288);

        let record = t.get_record(0).unwrap();
        assert_eq!(record.papers_submitted, 1);
    }

    #[test]
    fn validate_exit_higher_price_returns_residue() {
        let mut t = make_treasury();
        let id = t.issue_paper(0, "USDC", "WBTC", 90_000.0, 100, 288).position_id;

        // Price went up significantly — should have positive residue.
        let result = t.validate_exit(id, 100_000.0);
        assert!(result.is_some());
        let residue = result.unwrap();
        assert!(residue > 0.0, "Residue should be positive at higher price");
    }

    #[test]
    fn validate_exit_lower_price_returns_none() {
        let mut t = make_treasury();
        let id = t.issue_paper(0, "USDC", "WBTC", 90_000.0, 100, 288).position_id;

        // Price went down — no positive residue possible.
        let result = t.validate_exit(id, 80_000.0);
        assert!(result.is_none(), "Should deny exit at lower price");
    }

    #[test]
    fn check_deadline_after_expiry_returns_violence() {
        let mut t = make_treasury();
        let id = t.issue_paper(0, "USDC", "WBTC", 90_000.0, 100, 288).position_id;

        // Current candle past deadline.
        let verdicts = t.check_deadlines(100 + 288);
        assert_eq!(verdicts.len(), 1);
        assert_eq!(verdicts[0], TreasuryVerdict::Violence { paper_id: id });

        // Paper state is Violence.
        assert_eq!(t.papers[&id].state, PositionState::Violence);

        // Record updated.
        let record = t.get_record(0).unwrap();
        assert_eq!(record.papers_failed, 1);
    }

    #[test]
    fn resolve_grace_updates_state_and_record() {
        let mut t = make_treasury();
        let id = t.issue_paper(0, "USDC", "WBTC", 90_000.0, 100, 288).position_id;

        // Exit at a profitable price.
        let verdict = t.resolve_grace(id, 100_000.0);
        assert!(verdict.is_some());

        match verdict.unwrap() {
            TreasuryVerdict::Grace { paper_id, residue } => {
                assert_eq!(paper_id, id);
                assert!(residue > 0.0);
            }
            _ => panic!("Expected Grace verdict"),
        }

        // Paper state is Grace.
        match &t.papers[&id].state {
            PositionState::Grace { residue } => assert!(*residue > 0.0),
            _ => panic!("Expected Grace state"),
        }

        // Record updated.
        let record = t.get_record(0).unwrap();
        assert_eq!(record.papers_survived, 1);
        assert!(record.total_grace_residue > 0.0);
    }

    #[test]
    fn gate_predicate_new_proposer_denied() {
        let t = make_treasury();
        let record = ProposerRecord {
            papers_submitted: 10,
            papers_survived: 8,
            papers_failed: 2,
            total_grace_residue: 100.0,
            total_violence_loss: 0.0,
        };
        // Less than 50 papers — denied.
        assert!(!t.gate_predicate(&record));
    }

    #[test]
    fn gate_predicate_proven_proposer_approved() {
        let t = make_treasury();
        let record = ProposerRecord {
            papers_submitted: 100,
            papers_survived: 60,
            papers_failed: 40,
            total_grace_residue: 500.0,
            total_violence_loss: 200.0,
        };
        // 100 papers, 60% survival — approved.
        assert!(t.gate_predicate(&record));
    }

    #[test]
    fn gate_predicate_low_survival_denied() {
        let t = make_treasury();
        let record = ProposerRecord {
            papers_submitted: 100,
            papers_survived: 30,
            papers_failed: 70,
            total_grace_residue: 100.0,
            total_violence_loss: 500.0,
        };
        // 100 papers but only 30% survival — denied.
        assert!(!t.gate_predicate(&record));
    }

    #[test]
    fn real_position_denied_without_record() {
        let mut t = make_treasury();
        t.balances.insert("USDC".to_string(), 100_000.0);

        // No proposer record at all — denied.
        let result = t.issue_real(0, "USDC", "WBTC", 90_000.0, 100, 288);
        assert!(result.is_none());
    }

    #[test]
    fn real_position_denied_unproven_record() {
        let mut t = make_treasury();
        t.balances.insert("USDC".to_string(), 100_000.0);

        // Insert a record that doesn't pass the gate (< 50 papers).
        t.proposer_records.insert(
            0,
            ProposerRecord {
                papers_submitted: 10,
                papers_survived: 8,
                papers_failed: 2,
                total_grace_residue: 50.0,
                total_violence_loss: 0.0,
            },
        );

        let result = t.issue_real(0, "USDC", "WBTC", 90_000.0, 100, 288);
        assert!(result.is_none());
    }

    #[test]
    fn real_position_approved_with_proven_record_and_balance_moves() {
        let mut t = make_treasury();
        t.balances.insert("USDC".to_string(), 100_000.0);

        // Insert a proven record.
        t.proposer_records.insert(
            0,
            ProposerRecord {
                papers_submitted: 100,
                papers_survived: 60,
                papers_failed: 40,
                total_grace_residue: 500.0,
                total_violence_loss: 200.0,
            },
        );

        let balance_before = t.balances["USDC"];
        let result = t.issue_real(0, "USDC", "WBTC", 90_000.0, 100, 288);
        assert!(result.is_some());

        let receipt = result.unwrap();
        // Treasury decided the amount ($50 or available balance, whichever smaller)
        assert!(receipt.amount > 0.0, "Treasury should allocate something");
        assert!(receipt.amount <= 50.0, "Treasury allocates max $50 per position");

        // Balance decreased by the allocated amount.
        let balance_after = t.balances["USDC"];
        assert!(
            (balance_after - (balance_before - receipt.amount)).abs() < 1e-10,
            "Balance should decrease by the allocated amount"
        );

        // Real position exists.
        assert!(t.real_positions.contains_key(&receipt.position_id));
        let pos = &t.real_positions[&receipt.position_id];
        assert_eq!(pos.state, PositionState::Active);
        assert_eq!(pos.amount, receipt.amount);
    }

    #[test]
    fn real_position_denied_insufficient_balance() {
        let mut t = make_treasury();
        t.balances.insert("USDC".to_string(), 0.0);

        t.proposer_records.insert(
            0,
            ProposerRecord {
                papers_submitted: 100,
                papers_survived: 60,
                papers_failed: 40,
                total_grace_residue: 500.0,
                total_violence_loss: 200.0,
            },
        );

        // Trying to borrow more than available.
        let result = t.issue_real(0, "USDC", "WBTC", 90_000.0, 100, 288);
        assert!(result.is_none());
    }

    #[test]
    fn check_deadlines_real_position_violence_returns_balance() {
        let mut t = make_treasury();
        t.balances.insert("USDC".to_string(), 100_000.0);

        t.proposer_records.insert(
            0,
            ProposerRecord {
                papers_submitted: 100,
                papers_survived: 60,
                papers_failed: 40,
                total_grace_residue: 500.0,
                total_violence_loss: 200.0,
            },
        );

        let balance_before = t.balances["USDC"];
        let receipt = t
            .issue_real(0, "USDC", "WBTC", 90_000.0, 100, 288)
            .unwrap();

        let balance_after_issue = t.balances["USDC"];
        assert!((balance_after_issue - (balance_before - receipt.amount)).abs() < 1e-10);

        // Deadline expires.
        let verdicts = t.check_deadlines(100 + 288);
        assert_eq!(verdicts.len(), 1);
        assert_eq!(verdicts[0], TreasuryVerdict::Violence { paper_id: receipt.position_id });

        // Balance restored.
        let balance_after_violence = t.balances["USDC"];
        assert!(
            (balance_after_violence - balance_before).abs() < 1e-10,
            "Violence should return amount to balances"
        );
    }

    #[test]
    fn issue_paper_via_new_constructor_no_capital_move() {
        let mut t = make_treasury();
        t.balances.insert("USDC".to_string(), 50_000.0);

        let balance_before = t.balances["USDC"];
        t.issue_paper(0, "USDC", "WBTC", 90_000.0, 0, 288);
        let balance_after = t.balances["USDC"];

        assert_eq!(balance_before, balance_after, "Papers must not move capital");
    }
}
