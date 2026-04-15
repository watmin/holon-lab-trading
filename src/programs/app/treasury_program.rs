/// treasury_program.rs — the treasury thread body.
///
/// Receives candle ticks, entry proposals, and exit proposals.
/// Issues papers, validates exits, enforces deadlines.
/// Sends verdicts to brokers through per-broker pipes.
/// On shutdown, returns the Treasury — the state comes home.

use crate::domain::treasury::{ExitProposal, Treasury, TreasuryVerdict};
use crate::programs::stdlib::console::ConsoleHandle;
use crate::services::mailbox::MailboxReceiver;
use crate::services::queue::{QueueReceiver, QueueSender};
use crate::types::log_entry::LogEntry;

/// Candle tick — minimal info the treasury needs each candle.
#[derive(Debug, Clone)]
pub struct TreasuryTick {
    pub candle: usize,
    pub price: f64,
    pub atr: f64,
}

/// Entry proposal from a broker.
#[derive(Debug, Clone)]
pub struct EntryProposal {
    pub owner: usize,
    pub from_asset: String,
    pub to_asset: String,
    pub price: f64,
    pub is_real: bool,
    pub amount: f64,
}

/// Drain all pending entry proposals. Non-blocking.
/// Issues papers (and reals if proven). Collects verdicts.
fn drain_entries(
    entry_rx: &MailboxReceiver<EntryProposal>,
    treasury: &mut Treasury,
    candle: usize,
    deadline_candles: usize,
    verdicts: &mut Vec<(usize, TreasuryVerdict)>,
) {
    while let Ok(proposal) = entry_rx.try_recv() {
        // Always issue a paper.
        let paper_id = treasury.issue_paper(
            proposal.owner,
            &proposal.from_asset,
            &proposal.to_asset,
            proposal.price,
            candle,
            deadline_candles,
        );

        // If real requested, attempt real issuance.
        if proposal.is_real {
            let _ = treasury.issue_real(
                proposal.owner,
                &proposal.from_asset,
                &proposal.to_asset,
                proposal.amount,
                proposal.price,
                candle,
                deadline_candles,
            );
        }

        // Acknowledge the paper to the broker via Grace with zero residue.
        // The broker needs to know the paper_id.
        verdicts.push((
            proposal.owner,
            TreasuryVerdict::Grace {
                paper_id,
                residue: 0.0,
            },
        ));
    }
}

/// Drain all pending exit proposals. Non-blocking.
/// Validates and resolves grace where possible.
fn drain_exits(
    exit_rx: &MailboxReceiver<ExitProposal>,
    treasury: &mut Treasury,
    verdicts: &mut Vec<(usize, TreasuryVerdict)>,
) {
    while let Ok(proposal) = exit_rx.try_recv() {
        // Look up the paper to find the owner.
        let owner = match treasury.papers.get(&proposal.paper_id) {
            Some(paper) => paper.owner,
            None => continue,
        };

        // Attempt grace resolution.
        match treasury.resolve_grace(proposal.paper_id, proposal.current_price) {
            Some(verdict) => {
                verdicts.push((owner, verdict));
            }
            None => {
                // Exit denied — no positive residue. No verdict sent.
            }
        }
    }
}

/// Run the treasury program. Call this inside thread::spawn.
/// Returns the Treasury when the tick source disconnects.
pub fn treasury_program(
    tick_rx: QueueReceiver<TreasuryTick>,
    entry_rx: MailboxReceiver<EntryProposal>,
    exit_rx: MailboxReceiver<ExitProposal>,
    verdict_txs: Vec<QueueSender<TreasuryVerdict>>,
    console: ConsoleHandle,
    _db_tx: QueueSender<LogEntry>,
    mut treasury: Treasury,
    base_deadline: usize,
) -> Treasury {
    let mut candle_count = 0usize;

    while let Ok(tick) = tick_rx.recv() {
        candle_count += 1;
        let mut verdicts: Vec<(usize, TreasuryVerdict)> = Vec::new();

        // 1. LEARN FIRST. Drain entry proposals before the tick.
        drain_entries(
            &entry_rx,
            &mut treasury,
            tick.candle,
            base_deadline,
            &mut verdicts,
        );

        // 2. Drain exit proposals.
        drain_exits(&exit_rx, &mut treasury, &mut verdicts);

        // 3. Tick received (blocking recv above).

        // 4. Check deadlines at current candle.
        let deadline_verdicts = treasury.check_deadlines(tick.candle);
        for v in deadline_verdicts {
            // Find the owner from the verdict's paper_id.
            let owner = match &v {
                TreasuryVerdict::Grace { paper_id, .. }
                | TreasuryVerdict::Violence { paper_id } => {
                    treasury
                        .papers
                        .get(paper_id)
                        .map(|p| p.owner)
                        .unwrap_or(0)
                }
            };
            verdicts.push((owner, v));
        }

        // 5. Send all verdicts to their respective brokers.
        for (owner, verdict) in verdicts {
            if owner < verdict_txs.len() {
                let _ = verdict_txs[owner].send(verdict);
            }
        }

        // 6. Diagnostics every 1000 candles.
        if candle_count % 1000 == 0 {
            let active_papers = treasury
                .papers
                .values()
                .filter(|p| {
                    p.state == crate::domain::treasury::PositionState::Active
                })
                .count();
            let total_records: usize = treasury
                .proposer_records
                .values()
                .map(|r| r.papers_submitted)
                .sum();
            console.out(format!(
                "treasury: candle={} active_papers={} total_submitted={}",
                tick.candle, active_papers, total_records,
            ));
        }
    }

    // GRACEFUL SHUTDOWN. Drain remaining proposals one last time.
    drain_entries(
        &entry_rx,
        &mut treasury,
        candle_count,
        base_deadline,
        &mut Vec::new(),
    );
    drain_exits(&exit_rx, &mut treasury, &mut Vec::new());

    // The state comes home.
    treasury
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn treasury_tick_can_be_constructed() {
        let tick = TreasuryTick {
            candle: 100,
            price: 90_000.0,
            atr: 1500.0,
        };
        assert_eq!(tick.candle, 100);
        assert_eq!(tick.price, 90_000.0);
        assert_eq!(tick.atr, 1500.0);
    }

    #[test]
    fn entry_proposal_can_be_constructed() {
        let proposal = EntryProposal {
            owner: 0,
            from_asset: "USDC".to_string(),
            to_asset: "WBTC".to_string(),
            price: 90_000.0,
            is_real: false,
            amount: 0.0,
        };
        assert_eq!(proposal.owner, 0);
        assert_eq!(proposal.from_asset, "USDC");
        assert!(!proposal.is_real);
    }

    #[test]
    fn entry_proposal_real_with_amount() {
        let proposal = EntryProposal {
            owner: 2,
            from_asset: "USDC".to_string(),
            to_asset: "WBTC".to_string(),
            price: 95_000.0,
            is_real: true,
            amount: 5_000.0,
        };
        assert!(proposal.is_real);
        assert_eq!(proposal.amount, 5_000.0);
    }
}
