/// treasury_program.rs — the treasury service thread body.
///
/// One mailbox. Ticks and requests arrive in natural order. The treasury
/// processes whatever comes next. A tick advances deadlines. A request
/// gets an immediate response. No polling. No spinning. No deadlock.
///
/// The broker calls treasury_handle.submit_paper() which wraps the request,
/// sends it into the shared mailbox, and blocks on the per-broker response
/// queue. The handle IS the interface.
///
/// On shutdown, returns the Treasury — the state comes home.

use crate::domain::treasury::{PositionReceipt, PositionState, Treasury};
use crate::programs::stdlib::console::ConsoleHandle;
use crate::services::mailbox::MailboxReceiver;
use crate::services::queue::{QueueReceiver, QueueSender};
use crate::types::log_entry::LogEntry;

// ─── Events ────────────────────────────────────────────────────────────────

/// Everything that enters the treasury's mailbox.
#[derive(Debug)]
pub enum TreasuryEvent {
    /// The candle clock. Advances deadlines.
    Tick { candle: usize, price: f64, atr: f64 },
    /// A broker request. The client_id indexes the response queue.
    Request { client_id: usize, request: TreasuryRequest },
}

/// What the broker can ask the treasury.
#[derive(Debug, Clone)]
pub enum TreasuryRequest {
    SubmitPaper {
        from_asset: String,
        to_asset: String,
        price: f64,
    },
    SubmitReal {
        from_asset: String,
        to_asset: String,
        price: f64,
    },
    SubmitExit {
        paper_id: u64,
        current_price: f64,
    },
    GetPaperState {
        paper_id: u64,
    },
}

/// What the treasury sends back.
#[derive(Debug, Clone)]
pub enum TreasuryResponse {
    PaperIssued(PositionReceipt),
    RealApproved(PositionReceipt),
    RealDenied,
    ExitApproved { position_id: u64, residue: f64 },
    ExitDenied,
    PaperState { position_id: u64, state: PositionState },
    NotFound,
}

// ─── Handle ────────────────────────────────────────────────────────────────

/// A broker's handle to the treasury. One per broker.
/// Send request into the shared mailbox, block on per-broker response.
pub struct TreasuryHandle {
    client_id: usize,
    event_tx: QueueSender<TreasuryEvent>,
    response_rx: QueueReceiver<TreasuryResponse>,
}

impl TreasuryHandle {
    pub fn new(
        client_id: usize,
        event_tx: QueueSender<TreasuryEvent>,
        response_rx: QueueReceiver<TreasuryResponse>,
    ) -> Self {
        Self { client_id, event_tx, response_rx }
    }

