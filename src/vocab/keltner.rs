//! vocab/keltner — Keltner Channels + Squeeze detection
//!
//! SMA20 ± 2×ATR channels. Squeeze = BB inside Keltner (low volatility).
//! Pure computation, no encoding.

use crate::candle::Candle;
use super::Fact;

pub fn eval_keltner(candles: &[Candle]) -> Option<Vec<Fact<'static>>> {
    let now = candles.last()?;
    if now.sma20 <= 0.0 || now.atr_r <= 0.0 { return None; }

    let atr_abs = now.atr_r * now.close;
    let upper = now.sma20 + 2.0 * atr_abs;
    let lower = now.sma20 - 2.0 * atr_abs;
    let close = now.close;

    let mut facts: Vec<Fact<'static>> = Vec::new();

    // Close vs upper
    if close > upper {
        facts.push(Fact::Comparison { predicate: "above", a: "close", b: "keltner-upper" });
    } else {
        facts.push(Fact::Comparison { predicate: "below", a: "close", b: "keltner-upper" });
    }

    // Close vs lower
    if close > lower {
        facts.push(Fact::Comparison { predicate: "above", a: "close", b: "keltner-lower" });
    } else {
        facts.push(Fact::Comparison { predicate: "below", a: "close", b: "keltner-lower" });
    }

    // Squeeze: BB inside Keltner (low volatility)
    if now.bb_upper > 0.0 && now.bb_upper < upper && now.bb_lower > lower {
        facts.push(Fact::Comparison { predicate: "below", a: "bb-upper", b: "keltner-upper" });
    }

    Some(facts)
}
