//! vocab/flow — volume flow indicators
//!
//! Reads pre-computed MFI and OBV slope from the Candle struct.
//! VWAP and pressure are window/candle-dependent — computed from raw candles.

use crate::candle::Candle;
use super::Fact;

/// VWAP distance: how far is price from volume-weighted average?
/// Window-dependent — must be computed from raw candles.
fn vwap_distance(candles: &[Candle]) -> Option<f64> {
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

/// OBV analysis results that need special encoding (bind patterns
/// that don't fit the Fact interface).
pub struct ObvFacts {
    pub obv_sign: f64,
    pub obv_diverges: bool,
}

/// OBV direction from pre-computed slope. Divergence from price direction.
fn obv_analysis(now: &Candle, candles: &[Candle]) -> ObvFacts {
    let obv_sign = if now.obv_slope_12 > 0.0 { 1.0 }
        else if now.obv_slope_12 < 0.0 { -1.0 }
        else { 0.0 };

    // Price direction over ~12 candles for divergence check
    let n = candles.len();
    let price_slope = if n >= 12 {
        now.close - candles[n - 12].close
    } else if n >= 2 {
        now.close - candles[0].close
    } else { 0.0 };
    let price_sign = if price_slope > 0.0 { 1.0 }
        else if price_slope < 0.0 { -1.0 }
        else { 0.0 };

    let diverges = obv_sign != 0.0 && price_sign != 0.0 && obv_sign != price_sign;
    ObvFacts { obv_sign, obv_diverges: diverges }
}

/// All flow facts for a candle window.
pub fn eval_flow(candles: &[Candle]) -> (ObvFacts, Vec<Fact<'static>>) {
    let mut facts: Vec<Fact<'static>> = Vec::new();
    let now = match candles.last() {
        Some(c) => c,
        None => return (ObvFacts { obv_sign: 0.0, obv_diverges: false }, facts),
    };

    let obv = obv_analysis(now, candles);

    // VWAP distance — window-dependent, computed from raw candles
    if let Some(dist) = vwap_distance(candles) {
        facts.push(Fact::Scalar { indicator: "vwap", value: dist.clamp(-1.0, 1.0) * 0.5 + 0.5, scale: 1.0 });
    }

    // MFI — pre-computed on Candle
    if now.mfi > 80.0 {
        facts.push(Fact::Zone { indicator: "mfi", zone: "mfi-overbought" });
    } else if now.mfi < 20.0 {
        facts.push(Fact::Zone { indicator: "mfi", zone: "mfi-oversold" });
    }

    // Buying/selling pressure from wicks — per-candle, computed from raw
    let range = now.high - now.low;
    if range > 1e-10 {
        let body_top = now.close.max(now.open);
        let body_bottom = now.close.min(now.open);
        let body = body_top - body_bottom;
        let bp = (body_bottom - now.low) / range;
        let sp = (now.high - body_top) / range;
        let br = body / range;
        facts.push(Fact::Scalar { indicator: "buy-pressure", value: bp, scale: 1.0 });
        facts.push(Fact::Scalar { indicator: "sell-pressure", value: sp, scale: 1.0 });
        facts.push(Fact::Scalar { indicator: "body-ratio", value: br, scale: 1.0 });
    }

    // Volume acceleration — pre-computed on Candle
    if now.vol_accel > 2.0 {
        facts.push(Fact::Zone { indicator: "volume", zone: "volume-spike" });
    } else if now.vol_accel < 0.3 {
        facts.push(Fact::Zone { indicator: "volume", zone: "volume-drought" });
    }

    (obv, facts)
}
