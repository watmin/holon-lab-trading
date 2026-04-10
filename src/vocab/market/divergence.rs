/// RSI divergence via PELT structural peaks.

use crate::candle::Candle;
use crate::enums::ThoughtAST;

pub fn encode_divergence_facts(c: &Candle) -> Vec<ThoughtAST> {
    let mut facts = Vec::new();

    // Bullish divergence: price lower low, RSI higher low
    if c.rsi_divergence_bull > 0.0 {
        facts.push(ThoughtAST::Log {
            name: "rsi-divergence-bull".into(),
            value: 1.0 + c.rsi_divergence_bull,
        });
    }

    // Bearish divergence: price higher high, RSI lower high
    if c.rsi_divergence_bear > 0.0 {
        facts.push(ThoughtAST::Log {
            name: "rsi-divergence-bear".into(),
            value: 1.0 + c.rsi_divergence_bear,
        });
    }

    facts
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_encode_divergence_facts_default_empty() {
        let c = Candle::default();
        // Default has rsi_divergence_bull = 0.0 and rsi_divergence_bear = 0.0
        let facts = encode_divergence_facts(&c);
        assert!(facts.is_empty());
    }

    #[test]
    fn test_encode_divergence_facts_with_bull() {
        let mut c = Candle::default();
        c.rsi_divergence_bull = 0.5;
        let facts = encode_divergence_facts(&c);
        assert_eq!(facts.len(), 1);
    }

    #[test]
    fn test_encode_divergence_facts_with_both() {
        let mut c = Candle::default();
        c.rsi_divergence_bull = 0.5;
        c.rsi_divergence_bear = 0.3;
        let facts = encode_divergence_facts(&c);
        assert_eq!(facts.len(), 2);
    }
}
