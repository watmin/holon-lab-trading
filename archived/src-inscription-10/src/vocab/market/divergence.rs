// vocab/market/divergence.rs — compiled from wat/vocab/market/divergence.wat
//
// RSI divergence via structural peaks. Pure function: candle in, ASTs out.
// Conditional emission: divergence facts only fire when non-zero.
// atoms: rsi-divergence-bull, rsi-divergence-bear, divergence-spread

use crate::candle::Candle;
use crate::thought_encoder::ThoughtAST;

pub fn encode_divergence_facts(c: &Candle) -> Vec<ThoughtAST> {
    let bull = c.rsi_divergence_bull;
    let bear = c.rsi_divergence_bear;
    let mut facts = Vec::new();

    // Bullish divergence: only emitted when active.
    if bull > 0.0 {
        facts.push(ThoughtAST::Linear {
            name: "rsi-divergence-bull".into(),
            value: bull,
            scale: 1.0,
        });
    }

    // Bearish divergence: only emitted when active.
    if bear > 0.0 {
        facts.push(ThoughtAST::Linear {
            name: "rsi-divergence-bear".into(),
            value: bear,
            scale: 1.0,
        });
    }

    // Divergence spread: bull - bear. Only when either is active.
    if bull > 0.0 || bear > 0.0 {
        facts.push(ThoughtAST::Linear {
            name: "divergence-spread".into(),
            value: bull - bear,
            scale: 1.0,
        });
    }

    facts
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_encode_divergence_facts_empty_when_no_divergence() {
        let c = Candle::default(); // both divergence fields are 0.0
        let facts = encode_divergence_facts(&c);
        assert!(facts.is_empty());
    }

    #[test]
    fn test_encode_divergence_facts_with_bull() {
        let mut c = Candle::default();
        c.rsi_divergence_bull = 0.5;
        let facts = encode_divergence_facts(&c);
        assert_eq!(facts.len(), 2); // bull + spread
    }

    #[test]
    fn test_encode_divergence_facts_with_both() {
        let mut c = Candle::default();
        c.rsi_divergence_bull = 0.5;
        c.rsi_divergence_bear = 0.3;
        let facts = encode_divergence_facts(&c);
        assert_eq!(facts.len(), 3); // bull + bear + spread
    }
}
