//! vocab/keltner — Keltner Channels + Squeeze detection
//!
//! SMA20 ± 2×ATR channels. Squeeze = BB inside Keltner (low volatility).
//! Pure computation, no encoding.

use crate::candle::Candle;

pub struct KeltnerFacts {
    pub upper: f64,
    pub lower: f64,
    pub close_vs_upper: &'static str,  // "above" or "below"
    pub close_vs_lower: &'static str,  // "above" or "below"
    pub squeeze: bool,
}

pub fn eval_keltner(candles: &[Candle]) -> Option<KeltnerFacts> {
    let now = candles.last()?;
    if now.sma20 <= 0.0 || now.atr_r <= 0.0 { return None; }

    let atr_abs = now.atr_r * now.close;
    let upper = now.sma20 + 2.0 * atr_abs;
    let lower = now.sma20 - 2.0 * atr_abs;
    let close = now.close;

    let close_vs_upper = if close > upper { "above" } else { "below" };
    let close_vs_lower = if close > lower { "above" } else { "below" };

    // Squeeze: BB inside Keltner (low volatility)
    let squeeze = now.bb_upper > 0.0 && now.bb_upper < upper && now.bb_lower > lower;

    Some(KeltnerFacts { upper, lower, close_vs_upper, close_vs_lower, squeeze })
}
