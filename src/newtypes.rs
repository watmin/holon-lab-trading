/// TradeId — the treasury's key for active trades.
/// Not a raw usize — a distinct type the compiler enforces.

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct TradeId(pub usize);

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashSet;

    #[test]
    fn test_trade_id_copy() {
        let id = TradeId(42);
        let id2 = id; // Copy
        assert_eq!(id, id2);
    }

    #[test]
    fn test_trade_id_eq_hash() {
        let mut set = HashSet::new();
        set.insert(TradeId(1));
        set.insert(TradeId(2));
        set.insert(TradeId(1)); // duplicate
        assert_eq!(set.len(), 2);
    }

    #[test]
    fn test_trade_id_inner() {
        let id = TradeId(99);
        assert_eq!(id.0, 99);
    }
}
