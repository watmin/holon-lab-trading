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
