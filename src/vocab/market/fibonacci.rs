// vocab/market/fibonacci.rs — compiled from wat/vocab/market/fibonacci.wat
//
// Retracement level distances. Pure function: candle in, ASTs out.
// atoms: range-pos-12, range-pos-24, range-pos-48,
//        fib-dist-236, fib-dist-382, fib-dist-500, fib-dist-618, fib-dist-786

use crate::candle::Candle;
use crate::thought_encoder::ThoughtAST;

pub fn encode_fibonacci_facts(c: &Candle) -> Vec<ThoughtAST> {
    let pos48 = c.range_pos_48;

    vec![
        // Range position at each timeframe — Linear [0, 1]
        ThoughtAST::Linear {
            name: "range-pos-12".into(),
            value: c.range_pos_12,
            scale: 1.0,
        },
        ThoughtAST::Linear {
            name: "range-pos-24".into(),
            value: c.range_pos_24,
            scale: 1.0,
        },
        ThoughtAST::Linear {
            name: "range-pos-48".into(),
            value: pos48,
            scale: 1.0,
        },
        // Distance from key Fibonacci levels (using 48-period range)
        ThoughtAST::Linear {
            name: "fib-dist-236".into(),
            value: pos48 - 0.236,
            scale: 1.0,
        },
        ThoughtAST::Linear {
            name: "fib-dist-382".into(),
            value: pos48 - 0.382,
            scale: 1.0,
        },
        ThoughtAST::Linear {
            name: "fib-dist-500".into(),
            value: pos48 - 0.500,
            scale: 1.0,
        },
        ThoughtAST::Linear {
            name: "fib-dist-618".into(),
            value: pos48 - 0.618,
            scale: 1.0,
        },
        ThoughtAST::Linear {
            name: "fib-dist-786".into(),
            value: pos48 - 0.786,
            scale: 1.0,
        },
    ]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_encode_fibonacci_facts_nonempty() {
        let c = Candle::default();
        let facts = encode_fibonacci_facts(&c);
        assert_eq!(facts.len(), 8);
    }

    #[test]
    fn test_fib_dist_500() {
        let c = Candle::default();
        let facts = encode_fibonacci_facts(&c);
        match &facts[5] {
            ThoughtAST::Linear { name, value, .. } => {
                assert_eq!(name, "fib-dist-500");
                // range_pos_48 = 0.6, so 0.6 - 0.5 = 0.1
                assert!((value - 0.1).abs() < 1e-9);
            }
            _ => panic!("expected Linear"),
        }
    }
}
