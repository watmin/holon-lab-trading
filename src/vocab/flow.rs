//! mod/flow — volume flow indicators
//!
//! Implements: OBV direction, VWAP distance, Money Flow Index, buying/selling pressure
//! Spec: wat/mod/flow.wat (in ~/work/holon/wat/)
//!
//! Volume tells you WHO is behind the move. Flow tells you WHETHER
//! the move has backing.

use crate::candle::Candle;
use super::Fact;

/// On-Balance Volume direction: is OBV trending with or against price?
/// Returns (obv_slope_sign, obv_diverges_from_price)
pub fn obv_analysis(candles: &[Candle]) -> (f64, bool) {
    if candles.len() < 10 { return (0.0, false); }

    // Compute OBV series
    let mut obv = 0.0_f64;
    let mut obv_series: Vec<f64> = Vec::with_capacity(candles.len());
    obv_series.push(0.0);
    for i in 1..candles.len() {
        if candles[i].close > candles[i-1].close {
            obv += candles[i].volume;
        } else if candles[i].close < candles[i-1].close {
            obv -= candles[i].volume;
        }
        obv_series.push(obv);
    }

    // OBV slope over last 10 candles (simple: last - first)
    let n = obv_series.len();
    let obv_slope = obv_series[n-1] - obv_series[n.saturating_sub(10)];
    let obv_sign = if obv_slope > 0.0 { 1.0 } else if obv_slope < 0.0 { -1.0 } else { 0.0 };

    // Price slope over same period
    let price_slope = candles[n-1].close - candles[n.saturating_sub(10)].close;
    let price_sign = if price_slope > 0.0 { 1.0 } else if price_slope < 0.0 { -1.0 } else { 0.0 };

    // Divergence: OBV and price moving in opposite directions
    let diverges = obv_sign != 0.0 && price_sign != 0.0 && obv_sign != price_sign;

    (obv_sign, diverges)
}

/// VWAP distance: how far is price from volume-weighted average?
/// Returns distance as fraction of price (positive = above VWAP)
pub fn vwap_distance(candles: &[Candle]) -> Option<f64> {
    if candles.is_empty() { return None; }

    let mut cum_vol_price = 0.0_f64;
    let mut cum_vol = 0.0_f64;
    for c in candles {
        let typical = (c.high + c.low + c.close) / 3.0;
        cum_vol_price += typical * c.volume;
        cum_vol += c.volume;
    }
    if cum_vol < 1e-10 { return None; }

    let vwap = cum_vol_price / cum_vol;
    let current = candles.last()?.close;
    Some((current - vwap) / current)
}

/// Money Flow Index: RSI but weighted by volume.
/// Range: [0, 100]. > 80 = overbought. < 20 = oversold.
pub fn money_flow_index(candles: &[Candle], period: usize) -> Option<f64> {
    if candles.len() < period + 1 { return None; }

    let window = &candles[candles.len() - period - 1..];
    let mut pos_flow = 0.0_f64;
    let mut neg_flow = 0.0_f64;

    for i in 1..window.len() {
        let typical = (window[i].high + window[i].low + window[i].close) / 3.0;
        let prev_typical = (window[i-1].high + window[i-1].low + window[i-1].close) / 3.0;
        let raw_flow = typical * window[i].volume;

        if typical > prev_typical {
            pos_flow += raw_flow;
        } else {
            neg_flow += raw_flow;
        }
    }

    if neg_flow < 1e-10 { return Some(100.0); }
    let ratio = pos_flow / neg_flow;
    Some(100.0 - 100.0 / (1.0 + ratio))
}

/// Buying/selling pressure from wick analysis.
/// Returns (buy_pressure, sell_pressure, body_ratio) all in [0, 1]
pub fn pressure_analysis(candle: &Candle) -> (f64, f64, f64) {
    let range = candle.high - candle.low;
    if range < 1e-10 { return (0.5, 0.5, 0.5); }

    let body_top = candle.close.max(candle.open);
    let body_bottom = candle.close.min(candle.open);
    let body = body_top - body_bottom;

    let upper_wick = candle.high - body_top;
    let lower_wick = body_bottom - candle.low;

    let sell_pressure = upper_wick / range;  // selling pushed price down from high
    let buy_pressure = lower_wick / range;   // buying pushed price up from low
    let body_ratio = body / range;           // conviction of the move

    (buy_pressure, sell_pressure, body_ratio)
}

/// OBV analysis results that need special encoding (bind patterns
/// that don't fit the Fact interface).
pub struct ObvFacts {
    pub obv_sign: f64,
    pub obv_diverges: bool,
}

/// All flow facts for a candle window.
/// OBV direction/divergence returned separately because they use
/// direct bind patterns that don't map to Fact variants.
pub fn eval_flow(candles: &[Candle]) -> (ObvFacts, Vec<Fact<'static>>) {
    let mut facts: Vec<Fact<'static>> = Vec::new();

    let (obv_sign, obv_diverges) = obv_analysis(candles);

    // VWAP distance
    if let Some(dist) = vwap_distance(candles) {
        facts.push(Fact::Scalar { indicator: "vwap", value: dist.clamp(-1.0, 1.0) * 0.5 + 0.5, scale: 1.0 });
    }

    // MFI zone
    let mfi = money_flow_index(candles, 14);
    if let Some(v) = mfi {
        if v > 80.0 {
            facts.push(Fact::Zone { indicator: "mfi", zone: "mfi-overbought" });
        } else if v < 20.0 {
            facts.push(Fact::Zone { indicator: "mfi", zone: "mfi-oversold" });
        }
    }

    // Buying/selling pressure + body ratio
    let now = candles.last().unwrap();
    let (bp, sp, br) = pressure_analysis(now);
    facts.push(Fact::Scalar { indicator: "buy-pressure", value: bp, scale: 1.0 });
    facts.push(Fact::Scalar { indicator: "sell-pressure", value: sp, scale: 1.0 });
    facts.push(Fact::Scalar { indicator: "body-ratio", value: br, scale: 1.0 });

    (ObvFacts { obv_sign, obv_diverges }, facts)
}
