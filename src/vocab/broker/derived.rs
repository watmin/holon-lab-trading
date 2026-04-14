/// Broker derived-thought vocabulary. Cross-cutting ratios that no single
/// observer can compute — they require context from both market and exit
/// observers plus the broker's own state.
///
/// 11 atoms total. Pure function. No state, no pipes.
///
/// Per Beckman:
///   - risk-reward-ratio → Log (multiplicative structure)
///   - conviction-vol → Log(abs) + sign as separate atom (avoids saturation)

use std::collections::HashMap;
use crate::encoding::thought_encoder::{round_to, ThoughtAST};
use crate::encoding::scale_tracker::{ScaleTracker, scaled_linear};

/// Encode 11 derived atoms from cross-cutting broker context.
/// Pure function — no state, no side effects.
pub fn encode_broker_derived_facts(
    trail: f64,
    stop: f64,
    atr_ratio: f64,
    signed_conviction: f64,
    exit_grace_rate: f64,
    exit_avg_residue: f64,
    broker_grace_rate: f64,
    paper_count: usize,
    paper_duration: f64,
    excursion_avg: f64,
    market_anomaly_norm: f64,
    exit_anomaly_norm: f64,
    scales: &mut HashMap<String, ScaleTracker>,
) -> Vec<ThoughtAST> {
    vec![
        // Distance relative to volatility (2 atoms)
        ThoughtAST::Bind(
            Box::new(ThoughtAST::Atom("trail-atr-multiple".into())),
            Box::new(ThoughtAST::Log { value: round_to(trail / atr_ratio.max(0.001), 2) }),
        ),
        ThoughtAST::Bind(
            Box::new(ThoughtAST::Atom("stop-atr-multiple".into())),
            Box::new(ThoughtAST::Log { value: round_to(stop / atr_ratio.max(0.001), 2) }),
        ),
        // Risk-reward ratio (1 atom) — Log per Beckman
        ThoughtAST::Bind(
            Box::new(ThoughtAST::Atom("risk-reward-ratio".into())),
            Box::new(ThoughtAST::Log { value: round_to(trail / stop.max(0.001), 2) }),
        ),
        // Conviction-volatility interaction (2 atoms) — split per Beckman
        ThoughtAST::Bind(
            Box::new(ThoughtAST::Atom("conviction-vol-magnitude".into())),
            Box::new(ThoughtAST::Log { value: round_to(
                (signed_conviction.abs() / atr_ratio.max(0.001)).max(0.001),
                2,
            ) }),
        ),
        scaled_linear("conviction-vol-sign", if signed_conviction >= 0.0 { 1.0 } else { -1.0 }, scales),
        // Exit confidence (1 atom)
        scaled_linear("exit-confidence", round_to(exit_grace_rate * exit_avg_residue.max(0.001), 4), scales),
        // Self-exit agreement (1 atom)
        scaled_linear("self-exit-agreement", round_to(broker_grace_rate - exit_grace_rate, 2), scales),
        // Activity rate (1 atom)
        ThoughtAST::Bind(
            Box::new(ThoughtAST::Atom("activity-rate".into())),
            Box::new(ThoughtAST::Log { value: round_to(paper_count.max(1) as f64 / paper_duration.max(1.0), 2) }),
        ),
        // Excursion-trail ratio (1 atom)
        scaled_linear("excursion-trail-ratio", round_to(excursion_avg / trail.max(0.001), 2), scales),
        // Signal strength (2 atoms)
        ThoughtAST::Bind(
            Box::new(ThoughtAST::Atom("market-signal-strength".into())),
            Box::new(ThoughtAST::Log { value: round_to(market_anomaly_norm.max(0.001), 2) }),
        ),
        ThoughtAST::Bind(
            Box::new(ThoughtAST::Atom("exit-signal-strength".into())),
            Box::new(ThoughtAST::Log { value: round_to(exit_anomaly_norm.max(0.001), 2) }),
        ),
    ]
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample_facts() -> Vec<ThoughtAST> {
        let mut scales = HashMap::new();
        encode_broker_derived_facts(
            0.015, 0.030, 0.012, 0.25, 0.55, 0.005, 0.60, 20, 25.0, 0.008, 3.5, 2.1, &mut scales,
        )
    }

    #[test]
    fn test_count() {
        assert_eq!(sample_facts().len(), 11);
    }

    /// Helper: extract the atom name from a Bind(Atom(name), _) node.
    fn atom_name(ast: &ThoughtAST) -> &str {
        match ast {
            ThoughtAST::Bind(left, _) => match left.as_ref() {
                ThoughtAST::Atom(name) => name.as_str(),
                _ => panic!("expected Bind(Atom, _)"),
            },
            _ => panic!("expected Bind"),
        }
    }

    /// Helper: extract the scalar value from a Bind(_, Log{value}) node.
    fn log_value(ast: &ThoughtAST) -> f64 {
        match ast {
            ThoughtAST::Bind(_, right) => match right.as_ref() {
                ThoughtAST::Log { value } => *value,
                _ => panic!("expected Bind(_, Log)"),
            },
            _ => panic!("expected Bind"),
        }
    }

    /// Helper: extract the scalar value from a Bind(_, Linear{value, ..}) node.
    fn linear_value(ast: &ThoughtAST) -> f64 {
        match ast {
            ThoughtAST::Bind(_, right) => match right.as_ref() {
                ThoughtAST::Linear { value, .. } => *value,
                _ => panic!("expected Bind(_, Linear)"),
            },
            _ => panic!("expected Bind"),
        }
    }

    #[test]
    fn test_names() {
        let facts = sample_facts();
        let names: Vec<&str> = facts.iter().map(|f| atom_name(f)).collect();
        assert_eq!(
            names,
            vec![
                "trail-atr-multiple",
                "stop-atr-multiple",
                "risk-reward-ratio",
                "conviction-vol-magnitude",
                "conviction-vol-sign",
                "exit-confidence",
                "self-exit-agreement",
                "activity-rate",
                "excursion-trail-ratio",
                "market-signal-strength",
                "exit-signal-strength",
            ]
        );
    }

    #[test]
    fn test_trail_atr_multiple() {
        let facts = sample_facts();
        assert_eq!(log_value(&facts[0]), 1.25);
    }

    #[test]
    fn test_stop_atr_multiple() {
        let facts = sample_facts();
        assert_eq!(log_value(&facts[1]), 2.5);
    }

    #[test]
    fn test_risk_reward_ratio() {
        let facts = sample_facts();
        assert_eq!(log_value(&facts[2]), 0.5);
    }

    #[test]
    fn test_conviction_vol_magnitude() {
        let facts = sample_facts();
        assert_eq!(log_value(&facts[3]), 20.83);
    }

    #[test]
    fn test_conviction_vol_sign_positive() {
        let facts = sample_facts();
        assert_eq!(linear_value(&facts[4]), 1.0);
    }

    #[test]
    fn test_conviction_vol_sign_negative() {
        let mut scales = HashMap::new();
        let facts = encode_broker_derived_facts(
            0.015, 0.030, 0.012, -0.25, 0.55, 0.005, 0.60, 20, 25.0, 0.008, 3.5, 2.1, &mut scales,
        );
        assert_eq!(linear_value(&facts[4]), -1.0);
    }

    #[test]
    fn test_exit_confidence() {
        let facts = sample_facts();
        assert_eq!(linear_value(&facts[5]), 0.0);
    }

    #[test]
    fn test_self_exit_agreement() {
        let facts = sample_facts();
        assert_eq!(linear_value(&facts[6]), 0.05);
    }

    #[test]
    fn test_activity_rate() {
        let facts = sample_facts();
        assert_eq!(log_value(&facts[7]), 0.8);
    }

    #[test]
    fn test_excursion_trail_ratio() {
        let facts = sample_facts();
        assert_eq!(linear_value(&facts[8]), 0.53);
    }

    #[test]
    fn test_market_signal_strength() {
        let facts = sample_facts();
        assert_eq!(log_value(&facts[9]), 3.5);
    }

    #[test]
    fn test_exit_signal_strength() {
        let facts = sample_facts();
        assert_eq!(log_value(&facts[10]), 2.1);
    }

    #[test]
    fn test_zero_atr_ratio_clamped() {
        let mut scales = HashMap::new();
        let facts = encode_broker_derived_facts(
            0.015, 0.030, 0.0, 0.25, 0.55, 0.005, 0.60, 20, 25.0, 0.008, 3.5, 2.1, &mut scales,
        );
        assert_eq!(log_value(&facts[0]), 15.0);
    }

    #[test]
    fn test_zero_paper_count_clamped() {
        let mut scales = HashMap::new();
        let facts = encode_broker_derived_facts(
            0.015, 0.030, 0.012, 0.25, 0.55, 0.005, 0.60, 0, 25.0, 0.008, 3.5, 2.1, &mut scales,
        );
        assert_eq!(log_value(&facts[7]), 0.04);
    }

    #[test]
    fn test_all_log_types_correct() {
        let facts = sample_facts();
        // Log atoms: 0,1,2,3,7,9,10
        for i in [0, 1, 2, 3, 7, 9, 10] {
            match &facts[i] {
                ThoughtAST::Bind(_, right) => assert!(
                    matches!(right.as_ref(), ThoughtAST::Log { .. }),
                    "fact {} should be Bind(_, Log), got {:?}", i, facts[i]
                ),
                _ => panic!("fact {} should be Bind, got {:?}", i, facts[i]),
            }
        }
        // Linear atoms: 4,5,6,8
        for i in [4, 5, 6, 8] {
            match &facts[i] {
                ThoughtAST::Bind(_, right) => assert!(
                    matches!(right.as_ref(), ThoughtAST::Linear { .. }),
                    "fact {} should be Bind(_, Linear), got {:?}", i, facts[i]
                ),
                _ => panic!("fact {} should be Bind, got {:?}", i, facts[i]),
            }
        }
    }
}
