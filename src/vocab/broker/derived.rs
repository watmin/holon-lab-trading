/// Broker derived-thought vocabulary. Cross-cutting ratios that no single
/// observer can compute — they require context from both market and exit
/// observers plus the broker's own state.
///
/// 11 atoms total. Pure function. No state, no pipes.
///
/// Per Beckman:
///   - risk-reward-ratio → Log (multiplicative structure)
///   - conviction-vol → Log(abs) + sign as separate atom (avoids saturation)

use crate::thought_encoder::{round_to, ThoughtAST, ToAst};

/// Typed struct for broker derived facts.
pub struct BrokerDerivedThought {
    pub trail: f64,
    pub stop: f64,
    pub atr_ratio: f64,
    pub signed_conviction: f64,
    pub exit_grace_rate: f64,
    pub exit_avg_residue: f64,
    pub broker_grace_rate: f64,
    pub paper_count: usize,
    pub paper_duration: f64,
    pub excursion_avg: f64,
    pub market_anomaly_norm: f64,
    pub exit_anomaly_norm: f64,
}

impl BrokerDerivedThought {
    pub fn new(
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
    ) -> Self {
        Self {
            trail,
            stop,
            atr_ratio,
            signed_conviction,
            exit_grace_rate,
            exit_avg_residue,
            broker_grace_rate,
            paper_count,
            paper_duration,
            excursion_avg,
            market_anomaly_norm,
            exit_anomaly_norm,
        }
    }
}

impl ToAst for BrokerDerivedThought {
    fn to_ast(&self) -> ThoughtAST {
        ThoughtAST::Bundle(self.forms())
    }

