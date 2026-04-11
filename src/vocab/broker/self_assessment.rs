/// Broker self-assessment vocabulary. The machine thinks about itself.
///
/// Seven atoms about the broker's own performance and state.
/// These compose with the market+exit thought to give the reckoner
/// the full picture: market context + exit context + self-assessment.

use crate::thought_encoder::{round_to, ThoughtAST};

/// Encode broker self-assessment facts.
///
/// grace_rate: grace / (grace + violence), 0.0 when no experience
/// avg_paper_duration: running average candle age of resolved papers
/// paper_count: current number of active papers
/// trail_distance: the trail distance on the most recent paper
/// stop_distance: the stop distance on the most recent paper
/// recalib_freshness: observations since last reckoner recalibration
/// avg_excursion: running average of buy+sell excursion on resolution
pub fn encode_broker_self_facts(
    grace_rate: f64,
    avg_paper_duration: f64,
    paper_count: usize,
    trail_distance: f64,
    stop_distance: f64,
    recalib_freshness: usize,
    avg_excursion: f64,
) -> Vec<ThoughtAST> {
    let mut facts = Vec::with_capacity(7);

    // Am I winning? Linear [0, 1]
    facts.push(ThoughtAST::linear("grace-rate", round_to(grace_rate, 2), 1.0));

    // How long do my papers live? Log-encoded (unbounded positive)
    if avg_paper_duration > 0.0 {
        facts.push(ThoughtAST::log("paper-duration-avg", round_to(avg_paper_duration, 1)));
    }

    // How many open papers? Log-encoded
    if paper_count > 0 {
        facts.push(ThoughtAST::log("paper-count", paper_count as f64));
    }

    // How tight are my stops? Log-encoded
    if trail_distance > 0.0 {
        facts.push(ThoughtAST::log("trail-distance", round_to(trail_distance, 4)));
    }

    // How wide is my safety? Log-encoded
    if stop_distance > 0.0 {
        facts.push(ThoughtAST::log("stop-distance", round_to(stop_distance, 4)));
    }

    // How stale is my discriminant? Log-encoded
    if recalib_freshness > 0 {
        facts.push(ThoughtAST::log("recalib-freshness", recalib_freshness as f64));
    }

    // How far does price move for me? Log-encoded
    if avg_excursion > 0.0 {
        facts.push(ThoughtAST::log("excursion-avg", round_to(avg_excursion, 4)));
    }

    facts
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_encode_broker_self_facts_nonempty() {
        let facts = encode_broker_self_facts(0.55, 25.0, 20, 0.015, 0.030, 150, 0.005);
        assert!(!facts.is_empty());
        // Should have all 7 facts
        assert_eq!(facts.len(), 7);
    }

    #[test]
    fn test_encode_broker_self_facts_cold_start() {
        let facts = encode_broker_self_facts(0.0, 0.0, 0, 0.0, 0.0, 0, 0.0);
        // grace-rate is always emitted (0.0 is valid), rest are skipped
        assert_eq!(facts.len(), 1);
    }
}
