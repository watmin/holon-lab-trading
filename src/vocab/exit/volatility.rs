/// ATR regime, ATR ratio, squeeze state.

use crate::candle::Candle;
use crate::enums::ThoughtAST;

pub fn encode_exit_volatility_facts(c: &Candle) -> Vec<ThoughtAST> {
    vec![
        // ATR ratio — volatility relative to price
        ThoughtAST::Log { name: "atr-ratio".into(), value: c.atr_r.max(0.0001) },
        // ATR rate of change — is volatility expanding or contracting?
        ThoughtAST::Linear { name: "atr-roc-6".into(), value: c.atr_roc_6, scale: 1.0 },
        ThoughtAST::Linear { name: "atr-roc-12".into(), value: c.atr_roc_12, scale: 1.0 },
        // Squeeze state — BB inside Keltner
        ThoughtAST::Log { name: "squeeze".into(), value: c.squeeze.max(0.001) },
        // Bollinger width — how wide are the bands
        ThoughtAST::Log { name: "bb-width".into(), value: c.bb_width.max(0.001) },
        // Range ratio — compression vs expansion
        ThoughtAST::Log { name: "range-ratio".into(), value: c.range_ratio.max(0.001) },
    ]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_encode_exit_volatility_facts_non_empty() {
        let c = Candle::default();
        let facts = encode_exit_volatility_facts(&c);
        assert!(!facts.is_empty());
        assert_eq!(facts.len(), 6);
    }
}
