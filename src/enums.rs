/// Side, Direction, Outcome, TradePhase, ReckonerConfig, Prediction, ScalarEncoding, ThoughtAST,
/// MarketLens, ExitLens.

/// Which vocabulary a market observer thinks about.
#[derive(Clone, Debug, PartialEq)]
pub enum MarketLens {
    Momentum,
    Structure,
    Volume,
    Narrative,
    Regime,
    Generalist,
}

impl std::fmt::Display for MarketLens {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            MarketLens::Momentum => write!(f, "momentum"),
            MarketLens::Structure => write!(f, "structure"),
            MarketLens::Volume => write!(f, "volume"),
            MarketLens::Narrative => write!(f, "narrative"),
            MarketLens::Regime => write!(f, "regime"),
            MarketLens::Generalist => write!(f, "generalist"),
        }
    }
}

/// Which vocabulary an exit observer uses.
#[derive(Clone, Debug, PartialEq)]
pub enum ExitLens {
    Volatility,
    Structure,
    Timing,
    Generalist,
}

impl std::fmt::Display for ExitLens {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ExitLens::Volatility => write!(f, "volatility"),
            ExitLens::Structure => write!(f, "structure"),
            ExitLens::Timing => write!(f, "timing"),
            ExitLens::Generalist => write!(f, "generalist"),
        }
    }
}

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

/// What the vocabulary speaks. The ThoughtEncoder evaluates these.
#[derive(Clone, Debug)]
pub enum ThoughtAST {
    /// Dictionary lookup — a named atom vector.
    Atom(String),
    /// bind(atom, encode_linear(value, scale)).
    Linear { name: String, value: f64, scale: f64 },
    /// bind(atom, encode_log(value)).
    Log { name: String, value: f64 },
    /// bind(atom, encode_circular(value, period)).
    Circular { name: String, value: f64, period: f64 },
    /// Composition of two sub-trees.
    Bind(Box<ThoughtAST>, Box<ThoughtAST>),
    /// Superposition of sub-trees.
    Bundle(Vec<ThoughtAST>),
}

impl PartialEq for ThoughtAST {
    fn eq(&self, other: &Self) -> bool {
        match (self, other) {
            (ThoughtAST::Atom(a), ThoughtAST::Atom(b)) => a == b,
            (ThoughtAST::Linear { name: n1, value: v1, scale: s1 },
             ThoughtAST::Linear { name: n2, value: v2, scale: s2 }) =>
                n1 == n2 && v1.to_bits() == v2.to_bits() && s1.to_bits() == s2.to_bits(),
            (ThoughtAST::Log { name: n1, value: v1 },
             ThoughtAST::Log { name: n2, value: v2 }) =>
                n1 == n2 && v1.to_bits() == v2.to_bits(),
            (ThoughtAST::Circular { name: n1, value: v1, period: p1 },
             ThoughtAST::Circular { name: n2, value: v2, period: p2 }) =>
                n1 == n2 && v1.to_bits() == v2.to_bits() && p1.to_bits() == p2.to_bits(),
            (ThoughtAST::Bind(l1, r1), ThoughtAST::Bind(l2, r2)) =>
                l1 == l2 && r1 == r2,
            (ThoughtAST::Bundle(a), ThoughtAST::Bundle(b)) => a == b,
            _ => false,
        }
    }
}

impl Eq for ThoughtAST {}

impl std::hash::Hash for ThoughtAST {
    fn hash<H: std::hash::Hasher>(&self, state: &mut H) {
        std::mem::discriminant(self).hash(state);
        match self {
            ThoughtAST::Atom(name) => name.hash(state),
            ThoughtAST::Linear { name, value, scale } => {
                name.hash(state);
                value.to_bits().hash(state);
                scale.to_bits().hash(state);
            }
            ThoughtAST::Log { name, value } => {
                name.hash(state);
                value.to_bits().hash(state);
            }
            ThoughtAST::Circular { name, value, period } => {
                name.hash(state);
                value.to_bits().hash(state);
                period.to_bits().hash(state);
            }
            ThoughtAST::Bind(left, right) => {
                left.hash(state);
                right.hash(state);
            }
            ThoughtAST::Bundle(children) => {
                children.hash(state);
            }
        }
    }
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
    fn test_thought_ast_atom() {
        let ast = ThoughtAST::Atom("rsi".into());
        match ast {
            ThoughtAST::Atom(name) => assert_eq!(name, "rsi"),
            _ => panic!("Expected Atom"),
        }
    }

    #[test]
    fn test_thought_ast_linear() {
        let ast = ThoughtAST::Linear { name: "rsi".into(), value: 0.55, scale: 1.0 };
        match ast {
            ThoughtAST::Linear { name, value, scale } => {
                assert_eq!(name, "rsi");
                assert_eq!(value, 0.55);
                assert_eq!(scale, 1.0);
            }
            _ => panic!("Expected Linear"),
        }
    }

    #[test]
    fn test_thought_ast_bundle() {
        let ast = ThoughtAST::Bundle(vec![
            ThoughtAST::Atom("a".into()),
            ThoughtAST::Atom("b".into()),
        ]);
        match ast {
            ThoughtAST::Bundle(children) => assert_eq!(children.len(), 2),
            _ => panic!("Expected Bundle"),
        }
    }

    #[test]
    fn test_thought_ast_bind() {
        let ast = ThoughtAST::Bind(
            Box::new(ThoughtAST::Atom("a".into())),
            Box::new(ThoughtAST::Atom("b".into())),
        );
        match ast {
            ThoughtAST::Bind(left, right) => {
                assert_eq!(*left, ThoughtAST::Atom("a".into()));
                assert_eq!(*right, ThoughtAST::Atom("b".into()));
            }
            _ => panic!("Expected Bind"),
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
