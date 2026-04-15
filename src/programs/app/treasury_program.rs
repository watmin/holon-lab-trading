/// treasury_program.rs — the treasury service thread body.
///
/// The treasury is a service. Brokers are clients. The broker submits
/// requests and reads responses. The treasury does not push.
///
/// Request-response per client (like the cache service).
/// One request type, one response type. The broker sends a TreasuryRequest,
/// blocks on the response. The treasury processes and replies.
///
/// The treasury's only autonomous action: deadline enforcement on tick.
/// Brokers discover deadline Violence by querying their positions.
///
/// On shutdown, returns the Treasury — the state comes home.

use crate::domain::treasury::{
    PositionReceipt, PositionState, Treasury,
};
use crate::programs::stdlib::console::ConsoleHandle;
use crate::services::queue::{QueueReceiver, QueueSender};
use crate::types::log_entry::LogEntry;

/// Candle tick — the treasury's clock.
#[derive(Debug, Clone)]
pub struct TreasuryTick {
    pub candle: usize,
    pub price: f64,
    pub atr: f64,
}

/// A broker's request to the treasury.
#[derive(Debug, Clone)]
pub enum TreasuryRequest {
    /// Submit a paper proposal. Always succeeds.
    SubmitPaper {
        owner: usize,
        from_asset: String,
        to_asset: String,
        price: f64,
    },
    /// Submit a real proposal. Treasury decides amount. May be denied.
    SubmitReal {
        owner: usize,
        from_asset: String,
        to_asset: String,
        price: f64,
    },
    /// Submit an exit proposal. Treasury validates the arithmetic.
    SubmitExit {
        paper_id: u64,
        current_price: f64,
    },
    /// Query a paper position's current state.
    GetPaperPosition {
        paper_id: u64,
    },
}

/// The treasury's response to a broker request.
#[derive(Debug, Clone)]
pub enum TreasuryResponse {
    /// Paper issued. Here's the receipt.
    PaperIssued(PositionReceipt),
    /// Real position approved. Here's the receipt.
    RealApproved(PositionReceipt),
    /// Real position denied. No record, insufficient balance, or unproven.
    RealDenied,
    /// Exit approved. Grace. Here's the residue.
    ExitApproved { paper_id: u64, residue: f64 },
    /// Exit denied. Residue doesn't cover fees. Keep holding.
    ExitDenied,
    /// Position state query result.
    PaperState { paper_id: u64, state: PositionState },
    /// Position not found.
    NotFound,
}

/// A broker's handle to the treasury service. One per broker.
/// Request-response: send request, block for response.
pub struct TreasuryHandle {
    pub request_tx: QueueSender<TreasuryRequest>,
    pub response_rx: QueueReceiver<TreasuryResponse>,
}

impl TreasuryHandle {
    /// Submit a paper proposal. Always succeeds. Returns the receipt.
    pub fn submit_paper(
        &self,
        owner: usize,
        from_asset: &str,
        to_asset: &str,
        price: f64,
    ) -> Option<PositionReceipt> {
        self.request_tx
            .send(TreasuryRequest::SubmitPaper {
                owner,
                from_asset: from_asset.to_string(),
                to_asset: to_asset.to_string(),
                price,
            })
            .ok()?;
        match self.response_rx.recv().ok()? {
            TreasuryResponse::PaperIssued(receipt) => Some(receipt),
            _ => None,
        }
    }

    /// Submit a real proposal. Treasury decides amount. Returns receipt or None.
    pub fn submit_real(
        &self,
        owner: usize,
        from_asset: &str,
        to_asset: &str,
        price: f64,
    ) -> Option<PositionReceipt> {
        self.request_tx
            .send(TreasuryRequest::SubmitReal {
                owner,
                from_asset: from_asset.to_string(),
                to_asset: to_asset.to_string(),
                price,
            })
            .ok()?;
        match self.response_rx.recv().ok()? {
            TreasuryResponse::RealApproved(receipt) => Some(receipt),
            _ => None,
        }
    }

    /// Submit an exit. Returns Some(residue) if approved, None if denied.
    pub fn submit_exit(&self, paper_id: u64, current_price: f64) -> Option<f64> {
        self.request_tx
            .send(TreasuryRequest::SubmitExit {
                paper_id,
                current_price,
            })
            .ok()?;
        match self.response_rx.recv().ok()? {
            TreasuryResponse::ExitApproved { residue, .. } => Some(residue),
            _ => None,
        }
    }

    /// Query a paper position's state. Returns the state or None if not found.
    pub fn get_paper_state(&self, paper_id: u64) -> Option<PositionState> {
        self.request_tx
            .send(TreasuryRequest::GetPaperPosition { paper_id })
            .ok()?;
        match self.response_rx.recv().ok()? {
            TreasuryResponse::PaperState { state, .. } => Some(state),
            _ => None,
        }
    }
}

