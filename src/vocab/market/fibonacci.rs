// vocab/market/fibonacci.rs — compiled from wat/vocab/market/fibonacci.wat
//
// Retracement level distances. Pure function: candle in, ASTs out.
// atoms: range-pos-12, range-pos-24, range-pos-48,
//        fib-dist-236, fib-dist-382, fib-dist-500, fib-dist-618, fib-dist-786

use std::collections::HashMap;
use crate::types::candle::Candle;
use crate::encoding::thought_encoder::{ThoughtAST, ToAst, round_to};
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

impl ToAst for FibonacciThought {
    fn to_ast(&self) -> ThoughtAST {
        ThoughtAST::Bundle(self.forms())
    }

    fn forms(&self) -> Vec<ThoughtAST> {
        vec![
            ThoughtAST::Bind(Box::new(ThoughtAST::Atom("range-pos-12".into())), Box::new(ThoughtAST::Linear { value: self.range_pos_12, scale: 1.0 })),
            ThoughtAST::Bind(Box::new(ThoughtAST::Atom("range-pos-24".into())), Box::new(ThoughtAST::Linear { value: self.range_pos_24, scale: 1.0 })),
            ThoughtAST::Bind(Box::new(ThoughtAST::Atom("range-pos-48".into())), Box::new(ThoughtAST::Linear { value: self.range_pos_48, scale: 1.0 })),
            ThoughtAST::Bind(Box::new(ThoughtAST::Atom("fib-dist-236".into())), Box::new(ThoughtAST::Linear { value: self.fib_dist_236, scale: 1.0 })),
            ThoughtAST::Bind(Box::new(ThoughtAST::Atom("fib-dist-382".into())), Box::new(ThoughtAST::Linear { value: self.fib_dist_382, scale: 1.0 })),
            ThoughtAST::Bind(Box::new(ThoughtAST::Atom("fib-dist-500".into())), Box::new(ThoughtAST::Linear { value: self.fib_dist_500, scale: 1.0 })),
            ThoughtAST::Bind(Box::new(ThoughtAST::Atom("fib-dist-618".into())), Box::new(ThoughtAST::Linear { value: self.fib_dist_618, scale: 1.0 })),
            ThoughtAST::Bind(Box::new(ThoughtAST::Atom("fib-dist-786".into())), Box::new(ThoughtAST::Linear { value: self.fib_dist_786, scale: 1.0 })),
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
            ThoughtAST::Bind(left, right) => {
                match (left.as_ref(), right.as_ref()) {
                    (ThoughtAST::Atom(name), ThoughtAST::Linear { value, .. }) => {
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
