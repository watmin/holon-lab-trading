// vocab/market/ichimoku.rs — compiled from wat/vocab/market/ichimoku.wat
//
// Cloud position, TK cross, distances. Pure function: candle in, ASTs out.
// atoms: cloud-position, cloud-thickness, tk-cross-delta, tk-spread,
//        tenkan-dist, kijun-dist

use std::collections::HashMap;
use crate::types::candle::Candle;
use crate::encoding::thought_encoder::{ThoughtAST, round_to};
use crate::encoding::scale_tracker::{ScaleTracker, scaled_linear};

fn clamp(v: f64, lo: f64, hi: f64) -> f64 {
    v.max(lo).min(hi)
}

pub struct IchimokuThought {
    pub cloud_position: f64,
    pub cloud_thickness: f64,
    pub tk_cross_delta: f64,
    pub tk_spread: f64,
    pub tenkan_dist: f64,
    pub kijun_dist: f64,
}

impl IchimokuThought {
    pub fn from_candle(c: &Candle) -> Self {
        let close = c.close;
        let cloud_top = c.cloud_top;
        let cloud_bottom = c.cloud_bottom;
        let cloud_mid = (cloud_top + cloud_bottom) / 2.0;
        let cloud_width = cloud_top - cloud_bottom;
        let tenkan = c.tenkan_sen;
        let kijun = c.kijun_sen;

        Self {
            cloud_position: round_to(if cloud_width > 0.0 {
                clamp((close - cloud_mid) / cloud_width.max(close * 0.001), -1.0, 1.0)
            } else {
                clamp((close - cloud_mid) / (close * 0.01), -1.0, 1.0)
            }, 2),
            cloud_thickness: round_to((cloud_width / close).max(0.0001), 2),
            tk_cross_delta: round_to(clamp(c.tk_cross_delta, -1.0, 1.0), 2),
            tk_spread: round_to(clamp((tenkan - kijun) / (close * 0.01), -1.0, 1.0), 2),
            tenkan_dist: round_to(clamp((close - tenkan) / (close * 0.01), -1.0, 1.0), 2),
            kijun_dist: round_to(clamp((close - kijun) / (close * 0.01), -1.0, 1.0), 2),
        }
    }
}

pub fn encode_ichimoku_facts(c: &Candle, scales: &mut HashMap<String, ScaleTracker>) -> Vec<ThoughtAST> {
    let t = IchimokuThought::from_candle(c);
    vec![
        scaled_linear("cloud-position", t.cloud_position, scales),
        ThoughtAST::Bind(Box::new(ThoughtAST::Atom("cloud-thickness".into())), Box::new(ThoughtAST::Log { value: t.cloud_thickness })),
        scaled_linear("tk-cross-delta", t.tk_cross_delta, scales),
        scaled_linear("tk-spread", t.tk_spread, scales),
        scaled_linear("tenkan-dist", t.tenkan_dist, scales),
        scaled_linear("kijun-dist", t.kijun_dist, scales),
    ]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_encode_ichimoku_facts_nonempty() {
        let c = Candle::default();
        let mut scales = HashMap::new();
        let facts = encode_ichimoku_facts(&c, &mut scales);
        assert_eq!(facts.len(), 6);
    }

    #[test]
    fn test_cloud_position_above() {
        let c = Candle::default();
        let mut scales = HashMap::new();
        let facts = encode_ichimoku_facts(&c, &mut scales);
        match &facts[0] {
            ThoughtAST::Bind(left, right) => {
                match (left.as_ref(), right.as_ref()) {
                    (ThoughtAST::Atom(name), ThoughtAST::Linear { value, .. }) => {
                        assert_eq!(name, "cloud-position");
                        // close=42200, cloud_mid=41900, cloud_width=200
                        // (42200 - 41900) / 200 = 1.5 -> clamped to 1.0
                        assert_eq!(*value, 1.0);
                    }
                    _ => panic!("expected Bind(Atom, Linear)"),
                }
            }
            _ => panic!("expected Bind"),
        }
    }
}
