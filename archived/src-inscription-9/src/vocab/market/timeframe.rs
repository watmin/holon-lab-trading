/// 1h/4h structure + narrative + inter-timeframe agreement.

use crate::candle::Candle;
use crate::enums::ThoughtAST;

pub fn encode_timeframe_facts(c: &Candle) -> Vec<ThoughtAST> {
    let tf_1h_range = c.tf_1h_high - c.tf_1h_low;
    let tf_1h_range_pos = if tf_1h_range == 0.0 { 0.5 } else { (c.tf_1h_close - c.tf_1h_low) / tf_1h_range };

    let tf_4h_range = c.tf_4h_high - c.tf_4h_low;
    let tf_4h_range_pos = if tf_4h_range == 0.0 { 0.5 } else { (c.tf_4h_close - c.tf_4h_low) / tf_4h_range };

    vec![
        // 1h timeframe
        ThoughtAST::Linear { name: "tf-1h-ret".into(), value: c.tf_1h_ret, scale: 0.05 },
        ThoughtAST::Linear { name: "tf-1h-body".into(), value: c.tf_1h_body, scale: 1.0 },
        ThoughtAST::Linear { name: "tf-1h-range-pos".into(), value: tf_1h_range_pos, scale: 1.0 },
        // 4h timeframe
        ThoughtAST::Linear { name: "tf-4h-ret".into(), value: c.tf_4h_ret, scale: 0.05 },
        ThoughtAST::Linear { name: "tf-4h-body".into(), value: c.tf_4h_body, scale: 1.0 },
        ThoughtAST::Linear { name: "tf-4h-range-pos".into(), value: tf_4h_range_pos, scale: 1.0 },
        // Inter-timeframe agreement — [0, 1]
        ThoughtAST::Linear { name: "tf-agreement".into(), value: c.tf_agreement, scale: 1.0 },
    ]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_encode_timeframe_facts_non_empty() {
        let c = Candle::default();
        let facts = encode_timeframe_facts(&c);
        assert!(!facts.is_empty());
        assert_eq!(facts.len(), 7);
    }
}
