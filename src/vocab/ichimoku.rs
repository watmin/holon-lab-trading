//! vocab/ichimoku — Ichimoku Cloud system
//!
//! Computes Tenkan-sen, Kijun-sen, Senkou Spans, cloud boundaries,
//! cloud zone, and TK cross detection. Pure computation, no encoding.

use crate::candle::Candle;

pub struct IchimokuFacts {
    pub tenkan: f64,
    pub kijun: f64,
    pub span_a: f64,
    pub span_b: f64,
    pub cloud_top: f64,
    pub cloud_bottom: f64,
    pub cloud_zone: &'static str,
    /// None if not enough data; Some("above") or Some("below") on cross
    pub tk_cross: Option<&'static str>,
}

pub fn eval_ichimoku(candles: &[Candle]) -> Option<IchimokuFacts> {
    let n = candles.len();
    if n < 26 { return None; }

    let now = candles.last().unwrap();

    // Tenkan-sen: (highest_high + lowest_low) / 2 over 9 periods
    let tenkan = {
        let w = &candles[n.saturating_sub(9)..];
        let hi = w.iter().map(|c| c.high).fold(f64::NEG_INFINITY, f64::max);
        let lo = w.iter().map(|c| c.low).fold(f64::INFINITY, f64::min);
        (hi + lo) / 2.0
    };

    // Kijun-sen: (highest_high + lowest_low) / 2 over 26 periods
    let kijun = {
        let w = &candles[n.saturating_sub(26)..];
        let hi = w.iter().map(|c| c.high).fold(f64::NEG_INFINITY, f64::max);
        let lo = w.iter().map(|c| c.low).fold(f64::INFINITY, f64::min);
        (hi + lo) / 2.0
    };

    // Senkou Span A: (tenkan + kijun) / 2
    let span_a = (tenkan + kijun) / 2.0;

    // Senkou Span B: (highest + lowest) / 2 over 52 periods (use available)
    let span_b = {
        let hi = candles.iter().map(|c| c.high).fold(f64::NEG_INFINITY, f64::max);
        let lo = candles.iter().map(|c| c.low).fold(f64::INFINITY, f64::min);
        (hi + lo) / 2.0
    };

    let cloud_top = span_a.max(span_b);
    let cloud_bottom = span_a.min(span_b);
    let close = now.close;

    let cloud_zone = if close > cloud_top { "above-cloud" }
                     else if close < cloud_bottom { "below-cloud" }
                     else { "in-cloud" };

    // Tenkan-kijun cross (check prev candle)
    let tk_cross = if n >= 27 {
        let prev_tenkan = {
            let w = &candles[n.saturating_sub(10)..n-1];
            let hi = w.iter().map(|c| c.high).fold(f64::NEG_INFINITY, f64::max);
            let lo = w.iter().map(|c| c.low).fold(f64::INFINITY, f64::min);
            (hi + lo) / 2.0
        };
        let prev_kijun = {
            let w = &candles[n.saturating_sub(27)..n-1];
            let hi = w.iter().map(|c| c.high).fold(f64::NEG_INFINITY, f64::max);
            let lo = w.iter().map(|c| c.low).fold(f64::INFINITY, f64::min);
            (hi + lo) / 2.0
        };
        if prev_tenkan < prev_kijun && tenkan >= kijun {
            Some("above")
        } else if prev_tenkan > prev_kijun && tenkan <= kijun {
            Some("below")
        } else {
            None
        }
    } else {
        None
    };

    Some(IchimokuFacts {
        tenkan, kijun, span_a, span_b,
        cloud_top, cloud_bottom, cloud_zone, tk_cross,
    })
}
