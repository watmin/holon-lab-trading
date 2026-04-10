/// Cloud position, TK cross.

use crate::candle::Candle;
use crate::enums::ThoughtAST;

pub fn encode_ichimoku_facts(c: &Candle) -> Vec<ThoughtAST> {
    let close = c.close;
    let cloud_top = c.cloud_top;
    let cloud_bottom = c.cloud_bottom;
    let cloud_width = cloud_top - cloud_bottom;

    // Cloud position: where is close relative to the cloud?
    let cloud_position = if close > cloud_top {
        // Above cloud — distance above as ratio
        if cloud_top == 0.0 { 0.0 } else { (close - cloud_top) / cloud_top }
    } else if close < cloud_bottom {
        // Below cloud — distance below as negative ratio
        if cloud_bottom == 0.0 { 0.0 } else { (close - cloud_bottom) / cloud_bottom }
    } else {
        // Inside cloud — position within [0, 1] centered at 0
        if cloud_width == 0.0 { 0.0 } else { 2.0 * ((close - cloud_bottom) / cloud_width) - 1.0 }
    };

    vec![
        // Cloud position — signed distance from cloud
        ThoughtAST::Linear { name: "cloud-position".into(), value: cloud_position, scale: 0.1 },
        // Cloud thickness — log because it can vary widely
        ThoughtAST::Log {
            name: "cloud-thickness".into(),
            value: 1.0 + if close == 0.0 { 0.0 } else { cloud_width / close },
        },
        // TK cross delta — signed change in tenkan-kijun spread
        ThoughtAST::Linear { name: "tk-cross-delta".into(), value: c.tk_cross_delta, scale: 0.01 },
        // Tenkan-kijun spread — current spread as ratio of price
        ThoughtAST::Linear {
            name: "tk-spread".into(),
            value: if close == 0.0 { 0.0 } else { (c.tenkan_sen - c.kijun_sen) / close },
            scale: 0.01,
        },
    ]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_encode_ichimoku_facts_non_empty() {
        let c = Candle::default();
        let facts = encode_ichimoku_facts(&c);
        assert!(!facts.is_empty());
        assert_eq!(facts.len(), 4);
    }
}
