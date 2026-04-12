// vocab/exit/volatility.rs — compiled from wat/vocab/exit/volatility.wat
//
// ATR regime, ATR ratio, squeeze state. Exit observers use these
// to estimate optimal distances. Pure function: candle in, ASTs out.
// atoms: atr-ratio, atr-r, atr-roc-6, atr-roc-12, squeeze, bb-width

use std::collections::HashMap;
use crate::types::candle::Candle;
use crate::encoding::thought_encoder::{ThoughtAST, ToAst, round_to};
use crate::encoding::scale_tracker::{ScaleTracker, scaled_linear};

pub struct ExitVolatilityThought {
    pub atr_ratio: f64,
    pub atr_r: f64,
    pub atr_roc_6: f64,
    pub atr_roc_12: f64,
    pub squeeze: f64,
    pub bb_width: f64,
}

impl ExitVolatilityThought {
    pub fn from_candle(c: &Candle) -> Self {
        Self {
            atr_ratio: round_to(c.atr_r.max(0.001), 2),
            atr_r: round_to(c.atr.max(0.001), 2),
            atr_roc_6: round_to(c.atr_roc_6, 2),
            atr_roc_12: round_to(c.atr_roc_12, 2),
            squeeze: round_to(c.squeeze, 2),
            bb_width: round_to(c.bb_width.max(0.001), 2),
        }
    }
}

impl ToAst for ExitVolatilityThought {
    fn to_ast(&self) -> ThoughtAST {
        ThoughtAST::Bundle(self.forms())
    }

    fn forms(&self) -> Vec<ThoughtAST> {
        vec![
            ThoughtAST::Log { name: "atr-ratio".into(), value: self.atr_ratio },
            ThoughtAST::Log { name: "atr-r".into(), value: self.atr_r },
            ThoughtAST::Linear { name: "atr-roc-6".into(), value: self.atr_roc_6, scale: 1.0 },
            ThoughtAST::Linear { name: "atr-roc-12".into(), value: self.atr_roc_12, scale: 1.0 },
            ThoughtAST::Linear { name: "squeeze".into(), value: self.squeeze, scale: 1.0 },
            ThoughtAST::Log { name: "bb-width".into(), value: self.bb_width },
        ]
    }
}

pub fn encode_exit_volatility_facts(c: &Candle, scales: &mut HashMap<String, ScaleTracker>) -> Vec<ThoughtAST> {
    let t = ExitVolatilityThought::from_candle(c);
    vec![
        ThoughtAST::Log { name: "atr-ratio".into(), value: t.atr_ratio },
        ThoughtAST::Log { name: "atr-r".into(), value: t.atr_r },
        scaled_linear("atr-roc-6", t.atr_roc_6, scales),
        scaled_linear("atr-roc-12", t.atr_roc_12, scales),
        scaled_linear("squeeze", t.squeeze, scales),
        ThoughtAST::Log { name: "bb-width".into(), value: t.bb_width },
    ]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_encode_exit_volatility_facts_nonempty() {
        let c = Candle::default();
        let mut scales = HashMap::new();
        let facts = encode_exit_volatility_facts(&c, &mut scales);
        assert_eq!(facts.len(), 6);
    }

    #[test]
    fn test_atr_ratio_log() {
        let c = Candle::default();
        let mut scales = HashMap::new();
        let facts = encode_exit_volatility_facts(&c, &mut scales);
        match &facts[0] {
            ThoughtAST::Log { name, value } => {
                assert_eq!(name, "atr-ratio");
                assert_eq!(*value, 0.01);
            }
            _ => panic!("expected Log"),
        }
    }
}