/// Process one request against the treasury. Pure function.
fn handle_request(
    treasury: &mut Treasury,
    request: TreasuryRequest,
    candle: usize,
    deadline_candles: usize,
) -> TreasuryResponse {
    match request {
        TreasuryRequest::SubmitPaper {
            owner,
            from_asset,
            to_asset,
            price,
        } => {
            let receipt =
                treasury.issue_paper(owner, &from_asset, &to_asset, price, candle, deadline_candles);
            TreasuryResponse::PaperIssued(receipt)
        }
        TreasuryRequest::SubmitReal {
            owner,
            from_asset,
            to_asset,
            price,
        } => match treasury.issue_real(owner, &from_asset, &to_asset, price, candle, deadline_candles)
        {
            Some(receipt) => TreasuryResponse::RealApproved(receipt),
            None => TreasuryResponse::RealDenied,
        },
        TreasuryRequest::SubmitExit {
            paper_id,
            current_price,
        } => match treasury.resolve_grace(paper_id, current_price) {
            Some(verdict) => {
                let residue = match verdict {
                    crate::domain::treasury::TreasuryVerdict::Grace { residue, .. } => residue,
                    _ => 0.0,
                };
                TreasuryResponse::ExitApproved { paper_id, residue }
            }
            None => TreasuryResponse::ExitDenied,
        },
        TreasuryRequest::GetPaperPosition { paper_id } => {
            match treasury.get_paper_position(paper_id) {
                Some(paper) => TreasuryResponse::PaperState {
                    paper_id,
                    state: paper.state.clone(),
                },
                None => TreasuryResponse::NotFound,
            }
        }
    }
}

/// Run the treasury service. Call this inside thread::spawn.
/// Returns the Treasury when the tick source disconnects.
pub fn treasury_program(
    tick_rx: QueueReceiver<TreasuryTick>,
    client_rxs: Vec<QueueReceiver<TreasuryRequest>>,
    client_txs: Vec<QueueSender<TreasuryResponse>>,
    console: ConsoleHandle,
    _db_tx: QueueSender<LogEntry>,
    mut treasury: Treasury,
    base_deadline: usize,
) -> Treasury {
    let mut candle_count = 0usize;
    let mut current_candle = 0usize;

    while let Ok(tick) = tick_rx.recv() {
        candle_count += 1;
        current_candle = tick.candle;

        // 1. Check deadlines — the treasury's only autonomous action.
        let _ = treasury.check_deadlines(tick.candle);

        // 2. Service all client requests — round-robin, non-blocking.
        // Each client may have submitted requests since last tick.
        for (i, rx) in client_rxs.iter().enumerate() {
            while let Ok(request) = rx.try_recv() {
                let response = handle_request(
                    &mut treasury,
                    request,
                    tick.candle,
                    base_deadline,
                );
                if i < client_txs.len() {
                    let _ = client_txs[i].send(response);
                }
            }
        }

        // 3. Diagnostics every 1000 candles.
        if candle_count % 1000 == 0 {
            let active_papers = treasury
                .papers
                .values()
                .filter(|p| p.state == PositionState::Active)
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

    // GRACEFUL SHUTDOWN. Service remaining requests.
    for (i, rx) in client_rxs.iter().enumerate() {
        while let Ok(request) = rx.try_recv() {
            let response = handle_request(
                &mut treasury,
                request,
                current_candle,
                base_deadline,
            );
            if i < client_txs.len() {
                let _ = client_txs[i].send(response);
            }
        }
    }

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
    }

    #[test]
    fn treasury_request_submit_paper() {
        let req = TreasuryRequest::SubmitPaper {
            owner: 0,
            from_asset: "USDC".to_string(),
            to_asset: "WBTC".to_string(),
            price: 90_000.0,
        };
        assert!(matches!(req, TreasuryRequest::SubmitPaper { .. }));
    }

    #[test]
    fn treasury_response_variants() {
        let denied = TreasuryResponse::RealDenied;
        assert!(matches!(denied, TreasuryResponse::RealDenied));

        let exit_denied = TreasuryResponse::ExitDenied;
        assert!(matches!(exit_denied, TreasuryResponse::ExitDenied));
    }

    #[test]
    fn handle_request_submit_paper() {
        let mut treasury = Treasury::new(0.0035, 0.0035);
        let req = TreasuryRequest::SubmitPaper {
            owner: 0,
            from_asset: "USDC".to_string(),
            to_asset: "WBTC".to_string(),
            price: 90_000.0,
        };
        let resp = handle_request(&mut treasury, req, 100, 288);
        assert!(matches!(resp, TreasuryResponse::PaperIssued(_)));
        assert_eq!(treasury.papers.len(), 1);
    }

    #[test]
    fn handle_request_get_paper_position() {
        let mut treasury = Treasury::new(0.0035, 0.0035);
        let receipt = treasury.issue_paper(0, "USDC", "WBTC", 90_000.0, 100, 288);

        let req = TreasuryRequest::GetPaperPosition {
            paper_id: receipt.position_id,
        };
        let resp = handle_request(&mut treasury, req, 100, 288);
        assert!(matches!(
            resp,
            TreasuryResponse::PaperState {
                state: PositionState::Active,
                ..
            }
        ));
    }

    #[test]
    fn handle_request_get_nonexistent_paper() {
        let mut treasury = Treasury::new(0.0035, 0.0035);
        let req = TreasuryRequest::GetPaperPosition { paper_id: 999 };
        let resp = handle_request(&mut treasury, req, 100, 288);
        assert!(matches!(resp, TreasuryResponse::NotFound));
    }
}
