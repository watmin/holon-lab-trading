//! vocab/ichimoku — Ichimoku Cloud system
//!
//! Computes Tenkan-sen, Kijun-sen, Senkou Spans, cloud boundaries,
//! cloud zone, and TK cross detection. Pure computation, no encoding.

use crate::candle::Candle;
use super::Fact;

/// (highest high + lowest low) / 2 over a window of candles.
fn midpoint(candles: &[Candle]) -> f64 {
    let hi = candles.iter().map(|c| c.high).fold(f64::NEG_INFINITY, f64::max);
    let lo = candles.iter().map(|c| c.low).fold(f64::INFINITY, f64::min);
    (hi + lo) / 2.0
}

pub fn eval_ichimoku(candles: &[Candle]) -> Option<Vec<Fact<'static>>> {
    let n = candles.len();
    if n < 26 { return None; }

    let now = candles.last().unwrap();
    let close = now.close;

    // Tenkan-sen: midpoint over 9 periods
    let tenkan = midpoint(&candles[n.saturating_sub(9)..]);

    // Kijun-sen: midpoint over 26 periods
    let kijun = midpoint(&candles[n.saturating_sub(26)..]);

    // Senkou Span A: (tenkan + kijun) / 2
    let span_a = (tenkan + kijun) / 2.0;

    // Senkou Span B: midpoint over 52 periods (use available)
    let span_b = midpoint(candles);

    let cloud_top = span_a.max(span_b);
    let cloud_bottom = span_a.min(span_b);

    let mut facts: Vec<Fact<'static>> = Vec::new();

    // Comparison pairs: close vs ichimoku levels
    let pairs: &[(&str, &str, f64, f64)] = &[
        ("close", "tenkan-sen", close, tenkan),
        ("close", "kijun-sen", close, kijun),
        ("close", "cloud-top", close, cloud_top),
        ("close", "cloud-bottom", close, cloud_bottom),
        ("tenkan-sen", "kijun-sen", tenkan, kijun),
        ("close", "senkou-span-a", close, span_a),
        ("close", "senkou-span-b", close, span_b),
    ];
    for &(a_name, b_name, a_val, b_val) in pairs {
        let pred = if a_val > b_val { "above" } else { "below" };
        facts.push(Fact::Comparison { predicate: pred, a: a_name, b: b_name });
    }

    // Cloud zone
    let cloud_zone = if close > cloud_top { "above-cloud" }
                     else if close < cloud_bottom { "below-cloud" }
                     else { "in-cloud" };
    facts.push(Fact::Zone { indicator: "close", zone: cloud_zone });

    // Tenkan-kijun cross (check prev candle)
    // Previous tenkan/kijun: same period windows, shifted back one candle.
    // prev_candles = candles[0..n-1] — everything except the current candle.
    if n >= 27 {
        let prev = &candles[..n-1];
        let pn = prev.len();
        let prev_tenkan = midpoint(&prev[pn.saturating_sub(9)..]);
        let prev_kijun = midpoint(&prev[pn.saturating_sub(26)..]);
        if prev_tenkan < prev_kijun && tenkan >= kijun {
            facts.push(Fact::Comparison { predicate: "crosses-above", a: "tenkan-sen", b: "kijun-sen" });
        } else if prev_tenkan > prev_kijun && tenkan <= kijun {
            facts.push(Fact::Comparison { predicate: "crosses-below", a: "tenkan-sen", b: "kijun-sen" });
        }
    }

    Some(facts)
}
