// vocab/market/standard.rs — compiled from wat/vocab/market/standard.wat
//
// Universal context for all market observers. Takes the candle WINDOW
// (a slice of candles), not a single candle.
// atoms: since-rsi-extreme, since-vol-spike, since-large-move,
//        dist-from-high, dist-from-low, dist-from-midpoint,
//        dist-from-sma200, session-depth

use std::collections::HashMap;
use crate::types::candle::Candle;
use crate::encoding::thought_encoder::{ThoughtAST, ToAst, round_to};
use crate::encoding::scale_tracker::{ScaleTracker, scaled_linear};

pub struct StandardThought {
    pub since_rsi_extreme: f64,
    pub since_vol_spike: f64,
    pub since_large_move: f64,
    pub dist_from_high: f64,
    pub dist_from_low: f64,
    pub dist_from_midpoint: f64,
    pub dist_from_sma200: f64,
    pub session_depth: f64,
}

impl StandardThought {
    pub fn from_window(candle_window: &[Candle]) -> Option<Self> {
        if candle_window.is_empty() {
            return None;
        }

        let current = candle_window.last().unwrap();
        let n = candle_window.len();
        let price = current.close;

        let mut window_high = f64::NEG_INFINITY;
        let mut window_low = f64::INFINITY;
        for c in candle_window {
            if c.high > window_high {
                window_high = c.high;
            }
            if c.low < window_low {
                window_low = c.low;
            }
        }
        let window_mid = (window_high + window_low) / 2.0;

        let mut last_rsi_extreme_idx = 0;
        for (i, c) in candle_window.iter().enumerate() {
            if c.rsi > 80.0 || c.rsi < 20.0 {
                last_rsi_extreme_idx = i;
            }
        }
        let since_rsi_extreme = (n - last_rsi_extreme_idx) as f64;

        let mut last_vol_spike_idx = 0;
        for (i, c) in candle_window.iter().enumerate() {
            if c.volume_accel > 2.0 {
                last_vol_spike_idx = i;
            }
        }
        let since_vol_spike = (n - last_vol_spike_idx) as f64;

        let mut last_large_move_idx = 0;
        for (i, c) in candle_window.iter().enumerate() {
            if c.roc_1.abs() > 0.02 {
                last_large_move_idx = i;
            }
        }
        let since_large_move = (n - last_large_move_idx) as f64;

        Some(Self {
            since_rsi_extreme: round_to(since_rsi_extreme.max(1.0), 2),
            since_vol_spike: round_to(since_vol_spike.max(1.0), 2),
            since_large_move: round_to(since_large_move.max(1.0), 2),
            dist_from_high: round_to((price - window_high) / price, 4),
            dist_from_low: round_to((price - window_low) / price, 4),
            dist_from_midpoint: round_to((price - window_mid) / price, 4),
            dist_from_sma200: round_to((price - current.sma200) / price, 4),
            session_depth: round_to((1.0 + n as f64).max(1.0), 2),
        })
    }
}

impl ToAst for StandardThought {
    fn to_ast(&self) -> ThoughtAST {
        ThoughtAST::Bundle(self.forms())
    }

    fn forms(&self) -> Vec<ThoughtAST> {
        vec![
            ThoughtAST::Log { name: "since-rsi-extreme".into(), value: self.since_rsi_extreme },
            ThoughtAST::Log { name: "since-vol-spike".into(), value: self.since_vol_spike },
            ThoughtAST::Log { name: "since-large-move".into(), value: self.since_large_move },
            ThoughtAST::Linear { name: "dist-from-high".into(), value: self.dist_from_high, scale: 0.1 },
            ThoughtAST::Linear { name: "dist-from-low".into(), value: self.dist_from_low, scale: 0.1 },
            ThoughtAST::Linear { name: "dist-from-midpoint".into(), value: self.dist_from_midpoint, scale: 0.1 },
            ThoughtAST::Linear { name: "dist-from-sma200".into(), value: self.dist_from_sma200, scale: 0.1 },
            ThoughtAST::Log { name: "session-depth".into(), value: self.session_depth },
        ]
    }
}

pub fn encode_standard_facts(candle_window: &[Candle], scales: &mut HashMap<String, ScaleTracker>) -> Vec<ThoughtAST> {
    match StandardThought::from_window(candle_window) {
        Some(t) => vec![
            ThoughtAST::Log { name: "since-rsi-extreme".into(), value: t.since_rsi_extreme },
            ThoughtAST::Log { name: "since-vol-spike".into(), value: t.since_vol_spike },
            ThoughtAST::Log { name: "since-large-move".into(), value: t.since_large_move },
            scaled_linear("dist-from-high", t.dist_from_high, scales),
            scaled_linear("dist-from-low", t.dist_from_low, scales),
            scaled_linear("dist-from-midpoint", t.dist_from_midpoint, scales),
            scaled_linear("dist-from-sma200", t.dist_from_sma200, scales),
            ThoughtAST::Log { name: "session-depth".into(), value: t.session_depth },
        ],
        None => Vec::new(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_encode_standard_facts_nonempty() {
        let window = vec![Candle::default()];
        let mut scales = HashMap::new();
        let facts = encode_standard_facts(&window, &mut scales);
        assert_eq!(facts.len(), 8);
    }

    #[test]
    fn test_encode_standard_facts_empty_window() {
        let mut scales = HashMap::new();
        let facts = encode_standard_facts(&[], &mut scales);
        assert!(facts.is_empty());
    }

    #[test]
    fn test_dist_from_high() {
        let window = vec![Candle::default()];
        let mut scales = HashMap::new();
        let facts = encode_standard_facts(&window, &mut scales);
        match &facts[3] {
            ThoughtAST::Linear { name, value, .. } => {
                assert_eq!(name, "dist-from-high");
                // (42200 - 42500) / 42200 = -300/42200 ~ -0.00711
                assert!(*value < 0.0);
            }
            _ => panic!("expected Linear"),
        }
    }

    #[test]
    fn test_multi_candle_window() {
        let mut c1 = Candle::default();
        c1.high = 43000.0;
        c1.low = 41000.0;
        c1.rsi = 85.0; // RSI extreme
        let c2 = Candle::default();
        let window = vec![c1, c2];
        let mut scales = HashMap::new();
        let facts = encode_standard_facts(&window, &mut scales);
        assert_eq!(facts.len(), 8);

        // since-rsi-extreme should be 1.0 (last candle at idx 0, n=2, 2-0=2, but max(1.0, 2.0)=2.0)
        // Actually: last_rsi_extreme_idx=0, n=2, since=2-0=2
        match &facts[0] {
            ThoughtAST::Log { name, value } => {
                assert_eq!(name, "since-rsi-extreme");
                assert_eq!(*value, 2.0);
            }
            _ => panic!("expected Log"),
        }
    }
}
