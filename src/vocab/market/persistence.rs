// vocab/market/persistence.rs — compiled from wat/vocab/market/persistence.wat
//
// Memory in the series. Pure function: candle in, ASTs out.
// atoms: hurst, autocorrelation, adx

use std::collections::HashMap;
use crate::types::candle::Candle;
use crate::encoding::thought_encoder::{ThoughtAST, ToAst, round_to};
use crate::encoding::scale_tracker::{ScaleTracker, scaled_linear};

pub struct PersistenceThought {
    pub hurst: f64,
    pub autocorrelation: f64,
    pub adx: f64,
}

impl PersistenceThought {
    pub fn from_candle(c: &Candle) -> Self {
        Self {
            hurst: round_to(c.hurst, 2),
            autocorrelation: round_to(c.autocorrelation, 2),
            adx: round_to(c.adx / 100.0, 2),
        }
    }
}

impl ToAst for PersistenceThought {
    fn to_ast(&self) -> ThoughtAST {
        ThoughtAST::Bundle(self.forms())
    }

    fn forms(&self) -> Vec<ThoughtAST> {
        vec![
            ThoughtAST::Bind(Box::new(ThoughtAST::Atom("hurst".into())), Box::new(ThoughtAST::Linear { value: self.hurst, scale: 1.0 })),
            ThoughtAST::Bind(Box::new(ThoughtAST::Atom("autocorrelation".into())), Box::new(ThoughtAST::Linear { value: self.autocorrelation, scale: 1.0 })),
            ThoughtAST::Bind(Box::new(ThoughtAST::Atom("adx".into())), Box::new(ThoughtAST::Linear { value: self.adx, scale: 1.0 })),
        ]
    }
}

pub fn encode_persistence_facts(c: &Candle, scales: &mut HashMap<String, ScaleTracker>) -> Vec<ThoughtAST> {
    let t = PersistenceThought::from_candle(c);
    vec![
        scaled_linear("hurst", t.hurst, scales),
        scaled_linear("autocorrelation", t.autocorrelation, scales),
        scaled_linear("adx", t.adx, scales),
    ]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_encode_persistence_facts_nonempty() {
        let c = Candle::default();
        let mut scales = HashMap::new();
        let facts = encode_persistence_facts(&c, &mut scales);
        assert_eq!(facts.len(), 3);
    }

    #[test]
    fn test_hurst_value() {
        let c = Candle::default();
        let mut scales = HashMap::new();
        let facts = encode_persistence_facts(&c, &mut scales);
        match &facts[0] {
            ThoughtAST::Bind(left, right) => {
                match (left.as_ref(), right.as_ref()) {
                    (ThoughtAST::Atom(name), ThoughtAST::Linear { value, .. }) => {
                        assert_eq!(name, "hurst");
                        assert_eq!(*value, 0.55);
                    }
                    _ => panic!("expected Bind(Atom, Linear)"),
                }
            }
            _ => panic!("expected Bind"),
        }
    }
}
