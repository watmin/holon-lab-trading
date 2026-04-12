// vocab/market/keltner.rs — compiled from wat/vocab/market/keltner.wat
//
// Channel positions and squeeze. Pure function: candle in, ASTs out.
// atoms: bb-pos, bb-width, kelt-pos, squeeze, kelt-upper-dist, kelt-lower-dist

use crate::candle::Candle;
use crate::thought_encoder::{ThoughtAST, ToAst, round_to};

pub struct KeltnerThought {
    pub bb_pos: f64,
    pub bb_width: f64,
    pub kelt_pos: f64,
    pub squeeze: f64,
    pub kelt_upper_dist: f64,
    pub kelt_lower_dist: f64,
}

impl KeltnerThought {
    pub fn from_candle(c: &Candle) -> Self {
        Self {
            bb_pos: round_to(c.bb_pos, 2),
            bb_width: round_to(c.bb_width.max(0.001), 2),
            kelt_pos: round_to(c.kelt_pos, 2),
            squeeze: round_to(c.squeeze, 2),
            kelt_upper_dist: round_to((c.close - c.kelt_upper) / c.close, 4),
            kelt_lower_dist: round_to((c.close - c.kelt_lower) / c.close, 4),
        }
    }
}

impl ToAst for KeltnerThought {
    fn to_ast(&self) -> ThoughtAST {
        ThoughtAST::Bundle(self.forms())
    }

    fn forms(&self) -> Vec<ThoughtAST> {
        vec![
            ThoughtAST::Linear { name: "bb-pos".into(), value: self.bb_pos, scale: 1.0 },
            ThoughtAST::Log { name: "bb-width".into(), value: self.bb_width },
            ThoughtAST::Linear { name: "kelt-pos".into(), value: self.kelt_pos, scale: 1.0 },
            ThoughtAST::Linear { name: "squeeze".into(), value: self.squeeze, scale: 1.0 },
            ThoughtAST::Linear { name: "kelt-upper-dist".into(), value: self.kelt_upper_dist, scale: 0.1 },
            ThoughtAST::Linear { name: "kelt-lower-dist".into(), value: self.kelt_lower_dist, scale: 0.1 },
        ]
    }
}

pub fn encode_keltner_facts(c: &Candle) -> Vec<ThoughtAST> {
    KeltnerThought::from_candle(c).forms()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_encode_keltner_facts_nonempty() {
        let c = Candle::default();
        let facts = encode_keltner_facts(&c);
        assert_eq!(facts.len(), 6);
    }

    #[test]
    fn test_squeeze_value() {
        let c = Candle::default();
        let facts = encode_keltner_facts(&c);
        match &facts[3] {
            ThoughtAST::Linear { name, value, .. } => {
                assert_eq!(name, "squeeze");
                assert_eq!(*value, 0.95);
            }
            _ => panic!("expected Linear"),
        }
    }
}
