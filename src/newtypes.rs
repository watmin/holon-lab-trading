//! newtypes.wat -- distinct types wrapping primitives
//! Depends on: nothing

/// TradeId -- the treasury's key for active trades.
/// Not a raw integer -- a distinct type the compiler enforces.
/// Assigned at funding time.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct TradeId(pub usize);

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_trade_id_wraps_usize() {
        let id = TradeId(42);
        assert_eq!(id.0, 42);
    }

    #[test]
    fn test_trade_id_copy() {
        let a = TradeId(7);
        let b = a; // Copy
        assert_eq!(a, b);
    }

    #[test]
    fn test_trade_id_eq_hash() {
        use std::collections::HashSet;
        let mut set = HashSet::new();
        set.insert(TradeId(1));
        set.insert(TradeId(2));
        set.insert(TradeId(1)); // duplicate
        assert_eq!(set.len(), 2);
    }

    #[test]
    fn test_trade_id_distinct_from_raw_usize() {
        // TradeId(0) and TradeId(1) are different even though both are usize
        assert_ne!(TradeId(0), TradeId(1));
    }
}
