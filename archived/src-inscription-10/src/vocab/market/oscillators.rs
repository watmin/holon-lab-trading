// vocab/market/oscillators.rs — compiled from wat/vocab/market/oscillators.wat
//
// Oscillator positions as scalars. Pure function: candle in, ASTs out.
// atoms: rsi, cci, mfi, williams-r, roc-1, roc-3, roc-6, roc-12

use crate::candle::Candle;
use crate::thought_encoder::ThoughtAST;

pub fn encode_oscillator_facts(c: &Candle) -> Vec<ThoughtAST> {
    vec![
        // RSI: [0, 1] — Wilder's formula. Naturally bounded.
        ThoughtAST::Linear {
            name: "rsi".into(),
            value: c.rsi,
            scale: 1.0,
        },
        // CCI: unbounded but typically [-300, 300]. Normalize to [-1, 1].
        ThoughtAST::Linear {
            name: "cci".into(),
            value: c.cci / 300.0,
            scale: 1.0,
        },
        // MFI: [0, 1] — money flow index. Same range as RSI.
        ThoughtAST::Linear {
            name: "mfi".into(),
            value: c.mfi / 100.0,
            scale: 1.0,
        },
        // Williams %R: [-100, 0] raw. Normalize to [0, 1].
        ThoughtAST::Linear {
            name: "williams-r".into(),
            value: (c.williams_r + 100.0) / 100.0,
            scale: 1.0,
        },
        // Rate of change: unbounded ratio. Log-encoded.
        ThoughtAST::Log {
            name: "roc-1".into(),
            value: 1.0 + c.roc_1,
        },
        ThoughtAST::Log {
            name: "roc-3".into(),
            value: 1.0 + c.roc_3,
        },
        ThoughtAST::Log {
            name: "roc-6".into(),
            value: 1.0 + c.roc_6,
        },
        ThoughtAST::Log {
            name: "roc-12".into(),
            value: 1.0 + c.roc_12,
        },
    ]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_encode_oscillator_facts_nonempty() {
        let c = Candle::default();
        let facts = encode_oscillator_facts(&c);
        assert_eq!(facts.len(), 8);
    }

    #[test]
    fn test_rsi_value() {
        let c = Candle::default();
        let facts = encode_oscillator_facts(&c);
        match &facts[0] {
            ThoughtAST::Linear { name, value, .. } => {
                assert_eq!(name, "rsi");
                assert_eq!(*value, 55.0);
            }
            _ => panic!("expected Linear"),
        }
    }
}
