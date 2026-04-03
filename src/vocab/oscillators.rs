//! vocab/oscillators — momentum indicators
//!
//! Reads pre-computed values from the Candle struct where available.
//! Only computes window-dependent indicators (Ultimate Oscillator) from raw candles.

use crate::candle::Candle;
use super::Fact;

/// Ultimate Oscillator: weighted average of three timeframes.
/// Window-dependent — must be computed from raw candles, not pre-baked.
fn ultimate_oscillator(candles: &[Candle], p1: usize, p2: usize, p3: usize) -> Option<f64> {
    if candles.len() < p3 + 1 { return None; }
    let mut bp_sum = [0.0_f64; 3];
    let mut tr_sum = [0.0_f64; 3];
    let periods = [p1, p2, p3];

    for i in 1..candles.len() {
        let prev_close = candles[i - 1].close;
        let low = candles[i].low;
        let high = candles[i].high;
        let close = candles[i].close;

        let bp = close - low.min(prev_close);
        let tr = high.max(prev_close) - low.min(prev_close);

        let offset = candles.len() - i;
        for (pi, &period) in periods.iter().enumerate() {
            if offset < period {
                bp_sum[pi] += bp;
                tr_sum[pi] += tr;
            }
        }
    }

    let avg = |bp: f64, tr: f64| -> f64 {
        if tr.abs() < 1e-10 { 50.0 } else { bp / tr }
    };

    Some(100.0 * (4.0 * avg(bp_sum[0], tr_sum[0])
                + 2.0 * avg(bp_sum[1], tr_sum[1])
                + avg(bp_sum[2], tr_sum[2])) / 7.0)
}

/// Evaluate oscillator facts. Reads pre-computed values from the candle.
pub fn eval_oscillators(candles: &[Candle]) -> Vec<Fact<'static>> {
    let mut facts: Vec<Fact<'static>> = Vec::new();
    let now = match candles.last() {
        Some(c) => c,
        None => return facts,
    };

    // Williams %R — pre-computed on Candle
    let wr = now.williams_r;
    if wr > -20.0 {
        facts.push(Fact::Zone { indicator: "williams-r", zone: "williams-overbought" });
    } else if wr < -80.0 {
        facts.push(Fact::Zone { indicator: "williams-r", zone: "williams-oversold" });
    }
    facts.push(Fact::Scalar { indicator: "williams-r", value: (wr + 100.0) / 100.0, scale: 1.0 });

    // Stochastic RSI — pre-computed stoch_k on Candle, emitted as "stoch-rsi"
    // Note: this is stoch_%K used as an RSI-like oscillator, not the stochastic
    // from stochastic.wat (which emits "stoch-k" / "stoch-d" with cross-detection).
    let sk = now.stoch_k;
    if sk > 80.0 {
        facts.push(Fact::Zone { indicator: "stoch-rsi", zone: "stoch-rsi-overbought" });
    } else if sk < 20.0 {
        facts.push(Fact::Zone { indicator: "stoch-rsi", zone: "stoch-rsi-oversold" });
    }
    facts.push(Fact::Scalar { indicator: "stoch-rsi", value: sk / 100.0, scale: 1.0 });

    // Ultimate Oscillator — window-dependent, computed from raw candles
    if let Some(uo) = ultimate_oscillator(candles, 7, 14, 28) {
        if uo > 70.0 {
            facts.push(Fact::Zone { indicator: "ult-osc", zone: "ult-osc-overbought" });
        } else if uo < 30.0 {
            facts.push(Fact::Zone { indicator: "ult-osc", zone: "ult-osc-oversold" });
        }
    }

    // Multi-timeframe ROC — normalized per-candle rate.
    // roc_N / N = average per-candle rate over N periods.
    // Acceleration: short-term rate exceeds long-term rate (move getting faster).
    // Deceleration: short-term rate below long-term rate (move exhausting).
    // Majority vote across 3 comparisons — tolerates noise in one pair.
    let r1 = now.roc_1;           // already per-candle
    let r3 = now.roc_3 / 3.0;
    let r6 = now.roc_6 / 6.0;
    let r12 = now.roc_12 / 12.0;
    let accel_votes = (r1 > r3) as u8 + (r3 > r6) as u8 + (r6 > r12) as u8;
    let decel_votes = (r1 < r3) as u8 + (r3 < r6) as u8 + (r6 < r12) as u8;

    if accel_votes >= 2 {
        facts.push(Fact::Bare { label: "roc-accelerating" });
    }
    if decel_votes >= 2 {
        facts.push(Fact::Bare { label: "roc-decelerating" });
    }

    facts
}
