// vocab/market/timeframe.rs — compiled from wat/vocab/market/timeframe.wat
//
// 1h/4h structure + inter-timeframe agreement.
// Pure function: candle in, ASTs out.
// atoms: tf-1h-trend, tf-1h-ret, tf-4h-trend, tf-4h-ret,
//        tf-agreement, tf-5m-1h-align

use std::collections::HashMap;
use crate::types::candle::Candle;
use crate::encoding::thought_encoder::{ThoughtAST, round_to};
use crate::encoding::scale_tracker::{ScaleTracker, scaled_linear};

pub struct TimeframeThought {
    pub tf_1h_trend: f64,
    pub tf_1h_ret: f64,
    pub tf_4h_trend: f64,
    pub tf_4h_ret: f64,
    pub tf_agreement: f64,
    pub tf_5m_1h_align: f64,
}

impl TimeframeThought {
    pub fn from_candle(c: &Candle) -> Self {
        let signum_1h = if c.tf_1h_body > 0.0 {
            1.0
        } else if c.tf_1h_body < 0.0 {
            -1.0
        } else {
            0.0
        };
        let five_m_ret = (c.close - c.open) / c.close;
        Self {
            tf_1h_trend: round_to(c.tf_1h_body, 2),
            tf_1h_ret: round_to(c.tf_1h_ret, 4),
            tf_4h_trend: round_to(c.tf_4h_body, 2),
            tf_4h_ret: round_to(c.tf_4h_ret, 4),
            tf_agreement: round_to(c.tf_agreement, 2),
            tf_5m_1h_align: round_to(signum_1h * five_m_ret, 4),
        }
    }
}

pub fn encode_timeframe_facts(c: &Candle, scales: &mut HashMap<String, ScaleTracker>) -> Vec<ThoughtAST> {
    let t = TimeframeThought::from_candle(c);
    vec![
        scaled_linear("tf-1h-trend", t.tf_1h_trend, scales),
        scaled_linear("tf-1h-ret", t.tf_1h_ret, scales),
        scaled_linear("tf-4h-trend", t.tf_4h_trend, scales),
        scaled_linear("tf-4h-ret", t.tf_4h_ret, scales),
        scaled_linear("tf-agreement", t.tf_agreement, scales),
        scaled_linear("tf-5m-1h-align", t.tf_5m_1h_align, scales),
    ]
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::encoding::thought_encoder::ThoughtASTKind;

    #[test]
    fn test_encode_timeframe_facts_nonempty() {
        let c = Candle::default();
        let mut scales = HashMap::new();
        let facts = encode_timeframe_facts(&c, &mut scales);
        assert_eq!(facts.len(), 6);
    }

    #[test]
    fn test_tf_agreement() {
        let c = Candle::default();
        let mut scales = HashMap::new();
        let facts = encode_timeframe_facts(&c, &mut scales);
        match &facts[4].kind {
            ThoughtASTKind::Bind(left, right) => {
                match (&left.kind, &right.kind) {
                    (ThoughtASTKind::Atom(name), ThoughtASTKind::Linear { value, .. }) => {
                        assert_eq!(name, "tf-agreement");
                        assert_eq!(*value, 0.67);
                    }
                    _ => panic!("expected Bind(Atom, Linear)"),
                }
            }
            _ => panic!("expected Bind"),
        }
    }
}
