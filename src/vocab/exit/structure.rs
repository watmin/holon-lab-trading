// vocab/exit/structure.rs — compiled from wat/vocab/exit/structure.wat
//
// Trend consistency and ADX strength. Exit observers use these
// to gauge how orderly the market is. Pure function: candle in, ASTs out.
// atoms: trend-consistency-6, trend-consistency-12, trend-consistency-24,
//        adx, exit-kama-er

use std::collections::HashMap;
use crate::types::candle::Candle;
use crate::encoding::thought_encoder::{ThoughtAST, ToAst, round_to};
use crate::encoding::scale_tracker::{ScaleTracker, scaled_linear};

pub struct ExitStructureThought {
    pub trend_consistency_6: f64,
    pub trend_consistency_12: f64,
    pub trend_consistency_24: f64,
    pub adx: f64,
    pub exit_kama_er: f64,
}

impl ExitStructureThought {
    pub fn from_candle(c: &Candle) -> Self {
        Self {
            trend_consistency_6: round_to(c.trend_consistency_6, 2),
            trend_consistency_12: round_to(c.trend_consistency_12, 2),
            trend_consistency_24: round_to(c.trend_consistency_24, 2),
            adx: round_to(c.adx / 100.0, 2),
            exit_kama_er: round_to(c.kama_er, 2),
        }
    }
}

impl ToAst for ExitStructureThought {
    fn to_ast(&self) -> ThoughtAST {
        ThoughtAST::Bundle(self.forms())
    }

    fn forms(&self) -> Vec<ThoughtAST> {
        vec![
            ThoughtAST::Linear { name: "trend-consistency-6".into(), value: self.trend_consistency_6, scale: 1.0 },
            ThoughtAST::Linear { name: "trend-consistency-12".into(), value: self.trend_consistency_12, scale: 1.0 },
            ThoughtAST::Linear { name: "trend-consistency-24".into(), value: self.trend_consistency_24, scale: 1.0 },
            ThoughtAST::Linear { name: "adx".into(), value: self.adx, scale: 1.0 },
            ThoughtAST::Linear { name: "exit-kama-er".into(), value: self.exit_kama_er, scale: 1.0 },
        ]
    }
}

pub fn encode_exit_structure_facts(c: &Candle, scales: &mut HashMap<String, ScaleTracker>) -> Vec<ThoughtAST> {
    let t = ExitStructureThought::from_candle(c);
    vec![
        scaled_linear("trend-consistency-6", t.trend_consistency_6, scales),
        scaled_linear("trend-consistency-12", t.trend_consistency_12, scales),
        scaled_linear("trend-consistency-24", t.trend_consistency_24, scales),
        scaled_linear("adx", t.adx, scales),
        scaled_linear("exit-kama-er", t.exit_kama_er, scales),
    ]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_encode_exit_structure_facts_nonempty() {
        let c = Candle::default();
        let mut scales = HashMap::new();
        let facts = encode_exit_structure_facts(&c, &mut scales);
        assert_eq!(facts.len(), 5);
    }

    #[test]
    fn test_exit_kama_er() {
        let c = Candle::default();
        let mut scales = HashMap::new();
        let facts = encode_exit_structure_facts(&c, &mut scales);
        match &facts[4] {
            ThoughtAST::Linear { name, value, .. } => {
                assert_eq!(name, "exit-kama-er");
                assert_eq!(*value, 0.3);
            }
            _ => panic!("expected Linear"),
        }
    }
}
