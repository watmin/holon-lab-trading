/// Trend consistency, ADX strength.

use crate::candle::Candle;
use crate::enums::ThoughtAST;

pub fn encode_exit_structure_facts(c: &Candle) -> Vec<ThoughtAST> {
    vec![
        // Trend consistency at multiple horizons
        ThoughtAST::Linear { name: "trend-consistency-6".into(), value: c.trend_consistency_6, scale: 1.0 },
        ThoughtAST::Linear { name: "trend-consistency-12".into(), value: c.trend_consistency_12, scale: 1.0 },
        ThoughtAST::Linear { name: "trend-consistency-24".into(), value: c.trend_consistency_24, scale: 1.0 },
        // ADX — trend strength
        ThoughtAST::Linear { name: "adx".into(), value: c.adx / 100.0, scale: 1.0 },
        // DI spread — directional conviction
        ThoughtAST::Linear { name: "di-spread".into(), value: c.plus_di - c.minus_di, scale: 100.0 },
        // Hurst — trending vs mean-reverting
        ThoughtAST::Linear { name: "hurst".into(), value: c.hurst, scale: 1.0 },
    ]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_encode_exit_structure_facts_non_empty() {
        let c = Candle::default();
        let facts = encode_exit_structure_facts(&c);
        assert!(!facts.is_empty());
        assert_eq!(facts.len(), 6);
    }
}
