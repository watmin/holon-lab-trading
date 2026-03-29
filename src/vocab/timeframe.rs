//! vocab/timeframe — inter-timeframe structure and narrative
//!
//! Split by domain: structure sees geometry (range position, body ratio).
//! Narrative sees the story (direction agreement, return magnitude).
//!
//! Each expert gets the thoughts that belong to its way of thinking.

use crate::candle::Candle;
use super::Fact;

/// Structure thoughts: where is price in the multi-timeframe geometry?
pub fn eval_timeframe_structure(candles: &[Candle]) -> Vec<Fact<'static>> {
    let mut facts: Vec<Fact<'static>> = Vec::new();
    let now = match candles.last() {
        Some(c) => c,
        None => return facts,
    };

    // Body ratios — how decisive is each timeframe's candle?
    facts.push(Fact::Scalar { indicator: "tf-1h-body", value: now.tf_1h_body.clamp(0.0, 1.0), scale: 1.0 });
    facts.push(Fact::Scalar { indicator: "tf-4h-body", value: now.tf_4h_body.clamp(0.0, 1.0), scale: 1.0 });

    // Range position — where is price within the hourly/4h range?
    let h_range = now.tf_1h_high - now.tf_1h_low;
    if h_range > 1e-10 {
        let pos = (now.close - now.tf_1h_low) / h_range;
        facts.push(Fact::Scalar { indicator: "tf-1h-range-pos", value: pos.clamp(0.0, 1.0), scale: 1.0 });
    }
    let h4_range = now.tf_4h_high - now.tf_4h_low;
    if h4_range > 1e-10 {
        let pos = (now.close - now.tf_4h_low) / h4_range;
        facts.push(Fact::Scalar { indicator: "tf-4h-range-pos", value: pos.clamp(0.0, 1.0), scale: 1.0 });
    }

    facts
}

/// Narrative thoughts: what is the multi-timeframe story telling us?
pub fn eval_timeframe_narrative(candles: &[Candle]) -> Vec<Fact<'static>> {
    let mut facts: Vec<Fact<'static>> = Vec::new();
    let now = match candles.last() {
        Some(c) => c,
        None => return facts,
    };

    // 1-hour return direction and magnitude
    if now.tf_1h_ret.abs() > 1e-10 {
        let zone = if now.tf_1h_ret > 0.005 { "tf-1h-up-strong" }
            else if now.tf_1h_ret > 0.0 { "tf-1h-up-mild" }
            else if now.tf_1h_ret < -0.005 { "tf-1h-down-strong" }
            else { "tf-1h-down-mild" };
        facts.push(Fact::Zone { indicator: "tf-1h", zone });
        facts.push(Fact::Scalar { indicator: "tf-1h-ret", value: now.tf_1h_ret.clamp(-0.05, 0.05) * 10.0 + 0.5, scale: 1.0 });
    }

    // 4-hour return direction and magnitude
    if now.tf_4h_ret.abs() > 1e-10 {
        let zone = if now.tf_4h_ret > 0.01 { "tf-4h-up-strong" }
            else if now.tf_4h_ret > 0.0 { "tf-4h-up-mild" }
            else if now.tf_4h_ret < -0.01 { "tf-4h-down-strong" }
            else { "tf-4h-down-mild" };
        facts.push(Fact::Zone { indicator: "tf-4h", zone });
        facts.push(Fact::Scalar { indicator: "tf-4h-ret", value: now.tf_4h_ret.clamp(-0.05, 0.05) * 10.0 + 0.5, scale: 1.0 });
    }

    // Inter-timeframe agreement: do 5m and 1h and 4h agree on direction?
    if candles.len() >= 2 {
        let m5_dir = now.close - candles[candles.len() - 2].close;
        let agree_1h = (m5_dir > 0.0 && now.tf_1h_ret > 0.0) || (m5_dir < 0.0 && now.tf_1h_ret < 0.0);
        let agree_4h = (m5_dir > 0.0 && now.tf_4h_ret > 0.0) || (m5_dir < 0.0 && now.tf_4h_ret < 0.0);

        if agree_1h && agree_4h {
            facts.push(Fact::Bare { label: "tf-all-agree" });
        } else if !agree_1h && !agree_4h {
            facts.push(Fact::Bare { label: "tf-all-disagree" });
        } else if agree_1h {
            facts.push(Fact::Bare { label: "tf-1h-agrees" });
        } else {
            facts.push(Fact::Bare { label: "tf-4h-agrees" });
        }
    }

    facts
}
