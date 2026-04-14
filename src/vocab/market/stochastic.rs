// vocab/market/stochastic.rs — compiled from wat/vocab/market/stochastic.wat
//
// %K/%D spread and crosses. Pure function: candle in, ASTs out.
// atoms: stoch-k, stoch-d, stoch-kd-spread, stoch-cross-delta

use std::collections::HashMap;
use crate::types::candle::Candle;
use crate::encoding::thought_encoder::{ThoughtAST, ToAst, round_to};
use crate::encoding::scale_tracker::{ScaleTracker, scaled_linear};

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
            ThoughtAST::Bind(Box::new(ThoughtAST::Atom("stoch-k".into())), Box::new(ThoughtAST::Linear { value: self.stoch_k, scale: 1.0 })),
            ThoughtAST::Bind(Box::new(ThoughtAST::Atom("stoch-d".into())), Box::new(ThoughtAST::Linear { value: self.stoch_d, scale: 1.0 })),
            ThoughtAST::Bind(Box::new(ThoughtAST::Atom("stoch-kd-spread".into())), Box::new(ThoughtAST::Linear { value: self.stoch_kd_spread, scale: 1.0 })),
            ThoughtAST::Bind(Box::new(ThoughtAST::Atom("stoch-cross-delta".into())), Box::new(ThoughtAST::Linear { value: self.stoch_cross_delta, scale: 1.0 })),
        ]
    }
}

pub fn encode_stochastic_facts(c: &Candle, scales: &mut HashMap<String, ScaleTracker>) -> Vec<ThoughtAST> {
    let t = StochasticThought::from_candle(c);
    vec![
        scaled_linear("stoch-k", t.stoch_k, scales),
        scaled_linear("stoch-d", t.stoch_d, scales),
        scaled_linear("stoch-kd-spread", t.stoch_kd_spread, scales),
        scaled_linear("stoch-cross-delta", t.stoch_cross_delta, scales),
    ]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_encode_stochastic_facts_nonempty() {
        let c = Candle::default();
        let mut scales = HashMap::new();
        let facts = encode_stochastic_facts(&c, &mut scales);
        assert_eq!(facts.len(), 4);
    }

    #[test]
    fn test_stoch_k_normalized() {
        let c = Candle::default();
        let mut scales = HashMap::new();
        let facts = encode_stochastic_facts(&c, &mut scales);
        match &facts[0] {
            ThoughtAST::Bind(left, right) => {
                match (left.as_ref(), right.as_ref()) {
                    (ThoughtAST::Atom(name), ThoughtAST::Linear { value, .. }) => {
                        assert_eq!(name, "stoch-k");
                        assert!((value - 0.7).abs() < 1e-9); // 70/100
                    }
                    _ => panic!("expected Bind(Atom, Linear)"),
                }
            }
            _ => panic!("expected Bind"),
        }
    }
}
