/// Broker self-assessment vocabulary. The machine thinks about itself.
///
/// Seven atoms about the broker's own performance and state.
/// These compose with the market+exit thought to give the reckoner
/// the full picture: market context + exit context + self-assessment.

use std::collections::HashMap;
use crate::encoding::thought_encoder::{round_to, ThoughtAST};
use crate::encoding::scale_tracker::{ScaleTracker, scaled_linear};

/// Encode broker self-assessment facts.
pub fn encode_broker_self_facts(
    grace_rate: f64,
    avg_paper_duration: f64,
    paper_count: usize,
    trail_distance: f64,
    stop_distance: f64,
    recalib_freshness: usize,
    avg_excursion: f64,
    scales: &mut HashMap<String, ScaleTracker>,
) -> Vec<ThoughtAST> {
    let mut facts = Vec::with_capacity(7);

    // Am I winning? Linear [0, 1] — learned scale
    facts.push(scaled_linear("grace-rate", round_to(grace_rate, 2), scales));

    // How long do my papers live? Log-encoded (unbounded positive)
    if avg_paper_duration > 0.0 {
        facts.push(ThoughtAST::Bind(
            Box::new(ThoughtAST::Atom("paper-duration-avg".into())),
            Box::new(ThoughtAST::Log { value: round_to(avg_paper_duration, 1) }),
        ));
    }

    // How many open papers? Log-encoded
    if paper_count > 0 {
        facts.push(ThoughtAST::Bind(
            Box::new(ThoughtAST::Atom("paper-count".into())),
            Box::new(ThoughtAST::Log { value: paper_count as f64 }),
        ));
    }

    // How tight are my stops? Log-encoded
    if trail_distance > 0.0 {
        facts.push(ThoughtAST::Bind(
            Box::new(ThoughtAST::Atom("trail-distance".into())),
            Box::new(ThoughtAST::Log { value: round_to(trail_distance, 4) }),
        ));
    }

    // How wide is my safety? Log-encoded
    if stop_distance > 0.0 {
        facts.push(ThoughtAST::Bind(
            Box::new(ThoughtAST::Atom("stop-distance".into())),
            Box::new(ThoughtAST::Log { value: round_to(stop_distance, 4) }),
        ));
    }

    // How stale is my discriminant? Log-encoded
    if recalib_freshness > 0 {
        facts.push(ThoughtAST::Bind(
            Box::new(ThoughtAST::Atom("recalib-freshness".into())),
            Box::new(ThoughtAST::Log { value: recalib_freshness as f64 }),
        ));
    }

    // How far does price move for me? Log-encoded
    if avg_excursion > 0.0 {
        facts.push(ThoughtAST::Bind(
            Box::new(ThoughtAST::Atom("excursion-avg".into())),
            Box::new(ThoughtAST::Log { value: round_to(avg_excursion, 4) }),
        ));
    }

    facts
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_encode_broker_self_facts_nonempty() {
        let mut scales = HashMap::new();
        let facts = encode_broker_self_facts(0.55, 25.0, 20, 0.015, 0.030, 150, 0.005, &mut scales);
        assert!(!facts.is_empty());
        // Should have all 7 facts
        assert_eq!(facts.len(), 7);
    }

    #[test]
    fn test_encode_broker_self_facts_cold_start() {
        let mut scales = HashMap::new();
        let facts = encode_broker_self_facts(0.0, 0.0, 0, 0.0, 0.0, 0, 0.0, &mut scales);
        // grace-rate is always emitted (0.0 is valid), rest are skipped
        assert_eq!(facts.len(), 1);
    }

}
