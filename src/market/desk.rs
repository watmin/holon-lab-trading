//! Desk — a trading pair's expert panel.
//!
//! A desk trades one pair (asset_a / asset_b). It consumes two candle
//! streams and produces recommendations for the treasury.
//!
//! Two phases per tick:
//!   observe — always. Journals learn from partial data. The desk warms
//!            even before both streams align.
//!   act     — only when both sides are fresh. The desk recommends to
//!            the treasury only when it has a complete picture.
//!
//! The desk is a value. It has a tick method. The caller decides when
//! to call it. The desk doesn't know about the fold or the stream.

use crate::candle::Candle;

/// Configuration for creating a desk.
pub struct DeskConfig {
    /// Human-readable name (e.g., "btc-usdc", "btc-sol")
    pub name: String,
    /// First asset in the pair
    pub asset_a: String,
    /// Second asset in the pair
    pub asset_b: String,
    /// Maximum candles of staleness before a side is considered stale.
    /// Set to usize::MAX for stablecoins (never stale).
    pub staleness_a: usize,
    pub staleness_b: usize,
}

/// The freshness state of one side of the pair.
#[derive(Clone, Debug)]
struct SideState {
    /// The most recent candle for this asset.
    latest: Option<Candle>,
    /// How many candle events have passed since this side last updated.
    /// Reset to 0 when a candle arrives. Incremented when the OTHER side gets a candle.
    age: usize,
    /// Maximum age before considered stale.
    staleness_limit: usize,
}

impl SideState {
    fn new(staleness_limit: usize) -> Self {
        Self { latest: None, age: 0, staleness_limit }
    }

    fn is_fresh(&self) -> bool {
        // Stablecoin/base asset: staleness_limit = MAX means always fresh (no candle needed)
        if self.staleness_limit == usize::MAX { return true; }
        self.latest.is_some() && self.age <= self.staleness_limit
    }

    fn update(&mut self, candle: Candle) {
        self.latest = Some(candle);
        self.age = 0;
    }

    fn tick_age(&mut self) {
        self.age += 1;
    }
}

/// A desk's recommendation to the treasury.
#[derive(Clone, Debug)]
pub struct Recommendation {
    /// Which desk produced this.
    pub desk_name: String,
    /// The pair this desk trades.
    pub asset_a: String,
    pub asset_b: String,
    /// Direction: positive conviction = long asset_a vs asset_b.
    /// Negative = short.
    pub conviction: f64,
    /// The manager's raw cosine.
    pub raw_cos: f64,
    /// Whether the desk's manager has proven its edge.
    pub proven: bool,
}

/// A desk — one pair's expert panel.
///
/// Contains observers, generalist, manager, risk — the full enterprise
/// tree for one trading pair. The desk is a value with observe/act methods.
pub struct Desk {
    pub name: String,
    pub asset_a: String,
    pub asset_b: String,
    side_a: SideState,
    side_b: SideState,
    // TODO: observers, generalist, manager, risk will move here
    // from enterprise.rs as the streaming refactor progresses.
    // For now, the desk tracks freshness only.
}

impl Desk {
    /// Create a desk from configuration.
    pub fn new(config: DeskConfig) -> Self {
        Self {
            name: config.name,
            asset_a: config.asset_a.clone(),
            asset_b: config.asset_b.clone(),
            side_a: SideState::new(config.staleness_a),
            side_b: SideState::new(config.staleness_b),
        }
    }

    /// Feed a candle to the appropriate side. Returns true if this desk
    /// cares about the asset (it belongs to one of the two sides).
    pub fn observe_candle(&mut self, asset: &str, candle: Candle) -> bool {
        if asset == self.asset_a {
            self.side_a.update(candle);
            self.side_b.tick_age(); // the other side ages
            true
        } else if asset == self.asset_b {
            self.side_b.update(candle);
            self.side_a.tick_age();
            true
        } else {
            false
        }
    }

    /// Can this desk act? Both sides must have fresh data.
    pub fn can_act(&self) -> bool {
        self.side_a.is_fresh() && self.side_b.is_fresh()
    }

    /// The latest candle for side A (if any).
    pub fn candle_a(&self) -> Option<&Candle> {
        self.side_a.latest.as_ref()
    }

    /// The latest candle for side B (if any).
    pub fn candle_b(&self) -> Option<&Candle> {
        self.side_b.latest.as_ref()
    }

