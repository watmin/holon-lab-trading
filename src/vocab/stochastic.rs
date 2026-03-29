//! vocab/stochastic — Stochastic Oscillator (%K, %D)
//!
//! 14-period stochastic with 3-period %D smoothing.
//! Zone detection and K/D crossover. Pure computation, no encoding.

use crate::candle::Candle;
use super::Fact;

pub fn eval_stochastic(candles: &[Candle]) -> Option<Vec<Fact<'static>>> {
    let n = candles.len();
    if n < 14 { return None; }

    let w = &candles[n.saturating_sub(14)..];
    let hh = w.iter().map(|c| c.high).fold(f64::NEG_INFINITY, f64::max);
    let ll = w.iter().map(|c| c.low).fold(f64::INFINITY, f64::min);
    let range = hh - ll;
    if range < 1e-10 { return None; }

    let stoch_k = (candles.last().unwrap().close - ll) / range * 100.0;

    // %D = 3-period SMA of %K (approximate from last 3 candles)
    let stoch_d = if n >= 16 {
        let mut sum = stoch_k;
        for offset in 1..=2 {
            let idx = n - 1 - offset;
            let w2 = &candles[idx.saturating_sub(13)..=idx];
            let h2 = w2.iter().map(|c| c.high).fold(f64::NEG_INFINITY, f64::max);
            let l2 = w2.iter().map(|c| c.low).fold(f64::INFINITY, f64::min);
            let r2 = h2 - l2;
            if r2 > 1e-10 { sum += (candles[idx].close - l2) / r2 * 100.0; }
            else { sum += 50.0; }
        }
        sum / 3.0
    } else { stoch_k };

    let mut facts: Vec<Fact<'static>> = Vec::new();

    // K vs D comparison
    if stoch_k > stoch_d {
        facts.push(Fact::Comparison { predicate: "above", a: "stoch-k", b: "stoch-d" });
    } else {
        facts.push(Fact::Comparison { predicate: "below", a: "stoch-k", b: "stoch-d" });
    }

    // Cross detection
    if n >= 16 {
        let idx = n - 2;
        let w2 = &candles[idx.saturating_sub(13)..=idx];
        let h2 = w2.iter().map(|c| c.high).fold(f64::NEG_INFINITY, f64::max);
        let l2 = w2.iter().map(|c| c.low).fold(f64::INFINITY, f64::min);
        let r2 = h2 - l2;
        let prev_k = if r2 > 1e-10 { (candles[idx].close - l2) / r2 * 100.0 } else { 50.0 };
        let prev_d = stoch_d; // rough approximation
        if prev_k < prev_d && stoch_k >= stoch_d {
            facts.push(Fact::Comparison { predicate: "crosses-above", a: "stoch-k", b: "stoch-d" });
        } else if prev_k > prev_d && stoch_k <= stoch_d {
            facts.push(Fact::Comparison { predicate: "crosses-below", a: "stoch-k", b: "stoch-d" });
        }
    }

    // Zone
    if stoch_k > 80.0 {
        facts.push(Fact::Zone { indicator: "stoch-k", zone: "stoch-overbought" });
    } else if stoch_k < 20.0 {
        facts.push(Fact::Zone { indicator: "stoch-k", zone: "stoch-oversold" });
    }

    Some(facts)
}
