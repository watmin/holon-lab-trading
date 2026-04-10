/// Range-ratio, gaps, consecutive runs.

use crate::candle::Candle;
use crate::enums::ThoughtAST;

pub fn encode_price_action_facts(c: &Candle) -> Vec<ThoughtAST> {
    vec![
        // Range ratio: current range / prev range
        ThoughtAST::Log { name: "range-ratio".into(), value: c.range_ratio.max(0.001) },
        // Gap: signed — (open - prev close) / prev close
        ThoughtAST::Linear { name: "gap".into(), value: c.gap, scale: 0.05 },
        // Consecutive runs — how many in a row
        ThoughtAST::Linear { name: "consecutive-up".into(), value: c.consecutive_up, scale: 10.0 },
        ThoughtAST::Linear { name: "consecutive-down".into(), value: c.consecutive_down, scale: 10.0 },
    ]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_encode_price_action_facts_non_empty() {
        let c = Candle::default();
        let facts = encode_price_action_facts(&c);
        assert!(!facts.is_empty());
        assert_eq!(facts.len(), 4);
    }
}
