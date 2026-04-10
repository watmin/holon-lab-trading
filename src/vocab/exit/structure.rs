// vocab/exit/structure.rs — compiled from wat/vocab/exit/structure.wat
//
// Trend consistency and ADX strength. Exit observers use these
// to gauge how orderly the market is. Pure function: candle in, ASTs out.
// atoms: trend-consistency-6, trend-consistency-12, trend-consistency-24,
//        adx, exit-kama-er

use crate::candle::Candle;
use crate::thought_encoder::{ThoughtAST, round_to};

pub fn encode_exit_structure_facts(c: &Candle) -> Vec<ThoughtAST> {
    vec![
        // Trend consistency (6 period): [-1, 1].
        ThoughtAST::Linear {
            name: "trend-consistency-6".into(),
            value: round_to(c.trend_consistency_6, 2),
            scale: 1.0,
        },
        // Trend consistency (12 period): [-1, 1].
        ThoughtAST::Linear {
            name: "trend-consistency-12".into(),
            value: round_to(c.trend_consistency_12, 2),
            scale: 1.0,
        },
        // Trend consistency (24 period): [-1, 1].
        ThoughtAST::Linear {
            name: "trend-consistency-24".into(),
            value: round_to(c.trend_consistency_24, 2),
            scale: 1.0,
        },
        // ADX: [0, 100]. Normalize to [0, 1].
        ThoughtAST::Linear {
            name: "adx".into(),
            value: round_to(c.adx / 100.0, 2),
            scale: 1.0,
        },
        // KAMA efficiency ratio for exit context: [0, 1].
        ThoughtAST::Linear {
            name: "exit-kama-er".into(),
            value: round_to(c.kama_er, 2),
            scale: 1.0,
        },
    ]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_encode_exit_structure_facts_nonempty() {
        let c = Candle::default();
        let facts = encode_exit_structure_facts(&c);
        assert_eq!(facts.len(), 5);
    }

    #[test]
    fn test_exit_kama_er() {
        let c = Candle::default();
        let facts = encode_exit_structure_facts(&c);
        match &facts[4] {
            ThoughtAST::Linear { name, value, .. } => {
                assert_eq!(name, "exit-kama-er");
                assert_eq!(*value, 0.3);
            }
            _ => panic!("expected Linear"),
        }
    }
}
