// vocab/market/standard.rs — compiled from wat/vocab/market/standard.wat
//
// Universal context for all market observers. Takes the candle WINDOW
// (a slice of candles), not a single candle.
// atoms: since-rsi-extreme, since-vol-spike, since-large-move,
//        dist-from-high, dist-from-low, dist-from-midpoint,
//        dist-from-sma200, session-depth

use crate::candle::Candle;
use crate::thought_encoder::{ThoughtAST, round_to};

pub fn encode_standard_facts(candle_window: &[Candle]) -> Vec<ThoughtAST> {
    if candle_window.is_empty() {
        return Vec::new();
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

    // Since RSI extreme: candles since RSI was above 80 or below 20.
    // (Note: RSI on candle is raw [0, 100] scale based on default values)
    let mut last_rsi_extreme_idx = 0;
    for (i, c) in candle_window.iter().enumerate() {
        if c.rsi > 80.0 || c.rsi < 20.0 {
            last_rsi_extreme_idx = i;
        }
    }
    let since_rsi_extreme = (n - last_rsi_extreme_idx) as f64;

    // Since volume spike: candles since volume_accel exceeded 2.0.
    let mut last_vol_spike_idx = 0;
    for (i, c) in candle_window.iter().enumerate() {
        if c.volume_accel > 2.0 {
            last_vol_spike_idx = i;
        }
    }
    let since_vol_spike = (n - last_vol_spike_idx) as f64;

    // Since large move: candles since |roc_1| exceeded 0.02.
    let mut last_large_move_idx = 0;
    for (i, c) in candle_window.iter().enumerate() {
        if c.roc_1.abs() > 0.02 {
            last_large_move_idx = i;
        }
    }
    let since_large_move = (n - last_large_move_idx) as f64;

    vec![
        // Since RSI extreme: Log-encoded recency.
        ThoughtAST::Log {
            name: "since-rsi-extreme".into(),
            value: round_to(since_rsi_extreme.max(1.0), 2),
        },
        // Since volume spike: Log-encoded recency.
        ThoughtAST::Log {
            name: "since-vol-spike".into(),
            value: round_to(since_vol_spike.max(1.0), 2),
        },
        // Since large move: Log-encoded recency.
        ThoughtAST::Log {
            name: "since-large-move".into(),
            value: round_to(since_large_move.max(1.0), 2),
        },
        // Distance from window high: signed percentage. Always <= 0.
        ThoughtAST::Linear {
            name: "dist-from-high".into(),
            value: round_to((price - window_high) / price, 4),
            scale: 0.1,
        },
        // Distance from window low: signed percentage. Always >= 0.
        ThoughtAST::Linear {
            name: "dist-from-low".into(),
            value: round_to((price - window_low) / price, 4),
            scale: 0.1,
        },
        // Distance from midpoint: signed percentage.
        ThoughtAST::Linear {
            name: "dist-from-midpoint".into(),
            value: round_to((price - window_mid) / price, 4),
            scale: 0.1,
        },
        // Distance from SMA200: signed percentage.
        ThoughtAST::Linear {
            name: "dist-from-sma200".into(),
            value: round_to((price - current.sma200) / price, 4),
            scale: 0.1,
        },
        // Session depth: how deep into the window. Log-encoded.
        ThoughtAST::Log {
            name: "session-depth".into(),
            value: round_to((1.0 + n as f64).max(1.0), 2),
        },
    ]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_encode_standard_facts_nonempty() {
        let window = vec![Candle::default()];
        let facts = encode_standard_facts(&window);
        assert_eq!(facts.len(), 8);
    }

    #[test]
    fn test_encode_standard_facts_empty_window() {
        let facts = encode_standard_facts(&[]);
        assert!(facts.is_empty());
    }

    #[test]
    fn test_dist_from_high() {
        let window = vec![Candle::default()];
        let facts = encode_standard_facts(&window);
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
        let facts = encode_standard_facts(&window);
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
