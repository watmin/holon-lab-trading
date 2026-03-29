//! vocab/stochastic — Stochastic Oscillator (%K, %D)
//!
//! Reads pre-computed stoch_k, stoch_d from the Candle struct.
//! Crossover detection uses current + previous candle. Pure computation, no encoding.

use crate::candle::Candle;
use super::Fact;

pub fn eval_stochastic(candles: &[Candle]) -> Option<Vec<Fact<'static>>> {
    let n = candles.len();
    if n < 2 { return None; }

    let now = candles.last()?;
    let stoch_k = now.stoch_k;
    let stoch_d = now.stoch_d;

    let mut facts: Vec<Fact<'static>> = Vec::new();

    // K vs D comparison
    if stoch_k > stoch_d {
        facts.push(Fact::Comparison { predicate: "above", a: "stoch-k", b: "stoch-d" });
    } else {
        facts.push(Fact::Comparison { predicate: "below", a: "stoch-k", b: "stoch-d" });
    }

    // Cross detection using previous candle's pre-computed values
    let prev = &candles[n - 2];
    let prev_k = prev.stoch_k;
    let prev_d = prev.stoch_d;
    if prev_k < prev_d && stoch_k >= stoch_d {
        facts.push(Fact::Comparison { predicate: "crosses-above", a: "stoch-k", b: "stoch-d" });
    } else if prev_k > prev_d && stoch_k <= stoch_d {
        facts.push(Fact::Comparison { predicate: "crosses-below", a: "stoch-k", b: "stoch-d" });
    }

    // Zone
    if stoch_k > 80.0 {
        facts.push(Fact::Zone { indicator: "stoch-k", zone: "stoch-overbought" });
    } else if stoch_k < 20.0 {
        facts.push(Fact::Zone { indicator: "stoch-k", zone: "stoch-oversold" });
    }

    Some(facts)
}
