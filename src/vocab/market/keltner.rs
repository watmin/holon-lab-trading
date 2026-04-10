/// Channel position, BB position, squeeze.

use crate::candle::Candle;
use crate::enums::ThoughtAST;

pub fn encode_keltner_facts(c: &Candle) -> Vec<ThoughtAST> {
    let bb_pos = c.bb_pos;

    let mut facts = vec![
        // Keltner position — where in the channel [0, 1]
        ThoughtAST::Linear { name: "kelt-pos".into(), value: c.kelt_pos, scale: 1.0 },
        // Bollinger position — where in the bands [0, 1]
        ThoughtAST::Linear { name: "bb-pos".into(), value: bb_pos, scale: 1.0 },
        // Squeeze — BB width / Keltner width ratio
        ThoughtAST::Log { name: "squeeze".into(), value: c.squeeze.max(0.001) },
    ];

    // Conditional: beyond the bands or inside
    if bb_pos > 1.0 {
        facts.push(ThoughtAST::Log {
            name: "bb-breakout-upper".into(),
            value: 1.0 + (bb_pos - 1.0),
        });
    } else if bb_pos < 0.0 {
        facts.push(ThoughtAST::Log {
            name: "bb-breakout-lower".into(),
            value: 1.0 + bb_pos.abs(),
        });
    }

    // Bollinger width — how volatile is the market
    facts.push(ThoughtAST::Log { name: "bb-width".into(), value: c.bb_width.max(0.001) });

    facts
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_encode_keltner_facts_non_empty() {
        let c = Candle::default();
        let facts = encode_keltner_facts(&c);
        assert!(!facts.is_empty());
        // Default bb_pos = 0.6, so no breakout — 3 base + 1 bb_width = 4
        assert_eq!(facts.len(), 4);
    }

    #[test]
    fn test_encode_keltner_facts_breakout_upper() {
        let mut c = Candle::default();
        c.bb_pos = 1.5;
        let facts = encode_keltner_facts(&c);
        // 3 base + 1 breakout + 1 bb_width = 5
        assert_eq!(facts.len(), 5);
    }

    #[test]
    fn test_encode_keltner_facts_breakout_lower() {
        let mut c = Candle::default();
        c.bb_pos = -0.3;
        let facts = encode_keltner_facts(&c);
        assert_eq!(facts.len(), 5);
    }
}
