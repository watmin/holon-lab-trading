// vocab/exit/regime.rs — compiled from wat/vocab/exit/regime.wat
//
// Regime context for exit observers. Same candle fields as market/regime.rs.
// Pure function: candle in, ASTs out.
// atoms: kama-er, choppiness, dfa-alpha, variance-ratio,
//        entropy-rate, aroon-up, aroon-down, fractal-dim

use crate::candle::Candle;
use crate::thought_encoder::{ThoughtAST, round_to};

pub fn encode_exit_regime_facts(c: &Candle) -> Vec<ThoughtAST> {
    vec![
        // KAMA efficiency ratio: [0, 1].
        ThoughtAST::Linear {
            name: "kama-er".into(),
            value: round_to(c.kama_er, 2),
            scale: 1.0,
        },
        // Choppiness index: [0, 100]. Normalize to [0, 1].
        ThoughtAST::Linear {
            name: "choppiness".into(),
            value: round_to(c.choppiness / 100.0, 2),
            scale: 1.0,
        },
        // DFA alpha: [0, 2]. Normalize.
        ThoughtAST::Linear {
            name: "dfa-alpha".into(),
            value: round_to(c.dfa_alpha / 2.0, 2),
            scale: 1.0,
        },
        // Variance ratio: unbounded positive. Log-encoded.
        ThoughtAST::Log {
            name: "variance-ratio".into(),
            value: round_to(c.variance_ratio.max(0.001), 2),
        },
        // Entropy rate: [0, 1].
        ThoughtAST::Linear {
            name: "entropy-rate".into(),
            value: round_to(c.entropy_rate, 2),
            scale: 1.0,
        },
        // Aroon up: [0, 100]. Normalize.
        ThoughtAST::Linear {
            name: "aroon-up".into(),
            value: round_to(c.aroon_up / 100.0, 2),
            scale: 1.0,
        },
        // Aroon down: [0, 100]. Normalize.
        ThoughtAST::Linear {
            name: "aroon-down".into(),
            value: round_to(c.aroon_down / 100.0, 2),
            scale: 1.0,
        },
        // Fractal dimension: [1, 2]. Map to [0, 1].
        ThoughtAST::Linear {
            name: "fractal-dim".into(),
            value: round_to(c.fractal_dim - 1.0, 2),
            scale: 1.0,
        },
    ]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_encode_exit_regime_facts_nonempty() {
        let c = Candle::default();
        let facts = encode_exit_regime_facts(&c);
        assert_eq!(facts.len(), 8);
    }

    #[test]
    fn test_variance_ratio_log() {
        let c = Candle::default();
        let facts = encode_exit_regime_facts(&c);
        match &facts[3] {
            ThoughtAST::Log { name, value } => {
                assert_eq!(name, "variance-ratio");
                assert_eq!(*value, 1.05);
            }
            _ => panic!("expected Log"),
        }
    }
}
