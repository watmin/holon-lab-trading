// vocab/exit/volatility.rs — compiled from wat/vocab/exit/volatility.wat
//
// ATR regime, ATR ratio, squeeze state. Exit observers use these
// to estimate optimal distances. Pure function: candle in, ASTs out.
// atoms: atr-ratio, atr-r, atr-roc-6, atr-roc-12, squeeze, bb-width

use crate::candle::Candle;
use crate::thought_encoder::{ThoughtAST, round_to};

pub fn encode_exit_volatility_facts(c: &Candle) -> Vec<ThoughtAST> {
    vec![
        // ATR ratio: ATR / close. Unbounded positive. Log-encoded.
        ThoughtAST::Log {
            name: "atr-ratio".into(),
            value: round_to(c.atr_r.max(0.001), 2),
        },
        // ATR raw: absolute average true range. Log-encoded.
        ThoughtAST::Log {
            name: "atr-r".into(),
            value: round_to(c.atr.max(0.001), 2),
        },
        // ATR rate of change (6 period): signed.
        ThoughtAST::Linear {
            name: "atr-roc-6".into(),
            value: round_to(c.atr_roc_6, 2),
            scale: 1.0,
        },
        // ATR rate of change (12 period): signed.
        ThoughtAST::Linear {
            name: "atr-roc-12".into(),
            value: round_to(c.atr_roc_12, 2),
            scale: 1.0,
        },
        // Squeeze: [0, 1].
        ThoughtAST::Linear {
            name: "squeeze".into(),
            value: round_to(c.squeeze, 2),
            scale: 1.0,
        },
        // Bollinger width: unbounded positive. Log-encoded.
        ThoughtAST::Log {
            name: "bb-width".into(),
            value: round_to(c.bb_width.max(0.001), 2),
        },
    ]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_encode_exit_volatility_facts_nonempty() {
        let c = Candle::default();
        let facts = encode_exit_volatility_facts(&c);
        assert_eq!(facts.len(), 6);
    }

    #[test]
    fn test_atr_ratio_log() {
        let c = Candle::default();
        let facts = encode_exit_volatility_facts(&c);
        match &facts[0] {
            ThoughtAST::Log { name, value } => {
                assert_eq!(name, "atr-ratio");
                assert_eq!(*value, 0.01);
            }
            _ => panic!("expected Log"),
        }
    }
}
