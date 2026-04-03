//! Event — the enterprise's input vocabulary.
//!
//! The enterprise is a fold over Stream<Event>.
//! Every input is an Event. The enterprise doesn't know where events come from.
//! Backtest, websocket, test harness — same Event, same fold.
//!
//! The enterprise receives raw OHLCV. Each desk computes its own indicators.

use crate::indicators::RawCandle;
use crate::treasury::Asset;

/// The enterprise's fold input. One raw candle at a time.
/// No pre-computed indicators. No pre-encoded thoughts.
/// The desk computes everything from the raw OHLCV.
pub enum Event {
    /// A raw candle — just OHLCV + timestamp. The desk steps its indicator
    /// bank to produce computed indicators. No pre-computation.
    Candle(RawCandle),

    // rune:reap(aspirational) — Deposit and Withdraw are handled in on_event but
    // never constructed. Wired when streaming interface supports capital events.
    /// Capital deposited into the treasury.
    Deposit { asset: Asset, amount: f64 },

    /// Capital withdrawn from the treasury.
    Withdraw { asset: Asset, amount: f64 },
}
