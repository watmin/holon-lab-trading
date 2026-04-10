/// KAMA-ER, choppiness, DFA, variance ratio, entropy, Aroon, fractal dim.

use crate::candle::Candle;
use crate::enums::ThoughtAST;

pub fn encode_regime_facts(c: &Candle) -> Vec<ThoughtAST> {
    vec![
        // KAMA Efficiency Ratio — [0, 1], 1 = perfectly efficient
        ThoughtAST::Linear { name: "kama-er".into(), value: c.kama_er, scale: 1.0 },
        // Choppiness Index — [0, 100] normalized, high = choppy
        ThoughtAST::Linear { name: "choppiness".into(), value: c.choppiness / 100.0, scale: 1.0 },
        // DFA alpha — scaling exponent
        ThoughtAST::Linear { name: "dfa-alpha".into(), value: c.dfa_alpha, scale: 2.0 },
        // Variance ratio — 1.0 = random walk
        ThoughtAST::Linear { name: "variance-ratio".into(), value: c.variance_ratio, scale: 2.0 },
        // Entropy rate — conditional entropy of returns
        ThoughtAST::Linear { name: "entropy-rate".into(), value: c.entropy_rate, scale: 2.0 },
        // Aroon up/down — [0, 100] normalized
        ThoughtAST::Linear { name: "aroon-up".into(), value: c.aroon_up / 100.0, scale: 1.0 },
        ThoughtAST::Linear { name: "aroon-down".into(), value: c.aroon_down / 100.0, scale: 1.0 },
        // Fractal dimension — 1.0 trending, 2.0 noisy
        ThoughtAST::Linear { name: "fractal-dim".into(), value: c.fractal_dim, scale: 2.0 },
    ]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_encode_regime_facts_non_empty() {
        let c = Candle::default();
        let facts = encode_regime_facts(&c);
        assert!(!facts.is_empty());
        assert_eq!(facts.len(), 8);
    }
}
