//! vocab/keltner — Keltner Channels, Bollinger position, squeeze
//!
//! Reads pre-computed values from the Candle struct.
//! Band position is the continuous scalar. Squeeze is the regime marker.

use crate::candle::Candle;
use super::Fact;

pub fn eval_keltner(candles: &[Candle]) -> Vec<Fact<'static>> {
    let mut facts: Vec<Fact<'static>> = Vec::new();
    let now = match candles.last() {
        Some(c) if c.kelt_upper > 0.0 && c.kelt_lower > 0.0 => c,
        _ => return facts,
    };

    // Close vs Keltner bands
    if now.close > now.kelt_upper {
        facts.push(Fact::Comparison { predicate: "above", a: "close", b: "keltner-upper" });
    } else if now.close < now.kelt_lower {
        facts.push(Fact::Comparison { predicate: "below", a: "close", b: "keltner-lower" });
    }

    // Keltner position: where is price within the channel? [0,1]
    facts.push(Fact::Scalar { indicator: "kelt-pos", value: now.kelt_pos.clamp(0.0, 1.0), scale: 1.0 });

    // Bollinger position: where is price within the bands? [0,1]
    // 0.0 = lower band. 1.0 = upper band. Can exceed when price breaks out.
    facts.push(Fact::Scalar { indicator: "bb-pos", value: now.bb_pos.clamp(0.0, 1.0), scale: 1.0 });

    // Squeeze: BB inside Keltner = low volatility compression
    if now.squeeze {
        facts.push(Fact::Zone { indicator: "volatility", zone: "squeeze" });
    }

    facts
}
