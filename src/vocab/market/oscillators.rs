// vocab/market/oscillators.rs — compiled from wat/vocab/market/oscillators.wat
//
// Oscillator positions as scalars. Pure function: candle in, ASTs out.
// atoms: rsi, cci, mfi, williams-r, roc-1, roc-3, roc-6, roc-12

use std::collections::HashMap;
use crate::types::candle::Candle;
use crate::encoding::thought_encoder::{ThoughtAST, round_to};
use crate::encoding::scale_tracker::{ScaleTracker, scaled_linear};

pub struct OscillatorsThought {
    pub rsi: f64,
    pub cci: f64,
    pub mfi: f64,
    pub williams_r: f64,
    pub roc_1: f64,
    pub roc_3: f64,
    pub roc_6: f64,
    pub roc_12: f64,
}

impl OscillatorsThought {
    pub fn from_candle(c: &Candle) -> Self {
        Self {
            rsi: round_to(c.rsi, 2),
            cci: round_to(c.cci / 300.0, 2),
            mfi: round_to(c.mfi / 100.0, 2),
            williams_r: round_to((c.williams_r + 100.0) / 100.0, 2),
            roc_1: round_to(1.0 + c.roc_1, 2),
            roc_3: round_to(1.0 + c.roc_3, 2),
            roc_6: round_to(1.0 + c.roc_6, 2),
            roc_12: round_to(1.0 + c.roc_12, 2),
        }
    }
}

pub fn encode_oscillator_facts(c: &Candle, scales: &mut HashMap<String, ScaleTracker>) -> Vec<ThoughtAST> {
    let t = OscillatorsThought::from_candle(c);
    vec![
        scaled_linear("rsi", t.rsi, scales),
        scaled_linear("cci", t.cci, scales),
        scaled_linear("mfi", t.mfi, scales),
        scaled_linear("williams-r", t.williams_r, scales),
        ThoughtAST::Bind(Box::new(ThoughtAST::Atom("roc-1".into())), Box::new(ThoughtAST::Log { value: t.roc_1 })),
        ThoughtAST::Bind(Box::new(ThoughtAST::Atom("roc-3".into())), Box::new(ThoughtAST::Log { value: t.roc_3 })),
        ThoughtAST::Bind(Box::new(ThoughtAST::Atom("roc-6".into())), Box::new(ThoughtAST::Log { value: t.roc_6 })),
        ThoughtAST::Bind(Box::new(ThoughtAST::Atom("roc-12".into())), Box::new(ThoughtAST::Log { value: t.roc_12 })),
    ]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_encode_oscillator_facts_nonempty() {
        let c = Candle::default();
        let mut scales = HashMap::new();
        let facts = encode_oscillator_facts(&c, &mut scales);
        assert_eq!(facts.len(), 8);
    }

    #[test]
    fn test_rsi_value() {
        let c = Candle::default();
        let mut scales = HashMap::new();
        let facts = encode_oscillator_facts(&c, &mut scales);
        // scaled_linear returns Bind(Atom("rsi"), Linear{value, scale})
        match &facts[0] {
            ThoughtAST::Bind(left, right) => {
                match (left.as_ref(), right.as_ref()) {
                    (ThoughtAST::Atom(name), ThoughtAST::Linear { value, .. }) => {
                        assert_eq!(name, "rsi");
                        assert_eq!(*value, 55.0);
                    }
                    _ => panic!("expected Bind(Atom, Linear)"),
                }
            }
            _ => panic!("expected Bind"),
        }
    }
}
