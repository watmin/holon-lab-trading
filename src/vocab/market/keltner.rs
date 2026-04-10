// vocab/market/keltner.rs — compiled from wat/vocab/market/keltner.wat
//
// Channel positions and squeeze. Pure function: candle in, ASTs out.
// atoms: bb-pos, bb-width, kelt-pos, squeeze, kelt-upper-dist, kelt-lower-dist

use crate::candle::Candle;
use crate::thought_encoder::ThoughtAST;

pub fn encode_keltner_facts(c: &Candle) -> Vec<ThoughtAST> {
    vec![
        // Bollinger position: [-1, 1].
        ThoughtAST::Linear {
            name: "bb-pos".into(),
            value: c.bb_pos,
            scale: 1.0,
        },
        // Bollinger width: unbounded positive. Log-encoded.
        ThoughtAST::Log {
            name: "bb-width".into(),
            value: c.bb_width.max(0.001),
        },
        // Keltner position: [-1, 1].
        ThoughtAST::Linear {
            name: "kelt-pos".into(),
            value: c.kelt_pos,
            scale: 1.0,
        },
        // Squeeze: [0, 1].
        ThoughtAST::Linear {
            name: "squeeze".into(),
            value: c.squeeze,
            scale: 1.0,
        },
        // Keltner upper distance: signed percentage of price.
        ThoughtAST::Linear {
            name: "kelt-upper-dist".into(),
            value: (c.close - c.kelt_upper) / c.close,
            scale: 0.1,
        },
        // Keltner lower distance: signed percentage of price.
        ThoughtAST::Linear {
            name: "kelt-lower-dist".into(),
            value: (c.close - c.kelt_lower) / c.close,
            scale: 0.1,
        },
    ]
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
