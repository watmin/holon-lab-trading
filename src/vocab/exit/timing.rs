/// Momentum state, reversal signals.

use crate::candle::Candle;
use crate::enums::ThoughtAST;

pub fn encode_exit_timing_facts(c: &Candle) -> Vec<ThoughtAST> {
    vec![
        // RSI — potential reversal zone
        ThoughtAST::Linear { name: "rsi".into(), value: c.rsi, scale: 1.0 },
        // Stochastic K-D spread — momentum cross signal
        ThoughtAST::Linear { name: "stoch-kd-spread".into(), value: c.stoch_k - c.stoch_d, scale: 1.0 },
        // Stochastic cross delta — is momentum shifting?
        ThoughtAST::Linear { name: "stoch-cross-delta".into(), value: c.stoch_cross_delta, scale: 1.0 },
        // MACD histogram — momentum direction
        ThoughtAST::Linear { name: "macd-hist".into(), value: c.macd_hist, scale: 0.01 },
        // Williams %R — overbought/oversold
        ThoughtAST::Linear { name: "williams-r".into(), value: c.williams_r, scale: 1.0 },
        // Multi-ROC — momentum at different horizons
        ThoughtAST::Linear { name: "roc-1".into(), value: c.roc_1, scale: 0.1 },
        ThoughtAST::Linear { name: "roc-6".into(), value: c.roc_6, scale: 0.1 },
    ]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_encode_exit_timing_facts_non_empty() {
        let c = Candle::default();
        let facts = encode_exit_timing_facts(&c);
        assert!(!facts.is_empty());
        assert_eq!(facts.len(), 7);
    }
}