    /// Submit a paper proposal. Always succeeds. Returns the receipt.
    pub fn submit_paper(
        &self,
        from_asset: &str,
        to_asset: &str,
        price: f64,
    ) -> Option<PositionReceipt> {
        self.event_tx
            .send(TreasuryEvent::Request {
                client_id: self.client_id,
                request: TreasuryRequest::SubmitPaper {
                    from_asset: from_asset.to_string(),
                    to_asset: to_asset.to_string(),
                    price,
                },
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
        from_asset: &str,
        to_asset: &str,
        price: f64,
    ) -> Option<PositionReceipt> {
        self.event_tx
            .send(TreasuryEvent::Request {
                client_id: self.client_id,
                request: TreasuryRequest::SubmitReal {
                    from_asset: from_asset.to_string(),
                    to_asset: to_asset.to_string(),
                    price,
                },
            })
            .ok()?;
        match self.response_rx.recv().ok()? {
            TreasuryResponse::RealApproved(receipt) => Some(receipt),
            _ => None,
        }
    }

    /// Submit an exit. Returns Some(residue) if approved, None if denied.
    pub fn submit_exit(&self, paper_id: u64, current_price: f64) -> Option<f64> {
        self.event_tx
            .send(TreasuryEvent::Request {
                client_id: self.client_id,
                request: TreasuryRequest::SubmitExit {
                    paper_id,
                    current_price,
                },
            })
            .ok()?;
        match self.response_rx.recv().ok()? {
            TreasuryResponse::ExitApproved { residue, .. } => Some(residue),
            _ => None,
        }
    }

    /// Query a paper position's state. Returns the state or None.
    pub fn get_paper_state(&self, paper_id: u64) -> Option<PositionState> {
        self.event_tx
            .send(TreasuryEvent::Request {
                client_id: self.client_id,
                request: TreasuryRequest::GetPaperState { paper_id },
            })
            .ok()?;
        match self.response_rx.recv().ok()? {
            TreasuryResponse::PaperState { state, .. } => Some(state),
            _ => None,
        }
    }
}

// ─── Request handler ───────────────────────────────────────────────────────

/// Process one request. Pure function.
fn handle_request(
    treasury: &mut Treasury,
    client_id: usize,
    request: TreasuryRequest,
    candle: usize,
    deadline_candles: usize,
) -> TreasuryResponse {
    match request {
        TreasuryRequest::SubmitPaper {
            from_asset,
            to_asset,
            price,
        } => {
            let receipt = treasury.issue_paper(
                client_id, &from_asset, &to_asset, price, candle, deadline_candles,
            );
            TreasuryResponse::PaperIssued(receipt)
        }
        TreasuryRequest::SubmitReal {
            from_asset,
            to_asset,
            price,
        } => match treasury.issue_real(
            client_id, &from_asset, &to_asset, price, candle, deadline_candles,
        ) {
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
                TreasuryResponse::ExitApproved { position_id: paper_id, residue }
            }
            None => TreasuryResponse::ExitDenied,
        },
        TreasuryRequest::GetPaperState { paper_id } => {
            match treasury.get_paper_position(paper_id) {
                Some(paper) => TreasuryResponse::PaperState {
                    position_id: paper_id,
                    state: paper.state.clone(),
                },
                None => TreasuryResponse::NotFound,
            }
        }
    }
}

// ─── Program ───────────────────────────────────────────────────────────────

/// Run the treasury service. One recv loop. Two-level match.
/// Returns the Treasury when the mailbox disconnects.
pub fn treasury_program(
    event_rx: MailboxReceiver<TreasuryEvent>,
    client_txs: Vec<QueueSender<TreasuryResponse>>,
    console: ConsoleHandle,
    _db_tx: QueueSender<LogEntry>,
    mut treasury: Treasury,
    base_deadline: usize,
) -> Treasury {
    let mut candle_count = 0usize;
    let mut current_candle = 0usize;

    while let Ok(event) = event_rx.recv() {
        match event {
            TreasuryEvent::Tick { candle, price, .. } => {
                candle_count += 1;
                current_candle = candle;

                // Advance deadlines — the treasury's autonomous action.
                let _ = treasury.check_deadlines(candle, price);

                // Diagnostics every 1000 candles.
                if candle_count % 1000 == 0 {
                    let active_papers = treasury
                        .papers
                        .values()
                        .filter(|p| p.state == PositionState::Active)
                        .count();
                    let total_submitted: usize = treasury
                        .proposer_records
                        .values()
                        .map(|r| r.paper_submitted)
                        .sum();
                    let total_survived: usize = treasury
                        .proposer_records
                        .values()
                        .map(|r| r.paper_survived)
                        .sum();
                    console.out(format!(
                        "treasury: candle={} active={} submitted={} survived={}",
                        candle, active_papers, total_submitted, total_survived,
                    ));
                }
            }

            TreasuryEvent::Request { client_id, request } => {
                let response = handle_request(
                    &mut treasury,
                    client_id,
                    request,
                    current_candle,
                    base_deadline,
                );
                if client_id < client_txs.len() {
                    let _ = client_txs[client_id].send(response);
                }
            }
        }
    }

    // The state comes home.
    treasury
}

// ─── Tick sender helper ────────────────────────────────────────────────────

/// A handle for the main loop to send ticks. Wraps the event sender.
pub struct TreasuryTickSender {
    event_tx: QueueSender<TreasuryEvent>,
}

impl TreasuryTickSender {
    pub fn new(event_tx: QueueSender<TreasuryEvent>) -> Self {
        Self { event_tx }
    }

    pub fn send_tick(&self, candle: usize, price: f64, atr: f64) {
        let _ = self.event_tx.send(TreasuryEvent::Tick { candle, price, atr });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn treasury_event_tick() {
        let event = TreasuryEvent::Tick { candle: 100, price: 90_000.0, atr: 1500.0 };
        assert!(matches!(event, TreasuryEvent::Tick { .. }));
    }

    #[test]
    fn treasury_event_request() {
        let event = TreasuryEvent::Request {
            client_id: 0,
            request: TreasuryRequest::SubmitPaper {
                from_asset: "USDC".to_string(),
                to_asset: "WBTC".to_string(),
                price: 90_000.0,
            },
        };
        assert!(matches!(event, TreasuryEvent::Request { .. }));
    }

    #[test]
    fn handle_request_submit_paper() {
        let mut treasury = Treasury::new(0.0035, 0.0035);
        let resp = handle_request(
            &mut treasury,
            0,
            TreasuryRequest::SubmitPaper {
                from_asset: "USDC".to_string(),
                to_asset: "WBTC".to_string(),
                price: 90_000.0,
            },
            100,
            288,
        );
        assert!(matches!(resp, TreasuryResponse::PaperIssued(_)));
        assert_eq!(treasury.papers.len(), 1);
    }

    #[test]
    fn handle_request_get_paper_state() {
        let mut treasury = Treasury::new(0.0035, 0.0035);
        let receipt = treasury.issue_paper(0, "USDC", "WBTC", 90_000.0, 100, 288);

        let resp = handle_request(
            &mut treasury,
            0,
            TreasuryRequest::GetPaperState { paper_id: receipt.position_id },
            100,
            288,
        );
        assert!(matches!(
            resp,
            TreasuryResponse::PaperState { state: PositionState::Active, .. }
        ));
    }

    #[test]
    fn handle_request_not_found() {
        let mut treasury = Treasury::new(0.0035, 0.0035);
        let resp = handle_request(
            &mut treasury,
            0,
            TreasuryRequest::GetPaperState { paper_id: 999 },
            100,
            288,
        );
        assert!(matches!(resp, TreasuryResponse::NotFound));
    }
}
