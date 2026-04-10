// vocab/market/timeframe.rs — compiled from wat/vocab/market/timeframe.wat
//
// 1h/4h structure + inter-timeframe agreement.
// Pure function: candle in, ASTs out.
// atoms: tf-1h-trend, tf-1h-ret, tf-4h-trend, tf-4h-ret,
//        tf-agreement, tf-5m-1h-align

use crate::candle::Candle;
use crate::thought_encoder::ThoughtAST;

pub fn encode_timeframe_facts(c: &Candle) -> Vec<ThoughtAST> {
    // 5m-1h alignment: sign of 1h body * 5m return direction
    let signum_1h = if c.tf_1h_body > 0.0 {
        1.0
    } else if c.tf_1h_body < 0.0 {
        -1.0
    } else {
        0.0
    };
    let five_m_ret = (c.close - c.open) / c.close;

    vec![
        // 1h trend: body / range of the 1h candle. Signed. [-1, 1].
        ThoughtAST::Linear {
            name: "tf-1h-trend".into(),
            value: c.tf_1h_body,
            scale: 1.0,
        },
        // 1h return: signed percentage return over 1h.
        ThoughtAST::Linear {
            name: "tf-1h-ret".into(),
            value: c.tf_1h_ret,
            scale: 0.1,
        },
        // 4h trend: body / range of the 4h candle. Signed. [-1, 1].
        ThoughtAST::Linear {
            name: "tf-4h-trend".into(),
            value: c.tf_4h_body,
            scale: 1.0,
        },
        // 4h return: signed percentage return over 4h.
        ThoughtAST::Linear {
            name: "tf-4h-ret".into(),
            value: c.tf_4h_ret,
            scale: 0.1,
        },
        // Timeframe agreement: [0, 1].
        ThoughtAST::Linear {
            name: "tf-agreement".into(),
            value: c.tf_agreement,
            scale: 1.0,
        },
        // 5m-1h alignment: signed agreement between 5m direction and 1h trend.
        ThoughtAST::Linear {
            name: "tf-5m-1h-align".into(),
            value: signum_1h * five_m_ret,
            scale: 0.1,
        },
    ]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_encode_timeframe_facts_nonempty() {
        let c = Candle::default();
        let facts = encode_timeframe_facts(&c);
        assert_eq!(facts.len(), 6);
    }

    #[test]
    fn test_tf_agreement() {
        let c = Candle::default();
        let facts = encode_timeframe_facts(&c);
        match &facts[4] {
            ThoughtAST::Linear { name, value, .. } => {
                assert_eq!(name, "tf-agreement");
                assert_eq!(*value, 0.67);
            }
            _ => panic!("expected Linear"),
        }
    }
}
