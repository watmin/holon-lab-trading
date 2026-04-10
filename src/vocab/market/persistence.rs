/// Hurst, autocorrelation, ADX.

use crate::candle::Candle;
use crate::enums::ThoughtAST;

pub fn encode_persistence_facts(c: &Candle) -> Vec<ThoughtAST> {
    vec![
        // Hurst exponent — >0.5 trending, <0.5 mean-reverting
        ThoughtAST::Linear { name: "hurst".into(), value: c.hurst, scale: 1.0 },
        // Autocorrelation — lag-1, signed
        ThoughtAST::Linear { name: "autocorrelation".into(), value: c.autocorrelation, scale: 1.0 },
        // ADX — trend strength [0, 100] normalized
        ThoughtAST::Linear { name: "adx".into(), value: c.adx / 100.0, scale: 1.0 },
    ]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_encode_persistence_facts_non_empty() {
        let c = Candle::default();
        let facts = encode_persistence_facts(&c);
        assert!(!facts.is_empty());
        assert_eq!(facts.len(), 3);
    }
}
