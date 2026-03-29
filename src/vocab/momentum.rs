//! vocab/momentum — CCI and ROC zone detection
//!
//! CCI: Commodity Channel Index (20-period).
//! Pure computation, no encoding.

use crate::candle::Candle;

pub struct MomentumFacts {
    pub cci_zone: Option<&'static str>,
}

pub fn eval_momentum(candles: &[Candle]) -> MomentumFacts {
    let n = candles.len();
    let mut facts = MomentumFacts { cci_zone: None };
    if n < 20 { return facts; }

    let now = candles.last().unwrap();

    // CCI: (typical - SMA(typical, 20)) / (0.015 × mean_deviation)
    let typicals: Vec<f64> = candles[n.saturating_sub(20)..].iter()
        .map(|c| (c.high + c.low + c.close) / 3.0).collect();
    let typical_mean = typicals.iter().sum::<f64>() / typicals.len() as f64;
    let mean_dev = typicals.iter().map(|t| (t - typical_mean).abs()).sum::<f64>()
        / typicals.len() as f64;
    if mean_dev > 1e-10 {
        let typical_now = (now.high + now.low + now.close) / 3.0;
        let cci = (typical_now - typical_mean) / (0.015 * mean_dev);
        if cci > 100.0 {
            facts.cci_zone = Some("cci-overbought");
        } else if cci < -100.0 {
            facts.cci_zone = Some("cci-oversold");
        }
    }

    facts
}
