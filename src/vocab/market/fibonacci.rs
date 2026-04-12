// vocab/market/fibonacci.rs — compiled from wat/vocab/market/fibonacci.wat
//
// Retracement level distances. Pure function: candle in, ASTs out.
// atoms: range-pos-12, range-pos-24, range-pos-48,
//        fib-dist-236, fib-dist-382, fib-dist-500, fib-dist-618, fib-dist-786

use std::collections::HashMap;
use crate::candle::Candle;
use crate::thought_encoder::{ThoughtAST, ToAst, round_to};
use crate::scale_tracker::{ScaleTracker, scaled_linear};

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

impl ToAst for FibonacciThought {
    fn to_ast(&self) -> ThoughtAST {
        ThoughtAST::Bundle(self.forms())
    }

    fn forms(&self) -> Vec<ThoughtAST> {
        vec![
            ThoughtAST::Linear { name: "range-pos-12".into(), value: self.range_pos_12, scale: 1.0 },
            ThoughtAST::Linear { name: "range-pos-24".into(), value: self.range_pos_24, scale: 1.0 },
            ThoughtAST::Linear { name: "range-pos-48".into(), value: self.range_pos_48, scale: 1.0 },
            ThoughtAST::Linear { name: "fib-dist-236".into(), value: self.fib_dist_236, scale: 1.0 },
            ThoughtAST::Linear { name: "fib-dist-382".into(), value: self.fib_dist_382, scale: 1.0 },
            ThoughtAST::Linear { name: "fib-dist-500".into(), value: self.fib_dist_500, scale: 1.0 },
            ThoughtAST::Linear { name: "fib-dist-618".into(), value: self.fib_dist_618, scale: 1.0 },
            ThoughtAST::Linear { name: "fib-dist-786".into(), value: self.fib_dist_786, scale: 1.0 },
        ]
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
