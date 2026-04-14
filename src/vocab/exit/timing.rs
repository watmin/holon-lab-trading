// vocab/exit/timing.rs — compiled from wat/vocab/exit/timing.wat
//
// Momentum state and reversal signals. Exit observers use these
// to time entries and exits. Pure function: candle in, ASTs out.
// atoms: rsi, stoch-k, stoch-kd-spread, macd-hist, cci

use std::collections::HashMap;
use crate::types::candle::Candle;
use crate::encoding::thought_encoder::{ThoughtAST, round_to};
use crate::encoding::scale_tracker::{ScaleTracker, scaled_linear};

pub struct ExitTimingThought {
    pub rsi: f64,
    pub stoch_k: f64,
    pub stoch_kd_spread: f64,
    pub macd_hist: f64,
    pub cci: f64,
}

impl ExitTimingThought {
    pub fn from_candle(c: &Candle) -> Self {
        Self {
            rsi: round_to(c.rsi, 2),
            stoch_k: round_to(c.stoch_k / 100.0, 2),
            stoch_kd_spread: round_to((c.stoch_k - c.stoch_d) / 100.0, 2),
            macd_hist: round_to(c.macd_hist / c.close, 4),
            cci: round_to(c.cci / 300.0, 2),
        }
    }
}

pub fn encode_exit_timing_facts(c: &Candle, scales: &mut HashMap<String, ScaleTracker>) -> Vec<ThoughtAST> {
    let t = ExitTimingThought::from_candle(c);
    vec![
        scaled_linear("rsi", t.rsi, scales),
        scaled_linear("stoch-k", t.stoch_k, scales),
        scaled_linear("stoch-kd-spread", t.stoch_kd_spread, scales),
        scaled_linear("macd-hist", t.macd_hist, scales),
        scaled_linear("cci", t.cci, scales),
    ]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_encode_exit_timing_facts_nonempty() {
        let c = Candle::default();
        let mut scales = HashMap::new();
        let facts = encode_exit_timing_facts(&c, &mut scales);
        assert_eq!(facts.len(), 5);
    }

    #[test]
    fn test_stoch_kd_spread() {
        let c = Candle::default();
        let mut scales = HashMap::new();
        let facts = encode_exit_timing_facts(&c, &mut scales);
        match &facts[2] {
            ThoughtAST::Bind(left, right) => {
                match (left.as_ref(), right.as_ref()) {
                    (ThoughtAST::Atom(name), ThoughtAST::Linear { value, .. }) => {
                        assert_eq!(name, "stoch-kd-spread");
                        // (70 - 65) / 100 = 0.05
                        assert!((value - 0.05).abs() < 1e-9);
                    }
                    _ => panic!("expected Bind(Atom, Linear)"),
                }
            }
            _ => panic!("expected Bind"),
        }
    }
}
