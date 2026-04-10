// vocab/market/price_action.rs — compiled from wat/vocab/market/price-action.wat
//
// Candlestick anatomy, range, gaps. Pure function: candle in, ASTs out.
// atoms: range-ratio, gap, consecutive-up, consecutive-down,
//        body-ratio-pa, upper-wick, lower-wick

use crate::candle::Candle;
use crate::thought_encoder::{ThoughtAST, round_to};

pub fn encode_price_action_facts(c: &Candle) -> Vec<ThoughtAST> {
    let range = c.high - c.low;
    let body = (c.close - c.open).abs();
    let upper_wick = c.high - c.open.max(c.close);
    let lower_wick = c.open.min(c.close) - c.low;

    vec![
        // Range ratio: current range / previous range. Log-encoded.
        ThoughtAST::Log {
            name: "range-ratio".into(),
            value: round_to(c.range_ratio.max(0.001), 2),
        },
        // Gap: open vs previous close as percentage. Clamped to [-1, 1].
        ThoughtAST::Linear {
            name: "gap".into(),
            value: round_to((c.gap / 0.05).max(-1.0).min(1.0), 4),
            scale: 1.0,
        },
        // Consecutive up candles: count. Log-encoded.
        ThoughtAST::Log {
            name: "consecutive-up".into(),
            value: round_to((1.0 + c.consecutive_up).max(1.0), 2),
        },
        // Consecutive down candles: count. Log-encoded.
        ThoughtAST::Log {
            name: "consecutive-down".into(),
            value: round_to((1.0 + c.consecutive_down).max(1.0), 2),
        },
        // Body ratio (price-action): |body| / range. [0, 1].
        ThoughtAST::Linear {
            name: "body-ratio-pa".into(),
            value: round_to(if range > 0.0 { body / range } else { 0.0 }, 2),
            scale: 1.0,
        },
        // Upper wick: upper-wick / range. [0, 1].
        ThoughtAST::Linear {
            name: "upper-wick".into(),
            value: round_to(if range > 0.0 {
                upper_wick / range
            } else {
                0.0
            }, 2),
            scale: 1.0,
        },
        // Lower wick: lower-wick / range. [0, 1].
        ThoughtAST::Linear {
            name: "lower-wick".into(),
            value: round_to(if range > 0.0 {
                lower_wick / range
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
    fn test_encode_price_action_facts_nonempty() {
        let c = Candle::default();
        let facts = encode_price_action_facts(&c);
        assert_eq!(facts.len(), 7);
    }

    #[test]
    fn test_body_ratio_pa() {
        let c = Candle::default();
        let facts = encode_price_action_facts(&c);
        match &facts[4] {
            ThoughtAST::Linear { name, value, .. } => {
                assert_eq!(name, "body-ratio-pa");
                // |42200 - 42000| / (42500 - 41500) = 200/1000 = 0.2
                assert!((value - 0.2).abs() < 1e-9);
            }
            _ => panic!("expected Linear"),
        }
    }
}
