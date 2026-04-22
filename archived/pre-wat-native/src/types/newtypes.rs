/// Distinct types wrapping primitives. A newtype is about MEANING, not
/// structure. TradeId is not a usize — it is a TradeId that happens to
/// be represented as a usize.

/// Treasury's key for active trades. Assigned at funding time.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct TradeId(pub usize);

/// Price — a monetary value in the denomination currency.
#[derive(Clone, Copy, Debug, PartialEq, PartialOrd)]
pub struct Price(pub f64);

impl std::ops::Add for Price {
    type Output = Self;
    fn add(self, rhs: Self) -> Self { Price(self.0 + rhs.0) }
}

impl std::ops::Sub for Price {
    type Output = Self;
    fn sub(self, rhs: Self) -> Self { Price(self.0 - rhs.0) }
}

impl std::ops::Mul<f64> for Price {
    type Output = Self;
    fn mul(self, rhs: f64) -> Self { Price(self.0 * rhs) }
}

impl std::ops::Div<f64> for Price {
    type Output = Self;
    fn div(self, rhs: f64) -> Self { Price(self.0 / rhs) }
}

/// Amount — a quantity of capital.
#[derive(Clone, Copy, Debug, PartialEq, PartialOrd)]
pub struct Amount(pub f64);

impl std::ops::Add for Amount {
    type Output = Self;
    fn add(self, rhs: Self) -> Self { Amount(self.0 + rhs.0) }
}

impl std::ops::Sub for Amount {
    type Output = Self;
    fn sub(self, rhs: Self) -> Self { Amount(self.0 - rhs.0) }
}

impl std::ops::Mul<f64> for Amount {
    type Output = Self;
    fn mul(self, rhs: f64) -> Self { Amount(self.0 * rhs) }
}

impl std::ops::Div<f64> for Amount {
    type Output = Self;
    fn div(self, rhs: f64) -> Self { Amount(self.0 / rhs) }
}

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

    #[test]
    fn test_price_arithmetic() {
        let a = Price(100.0);
        let b = Price(50.0);
        assert_eq!((a + b).0, 150.0);
        assert_eq!((a - b).0, 50.0);
        assert_eq!((a * 2.0).0, 200.0);
        assert_eq!((a / 4.0).0, 25.0);
    }

    #[test]
    fn test_price_copy() {
        let a = Price(42.0);
        let b = a;
        assert_eq!(a, b);
    }

    #[test]
    fn test_amount_arithmetic() {
        let a = Amount(1000.0);
        let b = Amount(300.0);
        assert_eq!((a + b).0, 1300.0);
        assert_eq!((a - b).0, 700.0);
        assert_eq!((a * 0.5).0, 500.0);
        assert_eq!((a / 2.0).0, 500.0);
    }

    #[test]
    fn test_amount_copy() {
        let a = Amount(99.0);
        let b = a;
        assert_eq!(a, b);
    }
}
