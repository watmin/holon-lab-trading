// vocab/market/stochastic.rs — compiled from wat/vocab/market/stochastic.wat
//
// %K/%D spread and crosses. Pure function: candle in, ASTs out.
// atoms: stoch-k, stoch-d, stoch-kd-spread, stoch-cross-delta

use crate::candle::Candle;
use crate::thought_encoder::ThoughtAST;

pub fn encode_stochastic_facts(c: &Candle) -> Vec<ThoughtAST> {
    let k = c.stoch_k / 100.0;
    let d = c.stoch_d / 100.0;

    vec![
        // Stochastic %K: [0, 1].
        ThoughtAST::Linear {
            name: "stoch-k".into(),
            value: k,
            scale: 1.0,
        },
        // Stochastic %D: [0, 1].
        ThoughtAST::Linear {
            name: "stoch-d".into(),
            value: d,
            scale: 1.0,
        },
        // K-D spread: signed. [-1, 1].
        ThoughtAST::Linear {
            name: "stoch-kd-spread".into(),
            value: k - d,
            scale: 1.0,
        },
        // Stochastic cross delta: pre-computed. Signed. [-1, 1].
        ThoughtAST::Linear {
            name: "stoch-cross-delta".into(),
            value: c.stoch_cross_delta.max(-1.0).min(1.0),
            scale: 1.0,
        },
    ]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_encode_stochastic_facts_nonempty() {
        let c = Candle::default();
        let facts = encode_stochastic_facts(&c);
        assert_eq!(facts.len(), 4);
    }

    #[test]
    fn test_stoch_k_normalized() {
        let c = Candle::default();
        let facts = encode_stochastic_facts(&c);
        match &facts[0] {
            ThoughtAST::Linear { name, value, .. } => {
                assert_eq!(name, "stoch-k");
                assert!((value - 0.7).abs() < 1e-9); // 70/100
            }
            _ => panic!("expected Linear"),
        }
    }
}
