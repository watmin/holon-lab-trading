/// Williams %R, RSI, CCI, MFI, multi-ROC.

use crate::candle::Candle;
use crate::enums::ThoughtAST;

pub fn encode_oscillator_facts(c: &Candle) -> Vec<ThoughtAST> {
    vec![
        // RSI — [0, 1] from Wilder's formula
        ThoughtAST::Linear { name: "rsi".into(), value: c.rsi, scale: 1.0 },
        // Williams %R — [0, 1] normalized
        ThoughtAST::Linear { name: "williams-r".into(), value: c.williams_r, scale: 1.0 },
        // CCI — unbounded, use log for magnitude
        ThoughtAST::Log { name: "cci-magnitude".into(), value: 1.0 + c.cci.abs() },
        // CCI direction as linear
        ThoughtAST::Linear { name: "cci-direction".into(), value: c.cci.signum(), scale: 1.0 },
        // MFI — [0, 1]
        ThoughtAST::Linear { name: "mfi".into(), value: c.mfi, scale: 1.0 },
        // Multi-ROC — rate of change at different horizons
        ThoughtAST::Linear { name: "roc-1".into(), value: c.roc_1, scale: 0.1 },
        ThoughtAST::Linear { name: "roc-3".into(), value: c.roc_3, scale: 0.1 },
        ThoughtAST::Linear { name: "roc-6".into(), value: c.roc_6, scale: 0.1 },
        ThoughtAST::Linear { name: "roc-12".into(), value: c.roc_12, scale: 0.1 },
    ]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_encode_oscillator_facts_non_empty() {
        let c = Candle::default();
        let facts = encode_oscillator_facts(&c);
        assert!(!facts.is_empty());
        assert_eq!(facts.len(), 9);
    }
}
