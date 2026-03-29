//! vocab/price_action — candlestick patterns and price structure
//!
//! Inside/outside bars, gaps, consecutive same-direction candles.
//! Pure computation, no encoding.

use crate::candle::Candle;
use super::Fact;

pub fn eval_price_action(candles: &[Candle]) -> Vec<Fact<'static>> {
    let n = candles.len();
    let mut facts: Vec<Fact<'static>> = Vec::new();
    if n < 3 { return facts; }

    let now = &candles[n - 1];
    let prev = &candles[n - 2];

    // Inside bar: current range within previous range
    if now.high <= prev.high && now.low >= prev.low {
        facts.push(Fact::Zone { indicator: "close", zone: "inside-bar" });
    }
    // Outside bar: current range engulfs previous
    if now.high > prev.high && now.low < prev.low {
        facts.push(Fact::Zone { indicator: "close", zone: "outside-bar" });
    }
    // Gap up/down
    let gap = (now.open - prev.close) / prev.close;
    if gap > 0.001 {
        facts.push(Fact::Zone { indicator: "close", zone: "gap-up" });
    } else if gap < -0.001 {
        facts.push(Fact::Zone { indicator: "close", zone: "gap-down" });
    }

    // Consecutive same-direction candles
    let mut up_count = 0usize;
    let mut down_count = 0usize;
    for i in (0..n).rev() {
        if candles[i].close > candles[i].open { up_count += 1; } else { break; }
    }
    for i in (0..n).rev() {
        if candles[i].close < candles[i].open { down_count += 1; } else { break; }
    }
    if up_count >= 3 {
        facts.push(Fact::Zone { indicator: "close", zone: "consecutive-up" });
    }
    if down_count >= 3 {
        facts.push(Fact::Zone { indicator: "close", zone: "consecutive-down" });
    }

    facts
}
