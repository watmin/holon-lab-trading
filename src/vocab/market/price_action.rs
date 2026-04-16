use std::sync::Arc;
// vocab/market/price_action.rs — compiled from wat/vocab/market/price-action.wat
//
// Candlestick anatomy, range, gaps. Pure function: candle in, ASTs out.
// atoms: range-ratio, gap, consecutive-up, consecutive-down,
//        body-ratio-pa, upper-wick, lower-wick

use std::collections::HashMap;
use crate::types::candle::Candle;
use crate::encoding::thought_encoder::{ThoughtAST, round_to};
use crate::encoding::scale_tracker::{ScaleTracker, scaled_linear};

pub struct PriceActionThought {
    pub range_ratio: f64,
    pub gap: f64,
    pub consecutive_up: f64,
    pub consecutive_down: f64,
    pub body_ratio_pa: f64,
    pub upper_wick: f64,
    pub lower_wick: f64,
}

impl PriceActionThought {
    pub fn from_candle(c: &Candle) -> Self {
        let range = c.high - c.low;
        let body = (c.close - c.open).abs();
        let upper_wick = c.high - c.open.max(c.close);
        let lower_wick = c.open.min(c.close) - c.low;
        Self {
            range_ratio: round_to(c.range_ratio.max(0.001), 2),
            gap: round_to((c.gap / 0.05).max(-1.0).min(1.0), 4),
            consecutive_up: round_to((1.0 + c.consecutive_up).max(1.0), 2),
            consecutive_down: round_to((1.0 + c.consecutive_down).max(1.0), 2),
            body_ratio_pa: round_to(if range > 0.0 { body / range } else { 0.0 }, 2),
            upper_wick: round_to(if range > 0.0 { upper_wick / range } else { 0.0 }, 2),
            lower_wick: round_to(if range > 0.0 { lower_wick / range } else { 0.0 }, 2),
        }
    }
}

pub fn encode_price_action_facts(c: &Candle, scales: &mut HashMap<String, ScaleTracker>) -> Vec<ThoughtAST> {
    let t = PriceActionThought::from_candle(c);
    vec![
        ThoughtAST::Bind(Arc::new(ThoughtAST::Atom("range-ratio".into())), Arc::new(ThoughtAST::Log { value: t.range_ratio })),
        scaled_linear("gap", t.gap, scales),
        ThoughtAST::Bind(Arc::new(ThoughtAST::Atom("consecutive-up".into())), Arc::new(ThoughtAST::Log { value: t.consecutive_up })),
        ThoughtAST::Bind(Arc::new(ThoughtAST::Atom("consecutive-down".into())), Arc::new(ThoughtAST::Log { value: t.consecutive_down })),
        scaled_linear("body-ratio-pa", t.body_ratio_pa, scales),
        scaled_linear("upper-wick", t.upper_wick, scales),
        scaled_linear("lower-wick", t.lower_wick, scales),
    ]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_encode_price_action_facts_nonempty() {
        let c = Candle::default();
        let mut scales = HashMap::new();
        let facts = encode_price_action_facts(&c, &mut scales);
        assert_eq!(facts.len(), 7);
    }

    #[test]
    fn test_body_ratio_pa() {
        let c = Candle::default();
        let mut scales = HashMap::new();
        let facts = encode_price_action_facts(&c, &mut scales);
        match &facts[4] {
            ThoughtAST::Bind(left, right) => {
                match (left.as_ref(), right.as_ref()) {
                    (ThoughtAST::Atom(name), ThoughtAST::Linear { value, .. }) => {
                        assert_eq!(name, "body-ratio-pa");
                        // |42200 - 42000| / (42500 - 41500) = 200/1000 = 0.2
                        assert!((value - 0.2).abs() < 1e-9);
                    }
                    _ => panic!("expected Bind(Atom, Linear)"),
                }
            }
            _ => panic!("expected Bind"),
        }
    }
}
