/// Fibonacci retracement level detection.

use crate::candle::Candle;
use crate::enums::ThoughtAST;

/// Distance to nearest Fibonacci level (signed).
fn dist_to_nearest_fib(pos: f64) -> f64 {
    const FIB_LEVELS: [f64; 5] = [0.236, 0.382, 0.500, 0.618, 0.786];
    let mut best = 1.0_f64;
    for &lvl in &FIB_LEVELS {
        let d = (pos - lvl).abs();
        if d < best.abs() {
            best = pos - lvl;
        }
    }
    best
}

pub fn encode_fibonacci_facts(c: &Candle) -> Vec<ThoughtAST> {
    let pos_12 = c.range_pos_12;
    let pos_24 = c.range_pos_24;
    let pos_48 = c.range_pos_48;

    vec![
        // Range positions as raw values
        ThoughtAST::Linear { name: "range-pos-12".into(), value: pos_12, scale: 1.0 },
        ThoughtAST::Linear { name: "range-pos-24".into(), value: pos_24, scale: 1.0 },
        ThoughtAST::Linear { name: "range-pos-48".into(), value: pos_48, scale: 1.0 },
        // Distance to nearest Fibonacci level — signed
        ThoughtAST::Linear { name: "fib-distance-12".into(), value: dist_to_nearest_fib(pos_12), scale: 1.0 },
        ThoughtAST::Linear { name: "fib-distance-24".into(), value: dist_to_nearest_fib(pos_24), scale: 1.0 },
        ThoughtAST::Linear { name: "fib-distance-48".into(), value: dist_to_nearest_fib(pos_48), scale: 1.0 },
    ]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_encode_fibonacci_facts_non_empty() {
        let c = Candle::default();
        let facts = encode_fibonacci_facts(&c);
        assert!(!facts.is_empty());
        assert_eq!(facts.len(), 6);
    }

    #[test]
    fn test_dist_to_nearest_fib() {
        // 0.5 is exactly at the 0.500 level
        assert!((dist_to_nearest_fib(0.5)).abs() < 1e-10);
        // 0.6 is near 0.618
        assert!((dist_to_nearest_fib(0.6) - (0.6 - 0.618)).abs() < 1e-10);
    }
}
