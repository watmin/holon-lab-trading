// vocab/market/oscillators.rs — compiled from wat/vocab/market/oscillators.wat
//
// Oscillator positions as scalars. Pure function: candle in, ASTs out.
// atoms: rsi, cci, mfi, williams-r, roc-1, roc-3, roc-6, roc-12

use std::collections::HashMap;
use crate::types::candle::Candle;
use crate::encoding::thought_encoder::{ThoughtAST, ToAst, round_to};
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

impl ToAst for OscillatorsThought {
    fn to_ast(&self) -> ThoughtAST {
        ThoughtAST::Bundle(self.forms())
    }

    fn forms(&self) -> Vec<ThoughtAST> {
        vec![
            ThoughtAST::Linear { name: "rsi".into(), value: self.rsi, scale: 1.0 },
            ThoughtAST::Linear { name: "cci".into(), value: self.cci, scale: 1.0 },
            ThoughtAST::Linear { name: "mfi".into(), value: self.mfi, scale: 1.0 },
            ThoughtAST::Linear { name: "williams-r".into(), value: self.williams_r, scale: 1.0 },
            ThoughtAST::Log { name: "roc-1".into(), value: self.roc_1 },
            ThoughtAST::Log { name: "roc-3".into(), value: self.roc_3 },
            ThoughtAST::Log { name: "roc-6".into(), value: self.roc_6 },
            ThoughtAST::Log { name: "roc-12".into(), value: self.roc_12 },
        ]
    }
}

pub fn encode_oscillator_facts(c: &Candle, scales: &mut HashMap<String, ScaleTracker>) -> Vec<ThoughtAST> {
    let t = OscillatorsThought::from_candle(c);
    vec![
        scaled_linear("rsi", t.rsi, scales),
        scaled_linear("cci", t.cci, scales),
        scaled_linear("mfi", t.mfi, scales),
        scaled_linear("williams-r", t.williams_r, scales),
        ThoughtAST::Log { name: "roc-1".into(), value: t.roc_1 },
        ThoughtAST::Log { name: "roc-3".into(), value: t.roc_3 },
        ThoughtAST::Log { name: "roc-6".into(), value: t.roc_6 },
        ThoughtAST::Log { name: "roc-12".into(), value: t.roc_12 },
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
        match &facts[0] {
            ThoughtAST::Linear { name, value, .. } => {
                assert_eq!(name, "rsi");
                assert_eq!(*value, 55.0);
            }
            _ => panic!("expected Linear"),
        }
    }
}
