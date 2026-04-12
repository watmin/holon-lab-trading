// vocab/market/divergence.rs — compiled from wat/vocab/market/divergence.wat
//
// RSI divergence via structural peaks. Pure function: candle in, ASTs out.
// Conditional emission: divergence facts only fire when non-zero.
// atoms: rsi-divergence-bull, rsi-divergence-bear, divergence-spread

use std::collections::HashMap;
use crate::types::candle::Candle;
use crate::encoding::thought_encoder::{ThoughtAST, ToAst, round_to};
use crate::encoding::scale_tracker::{ScaleTracker, scaled_linear};

/// Divergence thought — conditional emission. Fields are Option because
/// divergence facts only fire when non-zero.
pub struct DivergenceThought {
    pub rsi_divergence_bull: Option<f64>,
    pub rsi_divergence_bear: Option<f64>,
    pub divergence_spread: Option<f64>,
}

impl DivergenceThought {
    pub fn from_candle(c: &Candle) -> Self {
        let bull = c.rsi_divergence_bull;
        let bear = c.rsi_divergence_bear;
        Self {
            rsi_divergence_bull: if bull > 0.0 { Some(round_to(bull, 2)) } else { None },
            rsi_divergence_bear: if bear > 0.0 { Some(round_to(bear, 2)) } else { None },
            divergence_spread: if bull > 0.0 || bear > 0.0 {
                Some(round_to(bull - bear, 2))
            } else {
                None
            },
        }
    }
}

impl ToAst for DivergenceThought {
    fn to_ast(&self) -> ThoughtAST {
        ThoughtAST::Bundle(self.forms())
    }

    fn forms(&self) -> Vec<ThoughtAST> {
        let mut facts = Vec::new();
        if let Some(v) = self.rsi_divergence_bull {
            facts.push(ThoughtAST::Linear { name: "rsi-divergence-bull".into(), value: v, scale: 1.0 });
        }
        if let Some(v) = self.rsi_divergence_bear {
            facts.push(ThoughtAST::Linear { name: "rsi-divergence-bear".into(), value: v, scale: 1.0 });
        }
        if let Some(v) = self.divergence_spread {
            facts.push(ThoughtAST::Linear { name: "divergence-spread".into(), value: v, scale: 1.0 });
        }
        facts
    }
}

pub fn encode_divergence_facts(c: &Candle, scales: &mut HashMap<String, ScaleTracker>) -> Vec<ThoughtAST> {
    let t = DivergenceThought::from_candle(c);
    let mut facts = Vec::new();
    if let Some(v) = t.rsi_divergence_bull {
        facts.push(scaled_linear("rsi-divergence-bull", v, scales));
    }
    if let Some(v) = t.rsi_divergence_bear {
        facts.push(scaled_linear("rsi-divergence-bear", v, scales));
    }
    if let Some(v) = t.divergence_spread {
        facts.push(scaled_linear("divergence-spread", v, scales));
    }
    facts
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_encode_divergence_facts_empty_when_no_divergence() {
        let c = Candle::default(); // both divergence fields are 0.0
        let mut scales = HashMap::new();
        let facts = encode_divergence_facts(&c, &mut scales);
        assert!(facts.is_empty());
    }

    #[test]
    fn test_encode_divergence_facts_with_bull() {
        let mut c = Candle::default();
        c.rsi_divergence_bull = 0.5;
        let mut scales = HashMap::new();
        let facts = encode_divergence_facts(&c, &mut scales);
        assert_eq!(facts.len(), 2); // bull + spread
    }

    #[test]
    fn test_encode_divergence_facts_with_both() {
        let mut c = Candle::default();
        c.rsi_divergence_bull = 0.5;
        c.rsi_divergence_bear = 0.3;
        let mut scales = HashMap::new();
        let facts = encode_divergence_facts(&c, &mut scales);
        assert_eq!(facts.len(), 3); // bull + bear + spread
    }
}
