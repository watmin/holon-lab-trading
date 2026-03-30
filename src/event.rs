//! Event — the enterprise's input vocabulary.
//!
//! The enterprise is a fold over Stream<Event>.
//! Every input is an Event. The enterprise doesn't know where events come from.
//! Backtest, websocket, test harness — same Event, same fold.

use crate::candle::Candle;

/// What the enterprise consumes. One event per fold iteration.
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
