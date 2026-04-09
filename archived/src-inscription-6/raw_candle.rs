//! raw-candle.wat -- Asset and RawCandle
//! Depends on: nothing

/// A named token. The identity of a currency or commodity.
#[derive(Clone, Debug, PartialEq)]
pub struct Asset {
    pub name: String,
}

impl Asset {
    pub fn new(name: String) -> Self {
        Self { name }
    }
}

/// The enterprise's only input. Eight fields. From the parquet,
/// from the websocket. The asset pair IS the routing key.
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
        ts: String,
        open: f64,
        high: f64,
        low: f64,
        close: f64,
        volume: f64,
    ) -> Self {
        Self {
            source_asset,
            target_asset,
            ts,
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
    fn test_asset_construct() {
        let a = Asset::new("BTC".to_string());
        assert_eq!(a.name, "BTC");
    }

    #[test]
    fn test_asset_clone_eq() {
        let a = Asset::new("ETH".to_string());
        let b = a.clone();
        assert_eq!(a, b);
    }

    #[test]
    fn test_raw_candle_construct_all_fields() {
        let src = Asset::new("BTC".to_string());
        let tgt = Asset::new("USDT".to_string());
        let rc = RawCandle::new(
            src.clone(),
            tgt.clone(),
            "2025-01-01T00:00:00Z".to_string(),
            100.0,
            110.0,
            90.0,
            105.0,
            1000.0,
        );
        assert_eq!(rc.source_asset, src);
        assert_eq!(rc.target_asset, tgt);
        assert_eq!(rc.ts, "2025-01-01T00:00:00Z");
        assert_eq!(rc.open, 100.0);
        assert_eq!(rc.high, 110.0);
        assert_eq!(rc.low, 90.0);
        assert_eq!(rc.close, 105.0);
        assert_eq!(rc.volume, 1000.0);
    }
}
