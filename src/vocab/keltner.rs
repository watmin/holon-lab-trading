//! vocab/keltner — Keltner Channels + Squeeze detection
//!
//! Reads pre-computed kelt_upper, kelt_lower, kelt_pos, squeeze from the Candle struct.
//! Pure computation, no encoding.

use crate::candle::Candle;
use super::Fact;

pub fn eval_keltner(candles: &[Candle]) -> Option<Vec<Fact<'static>>> {
    let now = candles.last()?;
    if now.kelt_upper <= 0.0 || now.kelt_lower <= 0.0 { return None; }

    let close = now.close;
    let mut facts: Vec<Fact<'static>> = Vec::new();

    // Close vs upper
    if close > now.kelt_upper {
        facts.push(Fact::Comparison { predicate: "above", a: "close", b: "keltner-upper" });
    } else {
        facts.push(Fact::Comparison { predicate: "below", a: "close", b: "keltner-upper" });
    }

    // Close vs lower
    if close > now.kelt_lower {
        facts.push(Fact::Comparison { predicate: "above", a: "close", b: "keltner-lower" });
    } else {
        facts.push(Fact::Comparison { predicate: "below", a: "close", b: "keltner-lower" });
    }

    // Squeeze: BB inside Keltner (low volatility) — pre-computed boolean
    if now.squeeze {
        facts.push(Fact::Comparison { predicate: "below", a: "bb-upper", b: "keltner-upper" });
    }

    Some(facts)
}
