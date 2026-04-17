use std::sync::Arc;
// vocab/market/momentum.rs — compiled from wat/vocab/market/momentum.wat
//
// Trend-relative, MACD, DI. Pure function: candle in, ASTs out.
// atoms: close-sma20, close-sma50, close-sma200, macd-hist, di-spread, atr-ratio

use std::collections::HashMap;
use crate::types::candle::Candle;
use crate::encoding::thought_encoder::{ThoughtAST, ThoughtASTKind, round_to};
use crate::encoding::scale_tracker::{ScaleTracker, scaled_linear};

pub struct MomentumThought {
    pub close_sma20: f64,
    pub close_sma50: f64,
    pub close_sma200: f64,
    pub macd_hist: f64,
    pub di_spread: f64,
    pub atr_ratio: f64,
}

impl MomentumThought {
    pub fn from_candle(c: &Candle) -> Self {
        Self {
            close_sma20: round_to((c.close - c.sma20) / c.close, 4),
            close_sma50: round_to((c.close - c.sma50) / c.close, 4),
            close_sma200: round_to((c.close - c.sma200) / c.close, 4),
            macd_hist: round_to(c.macd_hist / c.close, 4),
            di_spread: round_to((c.plus_di - c.minus_di) / 100.0, 2),
            atr_ratio: round_to(c.atr_ratio.max(0.001), 2),
        }
    }
}

pub fn encode_momentum_facts(c: &Candle, scales: &mut HashMap<String, ScaleTracker>) -> Vec<ThoughtAST> {
    let t = MomentumThought::from_candle(c);
    vec![
        scaled_linear("close-sma20", t.close_sma20, scales),
        scaled_linear("close-sma50", t.close_sma50, scales),
        scaled_linear("close-sma200", t.close_sma200, scales),
        scaled_linear("macd-hist", t.macd_hist, scales),
        scaled_linear("di-spread", t.di_spread, scales),
        ThoughtAST::new(ThoughtASTKind::Bind(Arc::new(ThoughtAST::new(ThoughtASTKind::Atom("atr-ratio".into()))), Arc::new(ThoughtAST::new(ThoughtASTKind::Log { value: t.atr_ratio })))),
    ]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_encode_momentum_facts_nonempty() {
        let c = Candle::default();
        let mut scales = HashMap::new();
        let facts = encode_momentum_facts(&c, &mut scales);
        assert_eq!(facts.len(), 6);
    }

    #[test]
    fn test_di_spread() {
        let c = Candle::default();
        let mut scales = HashMap::new();
        let facts = encode_momentum_facts(&c, &mut scales);
        match &facts[4].kind {
            ThoughtASTKind::Bind(left, right) => {
                match (&left.kind, &right.kind) {
                    (ThoughtASTKind::Atom(name), ThoughtASTKind::Linear { value, .. }) => {
                        assert_eq!(name, "di-spread");
                        // (25 - 20) / 100 = 0.05
                        assert!((value - 0.05).abs() < 1e-9);
                    }
                    _ => panic!("expected Bind(Atom, Linear)"),
                }
            }
            _ => panic!("expected Bind"),
        }
    }
}
