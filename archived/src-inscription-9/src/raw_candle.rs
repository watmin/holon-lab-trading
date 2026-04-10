/// Asset and RawCandle — the only input to the enterprise.

/// A named token (e.g. "BTC", "USD").
#[derive(Clone, Debug)]
pub struct Asset {
    pub name: String,
}

impl Asset {
    pub fn new(name: impl Into<String>) -> Self {
        Self { name: name.into() }
    }
}

/// The raw candle from the market — eight fields.
/// From the parquet. From the websocket.
/// The asset pair IS the routing key.
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
        let a = Asset::new("BTC");
        assert_eq!(a.name, "BTC");
    }

    #[test]
    fn test_raw_candle_new() {
        let rc = RawCandle::new(
            Asset::new("BTC"),
            Asset::new("USD"),
            "2024-01-01T00:00:00",
            42000.0,
            42500.0,
            41500.0,
            42200.0,
            100.0,
        );
        assert_eq!(rc.source_asset.name, "BTC");
        assert_eq!(rc.target_asset.name, "USD");
        assert_eq!(rc.ts, "2024-01-01T00:00:00");
        assert_eq!(rc.open, 42000.0);
        assert_eq!(rc.high, 42500.0);
        assert_eq!(rc.low, 41500.0);
        assert_eq!(rc.close, 42200.0);
        assert_eq!(rc.volume, 100.0);
    }
}
