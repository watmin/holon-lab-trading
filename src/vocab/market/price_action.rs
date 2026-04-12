// vocab/market/price_action.rs — compiled from wat/vocab/market/price-action.wat
//
// Candlestick anatomy, range, gaps. Pure function: candle in, ASTs out.
// atoms: range-ratio, gap, consecutive-up, consecutive-down,
//        body-ratio-pa, upper-wick, lower-wick

use crate::candle::Candle;
use crate::thought_encoder::{ThoughtAST, ToAst, round_to};

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

impl ToAst for PriceActionThought {
    fn to_ast(&self) -> ThoughtAST {
        ThoughtAST::Bundle(self.forms())
    }

    fn forms(&self) -> Vec<ThoughtAST> {
        vec![
            ThoughtAST::Log { name: "range-ratio".into(), value: self.range_ratio },
            ThoughtAST::Linear { name: "gap".into(), value: self.gap, scale: 1.0 },
            ThoughtAST::Log { name: "consecutive-up".into(), value: self.consecutive_up },
            ThoughtAST::Log { name: "consecutive-down".into(), value: self.consecutive_down },
            ThoughtAST::Linear { name: "body-ratio-pa".into(), value: self.body_ratio_pa, scale: 1.0 },
            ThoughtAST::Linear { name: "upper-wick".into(), value: self.upper_wick, scale: 1.0 },
            ThoughtAST::Linear { name: "lower-wick".into(), value: self.lower_wick, scale: 1.0 },
        ]
    }
}

pub fn encode_price_action_facts(c: &Candle) -> Vec<ThoughtAST> {
    PriceActionThought::from_candle(c).forms()
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
