// vocab/market/regime.rs — compiled from wat/vocab/market/regime.wat
//
// What KIND of market this is. Pure function: candle in, ASTs out.
// atoms: kama-er, choppiness, dfa-alpha, variance-ratio,
//        entropy-rate, aroon-up, aroon-down, fractal-dim

use std::collections::HashMap;
use crate::types::candle::Candle;
use crate::encoding::thought_encoder::{ThoughtAST, ToAst, round_to};
use crate::encoding::scale_tracker::{ScaleTracker, scaled_linear};

pub struct RegimeThought {
    pub kama_er: f64,
    pub choppiness: f64,
    pub dfa_alpha: f64,
    pub variance_ratio: f64,
    pub entropy_rate: f64,
    pub aroon_up: f64,
    pub aroon_down: f64,
    pub fractal_dim: f64,
}

impl RegimeThought {
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

impl ToAst for RegimeThought {
    fn to_ast(&self) -> ThoughtAST {
        ThoughtAST::Bundle(self.forms())
    }

    fn forms(&self) -> Vec<ThoughtAST> {
        vec![
            ThoughtAST::Linear { name: "kama-er".into(), value: self.kama_er, scale: 1.0 },
            ThoughtAST::Linear { name: "choppiness".into(), value: self.choppiness, scale: 1.0 },
            ThoughtAST::Linear { name: "dfa-alpha".into(), value: self.dfa_alpha, scale: 1.0 },
            ThoughtAST::Log { name: "variance-ratio".into(), value: self.variance_ratio },
            ThoughtAST::Linear { name: "entropy-rate".into(), value: self.entropy_rate, scale: 1.0 },
            ThoughtAST::Linear { name: "aroon-up".into(), value: self.aroon_up, scale: 1.0 },
            ThoughtAST::Linear { name: "aroon-down".into(), value: self.aroon_down, scale: 1.0 },
            ThoughtAST::Linear { name: "fractal-dim".into(), value: self.fractal_dim, scale: 1.0 },
        ]
    }
}

pub fn encode_regime_facts(c: &Candle, scales: &mut HashMap<String, ScaleTracker>) -> Vec<ThoughtAST> {
    let t = RegimeThought::from_candle(c);
    vec![
        scaled_linear("kama-er", t.kama_er, scales),
        scaled_linear("choppiness", t.choppiness, scales),
        scaled_linear("dfa-alpha", t.dfa_alpha, scales),
        ThoughtAST::Log { name: "variance-ratio".into(), value: t.variance_ratio },
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
    fn test_encode_regime_facts_nonempty() {
        let c = Candle::default();
        let mut scales = HashMap::new();
        let facts = encode_regime_facts(&c, &mut scales);
        assert_eq!(facts.len(), 8);
    }

    #[test]
    fn test_variance_ratio_log() {
        let c = Candle::default();
        let mut scales = HashMap::new();
        let facts = encode_regime_facts(&c, &mut scales);
        match &facts[3] {
            ThoughtAST::Log { name, value } => {
                assert_eq!(name, "variance-ratio");
                assert_eq!(*value, 1.05);
            }
            _ => panic!("expected Log"),
        }
    }
}
