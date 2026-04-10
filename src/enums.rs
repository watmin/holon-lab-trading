/// Side, Direction, Outcome, TradePhase, ReckonerConfig, Prediction, ScalarEncoding.

/// What the trader does. On Proposal and Trade.
#[derive(Clone, Debug, PartialEq)]
pub enum Side {
    Buy,
    Sell,
}

/// What the price did. Used in propagation.
#[derive(Clone, Debug, PartialEq)]
pub enum Direction {
    Up,
    Down,
}

/// Did this produce value or destroy it?
#[derive(Clone, Debug, PartialEq)]
pub enum Outcome {
    Grace,
    Violence,
}

/// The state machine of a position's lifecycle.
#[derive(Clone, Debug, PartialEq)]
pub enum TradePhase {
    /// Capital reserved, all stops live.
    Active,
    /// Residue riding, principal covered.
    Runner,
    /// Stop-loss fired — bounded loss.
    SettledViolence,
    /// Runner trail fired — residue is permanent gain.
    SettledGrace,
}

/// Readout mode for the learning primitive.
/// dims and recalib-interval are separate parameters.
#[derive(Clone, Debug, PartialEq)]
pub enum ReckonerConfig {
    /// Vec of label strings (e.g. ["Up", "Down"] or ["Grace", "Violence"]).
    Discrete(Vec<String>),
    /// The crutch — returned when ignorant.
    Continuous(f64),
}

/// What a reckoner returns. Data, not action.
#[derive(Clone, Debug)]
pub enum Prediction {
    Discrete {
        /// (label, cosine) for each label.
        scores: Vec<(String, f64)>,
        /// How strongly the reckoner leans.
        conviction: f64,
    },
    Continuous {
        /// The reckoned scalar.
        value: f64,
        /// How much the reckoner knows.
        experience: f64,
    },
}

/// How a scalar accumulator encodes values.
#[derive(Clone, Debug, PartialEq)]
pub enum ScalarEncoding {
    /// encode-log — ratios compress naturally.
    Log,
    /// encode-linear with scale.
    Linear { scale: f64 },
    /// encode-circular with period.
    Circular { period: f64 },
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_side_eq() {
        assert_eq!(Side::Buy, Side::Buy);
        assert_ne!(Side::Buy, Side::Sell);
    }

    #[test]
    fn test_direction_eq() {
        assert_eq!(Direction::Up, Direction::Up);
        assert_ne!(Direction::Up, Direction::Down);
    }

    #[test]
    fn test_outcome_eq() {
        assert_eq!(Outcome::Grace, Outcome::Grace);
        assert_ne!(Outcome::Grace, Outcome::Violence);
    }

    #[test]
    fn test_trade_phase_variants() {
        let phases = vec![
            TradePhase::Active,
            TradePhase::Runner,
            TradePhase::SettledViolence,
            TradePhase::SettledGrace,
        ];
        assert_eq!(phases.len(), 4);
        assert_eq!(phases[0], TradePhase::Active);
    }

    #[test]
    fn test_reckoner_config_discrete() {
        let cfg = ReckonerConfig::Discrete(vec!["Up".into(), "Down".into()]);
        match cfg {
            ReckonerConfig::Discrete(labels) => assert_eq!(labels.len(), 2),
            _ => panic!("Expected Discrete"),
        }
    }

    #[test]
    fn test_reckoner_config_continuous() {
        let cfg = ReckonerConfig::Continuous(0.5);
        match cfg {
            ReckonerConfig::Continuous(v) => assert_eq!(v, 0.5),
            _ => panic!("Expected Continuous"),
        }
    }

    #[test]
    fn test_prediction_discrete() {
        let p = Prediction::Discrete {
            scores: vec![("Up".into(), 0.8), ("Down".into(), 0.2)],
            conviction: 0.6,
        };
        match p {
            Prediction::Discrete { scores, conviction } => {
                assert_eq!(scores.len(), 2);
                assert_eq!(conviction, 0.6);
            }
            _ => panic!("Expected Discrete"),
        }
    }

    #[test]
    fn test_prediction_continuous() {
        let p = Prediction::Continuous {
            value: 0.03,
            experience: 0.9,
        };
        match p {
            Prediction::Continuous { value, experience } => {
                assert_eq!(value, 0.03);
                assert_eq!(experience, 0.9);
            }
            _ => panic!("Expected Discrete"),
        }
    }

    #[test]
    fn test_scalar_encoding_variants() {
        assert_eq!(ScalarEncoding::Log, ScalarEncoding::Log);
        let lin = ScalarEncoding::Linear { scale: 1.0 };
        assert_eq!(lin, ScalarEncoding::Linear { scale: 1.0 });
        let circ = ScalarEncoding::Circular { period: 24.0 };
        assert_eq!(circ, ScalarEncoding::Circular { period: 24.0 });
    }
}
