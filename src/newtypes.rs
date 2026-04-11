/// Distinct types wrapping primitives. A newtype is about MEANING, not
/// structure. TradeId is not a usize — it is a TradeId that happens to
/// be represented as a usize.

/// Treasury's key for active trades. Assigned at funding time.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct TradeId(pub usize);

impl TradeId {
    /// Named constructor. (Test-only — production uses TradeId(n) directly.)
    #[cfg(test)]
    pub fn new(id: usize) -> Self {
        Self(id)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashSet;

    #[test]
    fn test_trade_id_new() {
        let id = TradeId::new(42);
        assert_eq!(id.0, 42);
    }

    #[test]
    fn test_trade_id_tuple_constructor() {
        let id = TradeId(7);
        assert_eq!(id.0, 7);
    }

    #[test]
    fn test_trade_id_equality() {
        let a = TradeId(1);
        let b = TradeId(1);
        let c = TradeId(2);
        assert_eq!(a, b);
        assert_ne!(a, c);
    }

    #[test]
    fn test_trade_id_copy() {
        let a = TradeId(5);
        let b = a; // Copy, not move
        assert_eq!(a, b); // a is still usable
    }

    #[test]
    fn test_trade_id_clone() {
        let a = TradeId(10);
        let b = a.clone();
        assert_eq!(a, b);
    }

    #[test]
    fn test_trade_id_hash() {
        let mut set = HashSet::new();
        set.insert(TradeId(1));
        set.insert(TradeId(2));
        set.insert(TradeId(1)); // duplicate
        assert_eq!(set.len(), 2);
        assert!(set.contains(&TradeId(1)));
        assert!(set.contains(&TradeId(2)));
    }
}
