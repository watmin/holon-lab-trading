use std::sync::Arc;
// vocab/exit/regime.rs — compiled from wat/vocab/exit/regime.wat
//
// Regime context for exit observers. Same candle fields as market/regime.rs.
// Pure function: candle in, ASTs out.
// atoms: kama-er, choppiness, dfa-alpha, variance-ratio,
//        entropy-rate, aroon-up, aroon-down, fractal-dim

use std::collections::HashMap;
use crate::types::candle::Candle;
use crate::encoding::thought_encoder::{ThoughtAST, round_to};
use crate::encoding::scale_tracker::{ScaleTracker, scaled_linear};

pub struct ExitRegimeThought {
    pub kama_er: f64,
    pub choppiness: f64,
    pub dfa_alpha: f64,
    pub variance_ratio: f64,
    pub entropy_rate: f64,
    pub aroon_up: f64,
    pub aroon_down: f64,
    pub fractal_dim: f64,
}

impl ExitRegimeThought {
    pub fn from_candle(c: &Candle) -> Self {
        Self {
            kama_er: round_to(c.kama_er, 2),
            choppiness: round_to(c.choppiness / 100.0, 2),
            dfa_alpha: round_to(c.dfa_alpha / 2.0, 2),
            variance_ratio: round_to(c.variance_ratio.max(0.001), 2),
            entropy_rate: round_to(c.entropy_rate, 2),
            aroon_up: round_to(c.aroon_up / 100.0, 2),
            aroon_down: round_to(c.aroon_down / 100.0, 2),
            fractal_dim: round_to(c.fractal_dim - 1.0, 2),
        }
    }
}

pub fn encode_exit_regime_facts(c: &Candle, scales: &mut HashMap<String, ScaleTracker>) -> Vec<ThoughtAST> {
    let t = ExitRegimeThought::from_candle(c);
    vec![
        scaled_linear("kama-er", t.kama_er, scales),
        scaled_linear("choppiness", t.choppiness, scales),
        scaled_linear("dfa-alpha", t.dfa_alpha, scales),
        ThoughtAST::Bind(Arc::new(ThoughtAST::Atom("variance-ratio".into())), Arc::new(ThoughtAST::Log { value: t.variance_ratio })),
        scaled_linear("entropy-rate", t.entropy_rate, scales),
        scaled_linear("aroon-up", t.aroon_up, scales),
        scaled_linear("aroon-down", t.aroon_down, scales),
        scaled_linear("fractal-dim", t.fractal_dim, scales),
    ]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_encode_exit_regime_facts_nonempty() {
        let c = Candle::default();
        let mut scales = HashMap::new();
        let facts = encode_exit_regime_facts(&c, &mut scales);
        assert_eq!(facts.len(), 8);
    }

    #[test]
    fn test_variance_ratio_log() {
        let c = Candle::default();
        let mut scales = HashMap::new();
        let facts = encode_exit_regime_facts(&c, &mut scales);
        match &facts[3] {
            ThoughtAST::Bind(left, right) => {
                match (left.as_ref(), right.as_ref()) {
                    (ThoughtAST::Atom(name), ThoughtAST::Log { value }) => {
                        assert_eq!(name, "variance-ratio");
                        assert_eq!(*value, 1.05);
                    }
                    _ => panic!("expected Bind(Atom, Log)"),
                }
            }
            _ => panic!("expected Bind"),
        }
    }
}
