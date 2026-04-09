//! newtypes.wat -- distinct types wrapping primitives
//! Depends on: nothing

/// TradeId -- the treasury's key for active trades.
/// Not a raw integer -- a distinct type the compiler enforces.
/// Assigned at funding time.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct TradeId(pub usize);