    fn forms(&self) -> Vec<ThoughtAST> {
        encode_broker_derived_facts(
            self.trail,
            self.stop,
            self.atr_ratio,
            self.signed_conviction,
            self.exit_grace_rate,
            self.exit_avg_residue,
            self.broker_grace_rate,
            self.paper_count,
            self.paper_duration,
            self.excursion_avg,
            self.market_anomaly_norm,
            self.exit_anomaly_norm,
        )
    }
}

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
) -> Vec<ThoughtAST> {
    vec![
        // Distance relative to volatility (2 atoms)
        ThoughtAST::Log {
            name: "trail-atr-multiple".into(),
            value: round_to(trail / atr_ratio.max(0.001), 2),
        },
        ThoughtAST::Log {
            name: "stop-atr-multiple".into(),
            value: round_to(stop / atr_ratio.max(0.001), 2),
        },
        // Risk-reward ratio (1 atom) — Log per Beckman
        ThoughtAST::Log {
            name: "risk-reward-ratio".into(),
            value: round_to(trail / stop.max(0.001), 2),
        },
        // Conviction-volatility interaction (2 atoms) — split per Beckman
        ThoughtAST::Log {
            name: "conviction-vol-magnitude".into(),
            value: round_to(
                (signed_conviction.abs() / atr_ratio.max(0.001)).max(0.001),
                2,
            ),
        },
        ThoughtAST::Linear {
            name: "conviction-vol-sign".into(),
            value: if signed_conviction >= 0.0 { 1.0 } else { -1.0 },
            scale: 1.0,
        },
        // Exit confidence (1 atom)
        ThoughtAST::Linear {
            name: "exit-confidence".into(),
            value: round_to(exit_grace_rate * exit_avg_residue.max(0.001), 4),
            scale: 1.0,
        },
        // Self-exit agreement (1 atom)
        ThoughtAST::Linear {
            name: "self-exit-agreement".into(),
            value: round_to(broker_grace_rate - exit_grace_rate, 2),
            scale: 1.0,
        },
        // Activity rate (1 atom)
        ThoughtAST::Log {
            name: "activity-rate".into(),
            value: round_to(paper_count.max(1) as f64 / paper_duration.max(1.0), 2),
        },
        // Excursion-trail ratio (1 atom)
        ThoughtAST::Linear {
            name: "excursion-trail-ratio".into(),
            value: round_to(excursion_avg / trail.max(0.001), 2),
            scale: 1.0,
        },
        // Signal strength (2 atoms)
        ThoughtAST::Log {
            name: "market-signal-strength".into(),
            value: round_to(market_anomaly_norm.max(0.001), 2),
        },
        ThoughtAST::Log {
            name: "exit-signal-strength".into(),
            value: round_to(exit_anomaly_norm.max(0.001), 2),
        },
    ]
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample_facts() -> Vec<ThoughtAST> {
        encode_broker_derived_facts(
            0.015, 0.030, 0.012, 0.25, 0.55, 0.005, 0.60, 20, 25.0, 0.008, 3.5, 2.1,
        )
    }

    #[test]
    fn test_count() {
        assert_eq!(sample_facts().len(), 11);
    }

    #[test]
    fn test_names() {
        let facts = sample_facts();
        let names: Vec<String> = facts.iter().map(|f| f.name()).collect();
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
        // trail=0.015, atr_ratio=0.012 → 0.015/0.012 = 1.25
        let facts = sample_facts();
        match &facts[0] {
            ThoughtAST::Log { value, .. } => assert_eq!(*value, 1.25),
            _ => panic!("expected Log"),
        }
    }

    #[test]
    fn test_stop_atr_multiple() {
        // stop=0.030, atr_ratio=0.012 → 0.030/0.012 = 2.5
        let facts = sample_facts();
        match &facts[1] {
            ThoughtAST::Log { value, .. } => assert_eq!(*value, 2.5),
            _ => panic!("expected Log"),
        }
    }

    #[test]
    fn test_risk_reward_ratio() {
        // trail=0.015, stop=0.030 → 0.015/0.030 = 0.5
        let facts = sample_facts();
        match &facts[2] {
            ThoughtAST::Log { value, .. } => assert_eq!(*value, 0.5),
            _ => panic!("expected Log"),
        }
    }

    #[test]
    fn test_conviction_vol_magnitude() {
        // |0.25| / 0.012 = 20.833... → round to 20.83
        let facts = sample_facts();
        match &facts[3] {
            ThoughtAST::Log { value, .. } => assert_eq!(*value, 20.83),
            _ => panic!("expected Log"),
        }
    }

    #[test]
    fn test_conviction_vol_sign_positive() {
        let facts = sample_facts();
        match &facts[4] {
            ThoughtAST::Linear { value, .. } => assert_eq!(*value, 1.0),
            _ => panic!("expected Linear"),
        }
    }

    #[test]
    fn test_conviction_vol_sign_negative() {
        let facts = encode_broker_derived_facts(
            0.015, 0.030, 0.012, -0.25, 0.55, 0.005, 0.60, 20, 25.0, 0.008, 3.5, 2.1,
        );
        match &facts[4] {
            ThoughtAST::Linear { value, .. } => assert_eq!(*value, -1.0),
            _ => panic!("expected Linear"),
        }
    }

    #[test]
    fn test_exit_confidence() {
        // 0.55 * max(0.005, 0.001) = 0.55 * 0.005 = 0.00275 → round_to(4) = 0.0028
        let facts = sample_facts();
        match &facts[5] {
            ThoughtAST::Linear { value, .. } => assert_eq!(*value, 0.0028),
            _ => panic!("expected Linear"),
        }
    }

    #[test]
    fn test_self_exit_agreement() {
        // 0.60 - 0.55 = 0.05
        let facts = sample_facts();
        match &facts[6] {
            ThoughtAST::Linear { value, .. } => assert_eq!(*value, 0.05),
            _ => panic!("expected Linear"),
        }
    }

    #[test]
    fn test_activity_rate() {
        // max(20,1) / max(25.0,1.0) = 20/25 = 0.8
        let facts = sample_facts();
        match &facts[7] {
            ThoughtAST::Log { value, .. } => assert_eq!(*value, 0.8),
            _ => panic!("expected Log"),
        }
    }

    #[test]
    fn test_excursion_trail_ratio() {
        // 0.008 / max(0.015, 0.001) = 0.008 / 0.015 = 0.5333... → round_to(2) = 0.53
        let facts = sample_facts();
        match &facts[8] {
            ThoughtAST::Linear { value, .. } => assert_eq!(*value, 0.53),
            _ => panic!("expected Linear"),
        }
    }

    #[test]
    fn test_market_signal_strength() {
        // max(3.5, 0.001) = 3.5, round_to(2) = 3.5
        let facts = sample_facts();
        match &facts[9] {
            ThoughtAST::Log { value, .. } => assert_eq!(*value, 3.5),
            _ => panic!("expected Log"),
        }
    }

    #[test]
    fn test_exit_signal_strength() {
        // max(2.1, 0.001) = 2.1, round_to(2) = 2.1
        let facts = sample_facts();
        match &facts[10] {
            ThoughtAST::Log { value, .. } => assert_eq!(*value, 2.1),
            _ => panic!("expected Log"),
        }
    }

    #[test]
    fn test_zero_atr_ratio_clamped() {
        let facts = encode_broker_derived_facts(
            0.015, 0.030, 0.0, 0.25, 0.55, 0.005, 0.60, 20, 25.0, 0.008, 3.5, 2.1,
        );
        // atr_ratio clamped to 0.001 → trail/0.001 = 15.0
        match &facts[0] {
            ThoughtAST::Log { value, .. } => assert_eq!(*value, 15.0),
            _ => panic!("expected Log"),
        }
    }

    #[test]
    fn test_zero_paper_count_clamped() {
        let facts = encode_broker_derived_facts(
            0.015, 0.030, 0.012, 0.25, 0.55, 0.005, 0.60, 0, 25.0, 0.008, 3.5, 2.1,
        );
        // max(0,1) / 25.0 = 0.04
        match &facts[7] {
            ThoughtAST::Log { value, .. } => assert_eq!(*value, 0.04),
            _ => panic!("expected Log"),
        }
    }

    #[test]
    fn test_struct_forms_matches_function() {
        let thought = BrokerDerivedThought::new(
            0.015, 0.030, 0.012, 0.25, 0.55, 0.005, 0.60, 20, 25.0, 0.008, 3.5, 2.1,
        );
        let struct_forms = thought.forms();
        let fn_forms = sample_facts();
        assert_eq!(struct_forms, fn_forms);
    }

    #[test]
    fn test_struct_to_ast_is_bundle() {
        let thought = BrokerDerivedThought::new(
            0.015, 0.030, 0.012, 0.25, 0.55, 0.005, 0.60, 20, 25.0, 0.008, 3.5, 2.1,
        );
        let ast = thought.to_ast();
        match ast {
            ThoughtAST::Bundle(children) => assert_eq!(children.len(), 11),
            _ => panic!("expected Bundle"),
        }
    }

    #[test]
    fn test_all_log_types_correct() {
        let facts = sample_facts();
        // Log atoms: 0,1,2,3,7,9,10
        for i in [0, 1, 2, 3, 7, 9, 10] {
            assert!(
                matches!(&facts[i], ThoughtAST::Log { .. }),
                "fact {} should be Log, got {:?}",
                i,
                facts[i]
            );
        }
        // Linear atoms: 4,5,6,8
        for i in [4, 5, 6, 8] {
            assert!(
                matches!(&facts[i], ThoughtAST::Linear { .. }),
                "fact {} should be Linear, got {:?}",
                i,
                facts[i]
            );
        }
    }
}
