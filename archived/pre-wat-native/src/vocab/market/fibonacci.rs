// vocab/market/fibonacci.rs — compiled from wat/vocab/market/fibonacci.wat
//
// Retracement level distances. Pure function: candle in, ASTs out.
// atoms: range-pos-12, range-pos-24, range-pos-48,
//        fib-dist-236, fib-dist-382, fib-dist-500, fib-dist-618, fib-dist-786

use std::collections::HashMap;
use crate::types::candle::Candle;
use crate::encoding::thought_encoder::{ThoughtAST, round_to};
use crate::encoding::scale_tracker::{ScaleTracker, scaled_linear};

pub struct FibonacciThought {
    pub range_pos_12: f64,
    pub range_pos_24: f64,
    pub range_pos_48: f64,
    pub fib_dist_236: f64,
    pub fib_dist_382: f64,
    pub fib_dist_500: f64,
    pub fib_dist_618: f64,
    pub fib_dist_786: f64,
}

impl FibonacciThought {
    pub fn from_candle(c: &Candle) -> Self {
        let pos48 = c.range_pos_48;
        Self {
            range_pos_12: round_to(c.range_pos_12, 2),
            range_pos_24: round_to(c.range_pos_24, 2),
            range_pos_48: round_to(pos48, 2),
            fib_dist_236: round_to(pos48 - 0.236, 2),
            fib_dist_382: round_to(pos48 - 0.382, 2),
            fib_dist_500: round_to(pos48 - 0.500, 2),
            fib_dist_618: round_to(pos48 - 0.618, 2),
            fib_dist_786: round_to(pos48 - 0.786, 2),
        }
    }
}

pub fn encode_fibonacci_facts(c: &Candle, scales: &mut HashMap<String, ScaleTracker>) -> Vec<ThoughtAST> {
    let t = FibonacciThought::from_candle(c);
    vec![
        scaled_linear("range-pos-12", t.range_pos_12, scales),
        scaled_linear("range-pos-24", t.range_pos_24, scales),
        scaled_linear("range-pos-48", t.range_pos_48, scales),
        scaled_linear("fib-dist-236", t.fib_dist_236, scales),
        scaled_linear("fib-dist-382", t.fib_dist_382, scales),
        scaled_linear("fib-dist-500", t.fib_dist_500, scales),
        scaled_linear("fib-dist-618", t.fib_dist_618, scales),
        scaled_linear("fib-dist-786", t.fib_dist_786, scales),
    ]
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::encoding::thought_encoder::ThoughtASTKind;

    #[test]
    fn test_encode_fibonacci_facts_nonempty() {
        let c = Candle::default();
        let mut scales = HashMap::new();
        let facts = encode_fibonacci_facts(&c, &mut scales);
        assert_eq!(facts.len(), 8);
    }

    #[test]
    fn test_fib_dist_500() {
        let c = Candle::default();
        let mut scales = HashMap::new();
        let facts = encode_fibonacci_facts(&c, &mut scales);
        match &facts[5].kind {
            ThoughtASTKind::Bind(left, right) => {
                match (&left.kind, &right.kind) {
                    (ThoughtASTKind::Atom(name), ThoughtASTKind::Linear { value, .. }) => {
                        assert_eq!(name, "fib-dist-500");
                        // range_pos_48 = 0.6, so 0.6 - 0.5 = 0.1
                        assert!((value - 0.1).abs() < 1e-9);
                    }
                    _ => panic!("expected Bind(Atom, Linear)"),
                }
            }
            _ => panic!("expected Bind"),
        }
    }
}