    /// The cross rate: price of asset_a in terms of asset_b.
    /// For BTC/USDC where candles are BTC-priced-in-USDC: just candle_a.close.
    /// For BTC/SOL: candle_a.close / candle_b.close (both priced in base).
    pub fn cross_rate(&self) -> Option<f64> {
        match (self.candle_a(), self.candle_b()) {
            (Some(a), Some(b)) => {
                if b.close > 1e-10 {
                    Some(a.close / b.close)
                } else {
                    None
                }
            }
            (Some(a), None) => Some(a.close), // base-pair: asset_b is the base (price = 1.0)
            _ => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_candle(ts: &str, close: f64) -> Candle {
        Candle {
            ts: ts.to_string(), year: 2019,
            open: close, high: close, low: close, close, volume: 1.0,
            sma20: 0.0, sma50: 0.0, sma200: 0.0,
            bb_upper: 0.0, bb_lower: 0.0, bb_width: 0.0,
            rsi: 50.0,
            macd_line: 0.0, macd_signal: 0.0, macd_hist: 0.0,
            dmi_plus: 0.0, dmi_minus: 0.0, adx: 0.0,
            atr: 0.0, atr_r: 0.0,
            stoch_k: 50.0, stoch_d: 50.0, williams_r: -50.0,
            cci: 0.0, mfi: 50.0,
            roc_1: 0.0, roc_3: 0.0, roc_6: 0.0, roc_12: 0.0,
            obv_slope_12: 0.0, volume_sma_20: 1.0,
            tf_1h_close: close, tf_1h_high: close, tf_1h_low: close,
            tf_1h_ret: 0.0, tf_1h_body: 0.0,
            tf_4h_close: close, tf_4h_high: close, tf_4h_low: close,
            tf_4h_ret: 0.0, tf_4h_body: 0.0,
            bb_pos: 0.5, kelt_upper: 0.0, kelt_lower: 0.0, kelt_pos: 0.5,
            squeeze: false,
            range_pos_12: 0.5, range_pos_24: 0.5, range_pos_48: 0.5,
            trend_consistency_6: 0.5, trend_consistency_12: 0.5, trend_consistency_24: 0.5,
            atr_roc_6: 0.0, atr_roc_12: 0.0,
            vol_accel: 1.0,
            hour: 12.0, day_of_week: 3.0,
            label: "Noise".to_string(),
        }
    }

    #[test]
    fn test_single_pair_freshness() {
        let mut desk = Desk::new(DeskConfig {
            name: "btc-usdc".into(),
            asset_a: "BTC".into(),
            asset_b: "USDC".into(),
            staleness_a: 2,
            staleness_b: usize::MAX, // stablecoin never stale
        });

        assert!(!desk.can_act()); // no data yet

        desk.observe_candle("BTC", make_candle("2019-01-01 00:00:00", 3700.0));
        assert!(desk.can_act()); // BTC fresh, USDC never stale (no candle needed)

        // Wait — USDC side has no candle but staleness is MAX, so it's... not fresh (latest is None)
        // For the base pair case, we need to handle "stablecoin side never needs a candle"
    }

    #[test]
    fn test_cross_pair_freshness() {
        let mut desk = Desk::new(DeskConfig {
            name: "btc-sol".into(),
            asset_a: "BTC".into(),
            asset_b: "SOL".into(),
            staleness_a: 2,
            staleness_b: 2,
        });

        assert!(!desk.can_act());

        desk.observe_candle("BTC", make_candle("2019-01-01 00:00:00", 3700.0));
        assert!(!desk.can_act()); // only BTC, no SOL

        desk.observe_candle("SOL", make_candle("2019-01-01 00:00:00", 10.0));
        assert!(desk.can_act()); // both fresh

        assert!((desk.cross_rate().unwrap() - 370.0).abs() < 0.01); // 3700/10
    }

    #[test]
    fn test_staleness() {
        let mut desk = Desk::new(DeskConfig {
            name: "btc-sol".into(),
            asset_a: "BTC".into(),
            asset_b: "SOL".into(),
            staleness_a: 1,
            staleness_b: 1,
        });

        desk.observe_candle("BTC", make_candle("T1", 3700.0));
        desk.observe_candle("SOL", make_candle("T1", 10.0));
        assert!(desk.can_act());

        // Two more BTC candles without SOL — SOL goes stale
        desk.observe_candle("BTC", make_candle("T2", 3800.0));
        assert!(desk.can_act()); // SOL age=1, limit=1, still ok

        desk.observe_candle("BTC", make_candle("T3", 3900.0));
        assert!(!desk.can_act()); // SOL age=2 > limit=1, stale
    }
}
