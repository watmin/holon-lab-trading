/// OBV, VWAP, MFI, buying/selling pressure.

use crate::candle::Candle;
use crate::enums::ThoughtAST;

pub fn encode_flow_facts(c: &Candle) -> Vec<ThoughtAST> {
    vec![
        // OBV slope — direction and magnitude of on-balance volume
        ThoughtAST::Linear { name: "obv-slope".into(), value: c.obv_slope_12, scale: 1.0 },
        // Volume acceleration — how unusual is current volume
        ThoughtAST::Log { name: "volume-accel".into(), value: c.volume_accel.max(0.001) },
        // VWAP distance — signed: positive = above VWAP, negative = below
        ThoughtAST::Linear { name: "vwap-distance".into(), value: c.vwap_distance, scale: 0.1 },
        // MFI — money flow index [0, 1]
        ThoughtAST::Linear { name: "mfi".into(), value: c.mfi, scale: 1.0 },
    ]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_encode_flow_facts_non_empty() {
        let c = Candle::default();
        let facts = encode_flow_facts(&c);
        assert!(!facts.is_empty());
        assert_eq!(facts.len(), 4);
    }
}
