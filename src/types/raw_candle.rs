/// Raw input types. Asset identifies a token. RawCandle is the enterprise's
/// only input — everything else is derived.

/// A named token (e.g. "USDC", "WBTC").
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Asset {
    pub name: String,
}

impl Asset {
    pub fn new(name: impl Into<String>) -> Self {
        Self { name: name.into() }
    }
}

/// One period of market data. Eight fields.
/// From the parquet. From the websocket. The enterprise doesn't care which.
#[derive(Clone, Debug)]
pub struct RawCandle {
    pub source_asset: Asset,
    pub target_asset: Asset,
    pub ts: String,
    pub open: f64,
    pub high: f64,
    pub low: f64,
    pub close: f64,
    pub volume: f64,
}

impl RawCandle {
    pub fn new(
        source_asset: Asset,
        target_asset: Asset,
        ts: impl Into<String>,
        open: f64,
        high: f64,
        low: f64,
        close: f64,
        volume: f64,
    ) -> Self {
        Self {
            source_asset,
            target_asset,
            ts: ts.into(),
            open,
            high,
            low,
            close,
            volume,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_asset_new() {
        let a = Asset::new("WBTC");
        assert_eq!(a.name, "WBTC");
    }

    #[test]
    fn test_asset_equality() {
        let a = Asset::new("USDC");
        let b = Asset::new("USDC");
        let c = Asset::new("WBTC");
        assert_eq!(a, b);
        assert_ne!(a, c);
    }

    #[test]
    fn test_asset_clone() {
        let a = Asset::new("WBTC");
        let b = a.clone();
        assert_eq!(a, b);
    }

    #[test]
    fn test_raw_candle_new() {
        let candle = RawCandle::new(
            Asset::new("USDC"),
            Asset::new("WBTC"),
            "2025-01-01T00:00:00Z",
            42000.0,
            42500.0,
            41800.0,
            42200.0,
            1500.0,
        );
        assert_eq!(candle.source_asset.name, "USDC");
        assert_eq!(candle.target_asset.name, "WBTC");
        assert_eq!(candle.ts, "2025-01-01T00:00:00Z");
        assert_eq!(candle.open, 42000.0);
        assert_eq!(candle.high, 42500.0);
        assert_eq!(candle.low, 41800.0);
        assert_eq!(candle.close, 42200.0);
        assert_eq!(candle.volume, 1500.0);
    }

    #[test]
    fn test_raw_candle_clone() {
        let candle = RawCandle::new(
            Asset::new("USDC"),
            Asset::new("WBTC"),
            "2025-01-01T00:00:00Z",
            42000.0,
            42500.0,
            41800.0,
            42200.0,
            1500.0,
        );
        let cloned = candle.clone();
        assert_eq!(cloned.source_asset, candle.source_asset);
        assert_eq!(cloned.target_asset, candle.target_asset);
        assert_eq!(cloned.close, candle.close);
    }
}
