// vocab/exit/timing.rs — compiled from wat/vocab/exit/timing.wat
//
// Momentum state and reversal signals. Exit observers use these
// to time entries and exits. Pure function: candle in, ASTs out.
// atoms: rsi, stoch-k, stoch-kd-spread, macd-hist, cci

use crate::candle::Candle;
use crate::thought_encoder::{ThoughtAST, round_to};

pub fn encode_exit_timing_facts(c: &Candle) -> Vec<ThoughtAST> {
    vec![
        // RSI: [0, 1] — Wilder's formula. Naturally bounded.
        ThoughtAST::Linear {
            name: "rsi".into(),
            value: round_to(c.rsi, 2),
            scale: 1.0,
        },
        // Stochastic %K: [0, 1].
        ThoughtAST::Linear {
            name: "stoch-k".into(),
            value: round_to(c.stoch_k / 100.0, 2),
            scale: 1.0,
        },
        // Stochastic %K - %D spread: signed. [-1, 1].
        ThoughtAST::Linear {
            name: "stoch-kd-spread".into(),
            value: round_to((c.stoch_k - c.stoch_d) / 100.0, 2),
            scale: 1.0,
        },
        // MACD histogram: signed. Normalize by close.
        ThoughtAST::Linear {
            name: "macd-hist".into(),
            value: round_to(c.macd_hist / c.close, 4),
            scale: 0.01,
        },
        // CCI: unbounded. Normalize by 300.
        ThoughtAST::Linear {
            name: "cci".into(),
            value: round_to(c.cci / 300.0, 2),
            scale: 1.0,
        },
    ]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_encode_exit_timing_facts_nonempty() {
        let c = Candle::default();
        let facts = encode_exit_timing_facts(&c);
        assert_eq!(facts.len(), 5);
    }

    #[test]
    fn test_stoch_kd_spread() {
        let c = Candle::default();
        let facts = encode_exit_timing_facts(&c);
        match &facts[2] {
            ThoughtAST::Linear { name, value, .. } => {
                assert_eq!(name, "stoch-kd-spread");
                // (70 - 65) / 100 = 0.05
                assert!((value - 0.05).abs() < 1e-9);
            }
            _ => panic!("expected Linear"),
        }
    }
}
