// vocab/market/stochastic.rs — compiled from wat/vocab/market/stochastic.wat
//
// %K/%D spread and crosses. Pure function: candle in, ASTs out.
// atoms: stoch-k, stoch-d, stoch-kd-spread, stoch-cross-delta

use crate::candle::Candle;
use crate::thought_encoder::{ThoughtAST, ToAst, round_to};

pub struct StochasticThought {
    pub stoch_k: f64,
    pub stoch_d: f64,
    pub stoch_kd_spread: f64,
    pub stoch_cross_delta: f64,
}

impl StochasticThought {
    pub fn from_candle(c: &Candle) -> Self {
        let k = c.stoch_k / 100.0;
        let d = c.stoch_d / 100.0;
        Self {
            stoch_k: round_to(k, 2),
            stoch_d: round_to(d, 2),
            stoch_kd_spread: round_to(k - d, 2),
            stoch_cross_delta: round_to(c.stoch_cross_delta.max(-1.0).min(1.0), 2),
        }
    }
}

impl ToAst for StochasticThought {
    fn to_ast(&self) -> ThoughtAST {
        ThoughtAST::Bundle(self.forms())
    }

    fn forms(&self) -> Vec<ThoughtAST> {
        vec![
            ThoughtAST::Linear { name: "stoch-k".into(), value: self.stoch_k, scale: 1.0 },
            ThoughtAST::Linear { name: "stoch-d".into(), value: self.stoch_d, scale: 1.0 },
            ThoughtAST::Linear { name: "stoch-kd-spread".into(), value: self.stoch_kd_spread, scale: 1.0 },
            ThoughtAST::Linear { name: "stoch-cross-delta".into(), value: self.stoch_cross_delta, scale: 1.0 },
        ]
    }
}

pub fn encode_stochastic_facts(c: &Candle) -> Vec<ThoughtAST> {
    StochasticThought::from_candle(c).forms()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_encode_stochastic_facts_nonempty() {
        let c = Candle::default();
        let facts = encode_stochastic_facts(&c);
        assert_eq!(facts.len(), 4);
    }

    #[test]
    fn test_stoch_k_normalized() {
        let c = Candle::default();
        let facts = encode_stochastic_facts(&c);
        match &facts[0] {
            ThoughtAST::Linear { name, value, .. } => {
                assert_eq!(name, "stoch-k");
                assert!((value - 0.7).abs() < 1e-9); // 70/100
            }
            _ => panic!("expected Linear"),
        }
    }
}
