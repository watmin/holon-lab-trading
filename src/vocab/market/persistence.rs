// vocab/market/persistence.rs — compiled from wat/vocab/market/persistence.wat
//
// Memory in the series. Pure function: candle in, ASTs out.
// atoms: hurst, autocorrelation, adx

use crate::candle::Candle;
use crate::thought_encoder::{ThoughtAST, round_to};

pub fn encode_persistence_facts(c: &Candle) -> Vec<ThoughtAST> {
    vec![
        // Hurst exponent: [0, 1]. 0.5 = random walk.
        ThoughtAST::Linear {
            name: "hurst".into(),
            value: round_to(c.hurst, 2),
            scale: 1.0,
        },
        // Autocorrelation: [-1, 1]. Signed.
        ThoughtAST::Linear {
            name: "autocorrelation".into(),
            value: round_to(c.autocorrelation, 2),
            scale: 1.0,
        },
        // ADX: [0, 100]. Normalize to [0, 1].
        ThoughtAST::Linear {
            name: "adx".into(),
            value: round_to(c.adx / 100.0, 2),
            scale: 1.0,
        },
    ]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_encode_persistence_facts_nonempty() {
        let c = Candle::default();
        let facts = encode_persistence_facts(&c);
        assert_eq!(facts.len(), 3);
    }

    #[test]
    fn test_hurst_value() {
        let c = Candle::default();
        let facts = encode_persistence_facts(&c);
        match &facts[0] {
            ThoughtAST::Linear { name, value, .. } => {
                assert_eq!(name, "hurst");
                assert_eq!(*value, 0.55);
            }
            _ => panic!("expected Linear"),
        }
    }
}
