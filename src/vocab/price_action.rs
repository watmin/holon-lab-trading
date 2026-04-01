//! vocab/price_action — candlestick patterns and price structure
//!
//! Inside/outside bars, gaps, consecutive same-direction candles.
//! Pure computation, no encoding.

use crate::candle::Candle;
use super::Fact;

/// Count consecutive green candles (close > open) from the most recent candle backwards.
fn consecutive_up(candles: &[Candle]) -> usize {
    let mut count = 0;
    for c in candles.iter().rev() {
        if c.close > c.open { count += 1; } else { break; }
    }
    count
}

/// Count consecutive red candles (close < open) from the most recent candle backwards.
fn consecutive_down(candles: &[Candle]) -> usize {
    let mut count = 0;
    for c in candles.iter().rev() {
        if c.close < c.open { count += 1; } else { break; }
    }
    count
}

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
    let up_count = consecutive_up(candles);
    let down_count = consecutive_down(candles);
    if up_count >= 3 {
        facts.push(Fact::Zone { indicator: "close", zone: "consecutive-up" });
    }
    if down_count >= 3 {
        facts.push(Fact::Zone { indicator: "close", zone: "consecutive-down" });
    }

    facts
}
