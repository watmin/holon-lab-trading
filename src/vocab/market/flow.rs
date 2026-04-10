// vocab/market/flow.rs — compiled from wat/vocab/market/flow.wat
//
// Volume and pressure. Pure function: candle in, ASTs out.
// atoms: obv-slope, vwap-distance, buying-pressure, selling-pressure,
//        volume-ratio, body-ratio

use crate::candle::Candle;
use crate::thought_encoder::{ThoughtAST, round_to};

pub fn encode_flow_facts(c: &Candle) -> Vec<ThoughtAST> {
    let range = c.high - c.low;
    let body = c.close - c.open;
    let abs_body = body.abs();

    vec![
        // OBV slope: unbounded rate of change. Log-encoded.
        ThoughtAST::Log {
            name: "obv-slope".into(),
            value: round_to(c.obv_slope_12.exp(), 2),
        },
        // VWAP distance: signed percentage from VWAP. Linear, bounded by ~10%.
        ThoughtAST::Linear {
            name: "vwap-distance".into(),
            value: round_to(c.vwap_distance, 4),
            scale: 0.1,
        },
        // Buying pressure: (close - low) / range. [0, 1].
        ThoughtAST::Linear {
            name: "buying-pressure".into(),
            value: round_to(if range > 0.0 {
                (c.close - c.low) / range
            } else {
                0.5
            }, 2),
            scale: 1.0,
        },
        // Selling pressure: (high - close) / range. [0, 1].
        ThoughtAST::Linear {
            name: "selling-pressure".into(),
            value: round_to(if range > 0.0 {
                (c.high - c.close) / range
            } else {
                0.5
            }, 2),
            scale: 1.0,
        },
        // Volume ratio: current volume / average. Unbounded positive.
        ThoughtAST::Log {
            name: "volume-ratio".into(),
            value: round_to(c.volume_accel.exp().max(0.001), 2),
        },
        // Body ratio: |body| / range. [0, 1].
        ThoughtAST::Linear {
            name: "body-ratio".into(),
            value: round_to(if range > 0.0 {
                abs_body / range
            } else {
                0.0
            }, 2),
            scale: 1.0,
        },
    ]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_encode_flow_facts_nonempty() {
        let c = Candle::default();
        let facts = encode_flow_facts(&c);
        assert_eq!(facts.len(), 6);
    }

    #[test]
    fn test_buying_pressure_default() {
        let c = Candle::default();
        let facts = encode_flow_facts(&c);
        match &facts[2] {
            ThoughtAST::Linear { name, value, .. } => {
                assert_eq!(name, "buying-pressure");
                // (42200 - 41500) / (42500 - 41500) = 700/1000 = 0.7
                assert!((value - 0.7).abs() < 1e-9);
            }
            _ => panic!("expected Linear"),
        }
    }
}
