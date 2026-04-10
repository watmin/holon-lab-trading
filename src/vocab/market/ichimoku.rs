// vocab/market/ichimoku.rs — compiled from wat/vocab/market/ichimoku.wat
//
// Cloud position, TK cross, distances. Pure function: candle in, ASTs out.
// atoms: cloud-position, cloud-thickness, tk-cross-delta, tk-spread,
//        tenkan-dist, kijun-dist

use crate::candle::Candle;
use crate::thought_encoder::ThoughtAST;

fn clamp(v: f64, lo: f64, hi: f64) -> f64 {
    v.max(lo).min(hi)
}

pub fn encode_ichimoku_facts(c: &Candle) -> Vec<ThoughtAST> {
    let close = c.close;
    let cloud_top = c.cloud_top;
    let cloud_bottom = c.cloud_bottom;
    let cloud_mid = (cloud_top + cloud_bottom) / 2.0;
    let cloud_width = cloud_top - cloud_bottom;
    let tenkan = c.tenkan_sen;
    let kijun = c.kijun_sen;

    vec![
        // Cloud position: where price is relative to the cloud.
        ThoughtAST::Linear {
            name: "cloud-position".into(),
            value: if cloud_width > 0.0 {
                clamp(
                    (close - cloud_mid) / cloud_width.max(close * 0.001),
                    -1.0,
                    1.0,
                )
            } else {
                clamp((close - cloud_mid) / (close * 0.01), -1.0, 1.0)
            },
            scale: 1.0,
        },
        // Cloud thickness: width as percentage of price. Log-encoded.
        ThoughtAST::Log {
            name: "cloud-thickness".into(),
            value: (cloud_width / close).max(0.0001),
        },
        // TK cross delta: pre-computed. Signed. [-1, 1].
        ThoughtAST::Linear {
            name: "tk-cross-delta".into(),
            value: clamp(c.tk_cross_delta, -1.0, 1.0),
            scale: 1.0,
        },
        // TK spread: (tenkan - kijun) / price. Signed.
        ThoughtAST::Linear {
            name: "tk-spread".into(),
            value: clamp((tenkan - kijun) / (close * 0.01), -1.0, 1.0),
            scale: 1.0,
        },
        // Tenkan distance: (close - tenkan) / price. Signed percentage.
        ThoughtAST::Linear {
            name: "tenkan-dist".into(),
            value: clamp((close - tenkan) / (close * 0.01), -1.0, 1.0),
            scale: 1.0,
        },
        // Kijun distance: (close - kijun) / price. Signed percentage.
        ThoughtAST::Linear {
            name: "kijun-dist".into(),
            value: clamp((close - kijun) / (close * 0.01), -1.0, 1.0),
            scale: 1.0,
        },
    ]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_encode_ichimoku_facts_nonempty() {
        let c = Candle::default();
        let facts = encode_ichimoku_facts(&c);
        assert_eq!(facts.len(), 6);
    }

    #[test]
    fn test_cloud_position_above() {
        let c = Candle::default();
        let facts = encode_ichimoku_facts(&c);
        match &facts[0] {
            ThoughtAST::Linear { name, value, .. } => {
                assert_eq!(name, "cloud-position");
                // close=42200, cloud_mid=41900, cloud_width=200
                // (42200 - 41900) / 200 = 1.5 -> clamped to 1.0
                assert_eq!(*value, 1.0);
            }
            _ => panic!("expected Linear"),
        }
    }
}
