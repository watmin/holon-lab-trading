//! vocab/price_action — candlestick patterns and price structure
//!
//! Inside/outside bars, gaps, consecutive same-direction candles.
//! Pure computation, no encoding.

use crate::candle::Candle;

pub struct PriceActionFacts {
    pub patterns: Vec<&'static str>,
    pub consecutive_up: Option<usize>,
    pub consecutive_down: Option<usize>,
}

pub fn eval_price_action(candles: &[Candle]) -> PriceActionFacts {
    let n = candles.len();
    let mut facts = PriceActionFacts {
        patterns: Vec::new(),
        consecutive_up: None,
        consecutive_down: None,
    };
    if n < 3 { return facts; }

    let now = &candles[n - 1];
    let prev = &candles[n - 2];

    // Inside bar: current range within previous range
    if now.high <= prev.high && now.low >= prev.low {
        facts.patterns.push("inside-bar");
    }
    // Outside bar: current range engulfs previous
    if now.high > prev.high && now.low < prev.low {
        facts.patterns.push("outside-bar");
    }
    // Gap up/down
    let gap = (now.open - prev.close) / prev.close;
    if gap > 0.001 {
        facts.patterns.push("gap-up");
    } else if gap < -0.001 {
        facts.patterns.push("gap-down");
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
        facts.consecutive_up = Some(up_count);
    }
    if down_count >= 3 {
        facts.consecutive_down = Some(down_count);
    }

    facts
}
