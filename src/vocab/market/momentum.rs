// vocab/market/momentum.rs — compiled from wat/vocab/market/momentum.wat
//
// Trend-relative, MACD, DI. Pure function: candle in, ASTs out.
// atoms: close-sma20, close-sma50, close-sma200, macd-hist, di-spread, atr-ratio

use crate::candle::Candle;
use crate::thought_encoder::{ThoughtAST, round_to};

pub fn encode_momentum_facts(c: &Candle) -> Vec<ThoughtAST> {
    vec![
        // Close relative to SMA20: signed percentage distance.
        ThoughtAST::Linear {
            name: "close-sma20".into(),
            value: round_to((c.close - c.sma20) / c.close, 4),
            scale: 0.1,
        },
        // Close relative to SMA50: signed percentage distance.
        ThoughtAST::Linear {
            name: "close-sma50".into(),
            value: round_to((c.close - c.sma50) / c.close, 4),
            scale: 0.1,
        },
        // Close relative to SMA200: signed percentage distance.
        ThoughtAST::Linear {
            name: "close-sma200".into(),
            value: round_to((c.close - c.sma200) / c.close, 4),
            scale: 0.1,
        },
        // MACD histogram: signed, normalize by close.
        ThoughtAST::Linear {
            name: "macd-hist".into(),
            value: round_to(c.macd_hist / c.close, 4),
            scale: 0.01,
        },
        // DI spread: plus-DI minus minus-DI. Normalize to [-1, 1].
        ThoughtAST::Linear {
            name: "di-spread".into(),
            value: round_to((c.plus_di - c.minus_di) / 100.0, 2),
            scale: 1.0,
        },
        // ATR ratio: ATR / close. Log-encoded.
        ThoughtAST::Log {
            name: "atr-ratio".into(),
            value: round_to(c.atr_r.max(0.001), 2),
        },
    ]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_encode_momentum_facts_nonempty() {
        let c = Candle::default();
        let facts = encode_momentum_facts(&c);
        assert_eq!(facts.len(), 6);
    }

    #[test]
    fn test_di_spread() {
        let c = Candle::default();
        let facts = encode_momentum_facts(&c);
        match &facts[4] {
            ThoughtAST::Linear { name, value, .. } => {
                assert_eq!(name, "di-spread");
                // (25 - 20) / 100 = 0.05
                assert!((value - 0.05).abs() < 1e-9);
            }
            _ => panic!("expected Linear"),
        }
    }
}
