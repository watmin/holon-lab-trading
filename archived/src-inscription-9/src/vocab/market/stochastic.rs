/// %K/%D spread and crosses.

use crate::candle::Candle;
use crate::enums::ThoughtAST;

pub fn encode_stochastic_facts(c: &Candle) -> Vec<ThoughtAST> {
    vec![
        // %K value — [0, 1]
        ThoughtAST::Linear { name: "stoch-k".into(), value: c.stoch_k, scale: 1.0 },
        // %D value — [0, 1]
        ThoughtAST::Linear { name: "stoch-d".into(), value: c.stoch_d, scale: 1.0 },
        // K-D spread — signed, positive = K above D (bullish)
        ThoughtAST::Linear { name: "stoch-kd-spread".into(), value: c.stoch_k - c.stoch_d, scale: 1.0 },
        // Cross delta — change in K-D spread from previous candle
        ThoughtAST::Linear { name: "stoch-cross-delta".into(), value: c.stoch_cross_delta, scale: 1.0 },
    ]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_encode_stochastic_facts_non_empty() {
        let c = Candle::default();
        let facts = encode_stochastic_facts(&c);
        assert!(!facts.is_empty());
        assert_eq!(facts.len(), 4);
    }
}
