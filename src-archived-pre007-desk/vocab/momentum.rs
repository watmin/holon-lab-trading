//! vocab/momentum — CCI and ROC zone detection
//!
//! Reads pre-computed CCI from the Candle struct.
//! Pure computation, no encoding.

use crate::candle::Candle;
use super::Fact;

pub fn eval_momentum(candles: &[Candle]) -> Vec<Fact<'static>> {
    let mut facts: Vec<Fact<'static>> = Vec::new();
    let now = match candles.last() {
        Some(c) => c,
        None => return facts,
    };

    // CCI — pre-computed on Candle
    let cci = now.cci;
    if cci > 100.0 {
        facts.push(Fact::Zone { indicator: "cci", zone: "cci-overbought" });
    } else if cci < -100.0 {
        facts.push(Fact::Zone { indicator: "cci", zone: "cci-oversold" });
    }

    facts
}
