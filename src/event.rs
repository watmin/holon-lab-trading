//! Event — the enterprise's input vocabulary.
//!
//! The enterprise is a fold over Stream<Event>.
//! Every input is an Event. The enterprise doesn't know where events come from.
//! Backtest, websocket, test harness — same Event, same fold.

use crate::candle::{Candle, load_candles};
use holon::Vector;
use std::path::Path;

// dead-thoughts:allow(scaffolding) — Event + stream constructors are the multi-asset streaming interface; wired when desks dispatch merged streams
/// Raw event before encoding. Used by stream constructors (merge_streams, with_recurring_deposits).
/// The fold consumes EnrichedEvent, not Event. Event is the source vocabulary; EnrichedEvent is the fold's input.
#[derive(Clone, Debug)]
pub enum Event {
    /// A new candle arrived for an asset.
    Candle {
        asset: String,
        candle: Candle,
    },

    /// Capital deposited into the treasury.
    /// The system evolves with new capital arriving over time.
    Deposit {
        asset: String,
        amount: f64,
    },

    /// Capital withdrawn from the treasury.
    Withdraw {
        asset: String,
        amount: f64,
    },
}

impl Event {
    /// Which asset does this event concern?
    pub fn asset(&self) -> &str {
        match self {
            Event::Candle { asset, .. } => asset,
            Event::Deposit { asset, .. } => asset,
            Event::Withdraw { asset, .. } => asset,
        }
    }

    /// The timestamp of this event (for ordering merged streams).
    pub fn timestamp(&self) -> &str {
        match self {
            Event::Candle { candle, .. } => &candle.ts,
            // Deposits and withdrawals carry no candle timestamp.
            // In a merged stream, they're ordered by insertion time.
            _ => "",
        }
    }
}

/// Enriched event — carries pre-computed encoding products.
///
/// The backtest runner pre-encodes in parallel, then wraps the results
/// in EnrichedEvent::Candle. A live runner would encode per-candle.
/// The enterprise folds over EnrichedEvent, not raw Event.
pub enum EnrichedEvent {
    /// A candle with pre-computed thought encodings.
    Candle {
        candle: Candle,
        fact_labels: Vec<String>,
        observer_vecs: Vec<Vector>,
    },

    // dead-thoughts:allow(scaffolding) — Deposit/Withdraw constructed by live feed or multi-asset recurring deposits
    /// Capital deposited into the treasury.
    Deposit { asset: String, amount: f64 },

    /// Capital withdrawn from the treasury.
    Withdraw { asset: String, amount: f64 },
}

// ─── Stream constructors ────────────────────────────────────────────────────

/// Convert already-loaded candles into an event stream.
/// Zero-copy of the candle data — wraps each candle with an asset tag.
pub fn stream_from_candles(candles: &[Candle], asset: &str) -> Vec<Event> {
    candles.iter()
        .map(|candle| Event::Candle {
            asset: asset.to_string(),
            candle: candle.clone(),
        })
        .collect()
}

/// Load a single asset's candles from a DB and produce an event stream.
/// Convenience: loads + wraps in one call.
pub fn stream_from_db(db_path: &Path, asset: &str, label_col: &str) -> Vec<Event> {
    let candles = load_candles(db_path, label_col);
    stream_from_candles(&candles, asset)
}

/// Merge multiple event streams by timestamp.
/// The merged stream is sorted — the enterprise processes events in time order.
/// This is the bridge to multi-asset: each asset's stream is merged into one.
pub fn merge_streams(streams: Vec<Vec<Event>>) -> Vec<Event> {
    let mut merged: Vec<Event> = streams.into_iter().flatten().collect();
    merged.sort_by(|a, b| a.timestamp().cmp(b.timestamp()));
    merged
}

/// Inject recurring deposits into a stream.
/// Every `interval` candles, deposit `amount` of `asset`.
/// The system evolves with new capital arriving over time.
pub fn with_recurring_deposits(
    mut events: Vec<Event>,
    asset: &str,
    amount: f64,
    interval: usize,
) -> Vec<Event> {
    let mut deposits = Vec::new();

    // Find candle timestamps at deposit intervals
    let mut candle_idx = 0;
    for event in &events {
        if let Event::Candle { candle: _, .. } = event {
            candle_idx += 1;
            if candle_idx % interval == 0 {
                deposits.push(Event::Deposit {
                    asset: asset.to_string(),
                    amount,
                });
                // We'll insert after this candle's timestamp
            }
        }
    }

    // For now, append deposits at end and re-sort
    // (proper interleaving would insert at the right timestamp)
    if !deposits.is_empty() {
        events.extend(deposits);
        events.sort_by(|a, b| a.timestamp().cmp(b.timestamp()));
    }

    events
}
