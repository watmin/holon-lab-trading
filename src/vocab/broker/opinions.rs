/// Broker opinion vocabulary. The decisions of the leaf observers, encoded as
/// scalar facts so the broker's reckoner can learn what predicts Grace.
///
/// Market opinions: 3 atoms (signed-conviction, conviction, edge).
/// Exit opinions: 4 atoms (trail, stop, grace-rate, avg-residue).
///
/// These compose with the extracted context and self-assessment to give the
/// broker ~142 atoms. The noise subspace strips what doesn't matter.

use std::collections::HashMap;
use crate::encoding::thought_encoder::{round_to, ThoughtAST, ToAst};
use crate::encoding::scale_tracker::{ScaleTracker, scaled_linear};

/// Market observer's decisions as scalar facts.
///
/// signed_conviction: positive = Up, negative = Down. Range [-1, +1].
/// conviction: absolute conviction. Range [0, 1].
/// edge: accuracy at this conviction level. Range [0, 1].
pub struct MarketOpinionThought {
    pub signed_conviction: f64,
    pub conviction: f64,
    pub edge: f64,
}

impl MarketOpinionThought {
    pub fn new(signed_conviction: f64, conviction: f64, edge: f64) -> Self {
        Self {
            signed_conviction,
            conviction,
            edge,
        }
    }
}

impl ToAst for MarketOpinionThought {
    fn to_ast(&self) -> ThoughtAST {
        ThoughtAST::Bundle(self.forms())
    }

    fn forms(&self) -> Vec<ThoughtAST> {
        vec![
            ThoughtAST::Bind(
                Box::new(ThoughtAST::Atom("market-direction".into())),
                Box::new(ThoughtAST::Linear { value: round_to(self.signed_conviction, 3), scale: 1.0 }),
            ),
            ThoughtAST::Bind(
                Box::new(ThoughtAST::Atom("market-conviction".into())),
                Box::new(ThoughtAST::Linear { value: round_to(self.conviction, 3), scale: 1.0 }),
            ),
            ThoughtAST::Bind(
                Box::new(ThoughtAST::Atom("market-edge".into())),
                Box::new(ThoughtAST::Linear { value: round_to(self.edge, 3), scale: 1.0 }),
            ),
        ]
    }
}

/// Encode the market observer's decisions as scalar facts.
/// Delegates to MarketOpinionThought.
pub fn encode_market_opinions(
    signed_conviction: f64,
    conviction: f64,
    edge: f64,
    scales: &mut HashMap<String, ScaleTracker>,
) -> Vec<ThoughtAST> {
    vec![
        scaled_linear("market-direction", round_to(signed_conviction, 3), scales),
        scaled_linear("market-conviction", round_to(conviction, 3), scales),
        scaled_linear("market-edge", round_to(edge, 3), scales),
    ]
}

/// Exit observer's decisions as scalar facts.
///
/// trail: chosen trail distance. Log-encoded (small positive fraction).
/// stop: chosen stop distance. Log-encoded (small positive fraction).
/// grace_rate: exit's recent performance [0, 1].
/// avg_residue: exit's recent residue per paper. Log-encoded.
pub struct ExitOpinionThought {
    pub trail: f64,
    pub stop: f64,
    pub grace_rate: f64,
    pub avg_residue: f64,
}

impl ExitOpinionThought {
    pub fn new(trail: f64, stop: f64, grace_rate: f64, avg_residue: f64) -> Self {
        Self {
            trail,
            stop,
            grace_rate,
            avg_residue,
        }
    }
}

impl ToAst for ExitOpinionThought {
    fn to_ast(&self) -> ThoughtAST {
        ThoughtAST::Bundle(self.forms())
    }

    fn forms(&self) -> Vec<ThoughtAST> {
        vec![
            ThoughtAST::Bind(
                Box::new(ThoughtAST::Atom("exit-trail".into())),
                Box::new(ThoughtAST::Log { value: round_to(self.trail.max(0.001), 4) }),
            ),
            ThoughtAST::Bind(
                Box::new(ThoughtAST::Atom("exit-stop".into())),
                Box::new(ThoughtAST::Log { value: round_to(self.stop.max(0.001), 4) }),
            ),
            ThoughtAST::Bind(
                Box::new(ThoughtAST::Atom("exit-grace-rate".into())),
                Box::new(ThoughtAST::Linear { value: round_to(self.grace_rate, 2), scale: 1.0 }),
            ),
            ThoughtAST::Bind(
                Box::new(ThoughtAST::Atom("exit-avg-residue".into())),
                Box::new(ThoughtAST::Log { value: round_to(self.avg_residue.max(0.001), 4) }),
            ),
        ]
    }
}

/// Encode the exit observer's decisions as scalar facts.
/// Delegates to ExitOpinionThought.
pub fn encode_exit_opinions(
    trail: f64,
    stop: f64,
    grace_rate: f64,
    avg_residue: f64,
    scales: &mut HashMap<String, ScaleTracker>,
) -> Vec<ThoughtAST> {
    vec![
        ThoughtAST::Bind(
            Box::new(ThoughtAST::Atom("exit-trail".into())),
            Box::new(ThoughtAST::Log { value: round_to(trail.max(0.001), 4) }),
        ),
        ThoughtAST::Bind(
            Box::new(ThoughtAST::Atom("exit-stop".into())),
            Box::new(ThoughtAST::Log { value: round_to(stop.max(0.001), 4) }),
        ),
        scaled_linear("exit-grace-rate", round_to(grace_rate, 2), scales),
        ThoughtAST::Bind(
            Box::new(ThoughtAST::Atom("exit-avg-residue".into())),
            Box::new(ThoughtAST::Log { value: round_to(avg_residue.max(0.001), 4) }),
        ),
    ]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_encode_market_opinions_count() {
        let mut scales = HashMap::new();
        let facts = encode_market_opinions(0.15, 0.15, 0.62, &mut scales);
        assert_eq!(facts.len(), 3);
    }

    /// Helper: extract atom name from Bind(Atom(name), _).
    fn atom_name(ast: &ThoughtAST) -> &str {
        match ast {
            ThoughtAST::Bind(left, _) => match left.as_ref() {
                ThoughtAST::Atom(name) => name.as_str(),
                _ => panic!("expected Bind(Atom, _)"),
            },
            _ => panic!("expected Bind"),
        }
    }

    /// Helper: extract scalar value from Bind(_, Linear{value, ..}).
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
    fn test_encode_market_opinions_names() {
        let mut scales = HashMap::new();
        let facts = encode_market_opinions(-0.08, 0.08, 0.55, &mut scales);
        let names: Vec<&str> = facts.iter().map(|f| atom_name(f)).collect();
        assert_eq!(names, vec!["market-direction", "market-conviction", "market-edge"]);
    }

    #[test]
    fn test_encode_market_opinions_signed_conviction() {
        let mut scales = HashMap::new();
        // Up at 0.15 → +0.15
        let facts = encode_market_opinions(0.15, 0.15, 0.62, &mut scales);
        assert!(linear_value(&facts[0]) > 0.0);
        // Down at 0.08 → -0.08
        let facts = encode_market_opinions(-0.08, 0.08, 0.55, &mut scales);
        assert!(linear_value(&facts[0]) < 0.0);
    }

    #[test]
    fn test_encode_market_opinions_rounding() {
        let mut scales = HashMap::new();
        let facts = encode_market_opinions(0.12345, 0.6789, 0.4321, &mut scales);
        assert_eq!(linear_value(&facts[0]), 0.12);
        assert_eq!(linear_value(&facts[1]), 0.68);
        assert_eq!(linear_value(&facts[2]), 0.43);
    }

    #[test]
    fn test_encode_exit_opinions_count() {
        let mut scales = HashMap::new();
        let facts = encode_exit_opinions(0.015, 0.030, 0.55, 0.005, &mut scales);
        assert_eq!(facts.len(), 4);
    }

    /// Helper: extract scalar value from Bind(_, Log{value}).
    fn log_value(ast: &ThoughtAST) -> f64 {
        match ast {
            ThoughtAST::Bind(_, right) => match right.as_ref() {
                ThoughtAST::Log { value } => *value,
                _ => panic!("expected Bind(_, Log)"),
            },
            _ => panic!("expected Bind"),
        }
    }

    #[test]
    fn test_encode_exit_opinions_names() {
        let mut scales = HashMap::new();
        let facts = encode_exit_opinions(0.015, 0.030, 0.55, 0.005, &mut scales);
        let names: Vec<&str> = facts.iter().map(|f| atom_name(f)).collect();
        assert_eq!(
            names,
            vec!["exit-trail", "exit-stop", "exit-grace-rate", "exit-avg-residue"]
        );
    }

    #[test]
    fn test_encode_exit_opinions_log_encoding() {
        let mut scales = HashMap::new();
        let facts = encode_exit_opinions(0.015, 0.030, 0.55, 0.005, &mut scales);
        // All are Bind nodes; check the inner scalar type
        for (i, expected_log) in [(0, true), (1, true), (2, false), (3, true)] {
            match &facts[i] {
                ThoughtAST::Bind(_, right) => {
                    if expected_log {
                        assert!(matches!(right.as_ref(), ThoughtAST::Log { .. }), "fact {} should be Log", i);
                    } else {
                        assert!(matches!(right.as_ref(), ThoughtAST::Linear { .. }), "fact {} should be Linear", i);
                    }
                }
                _ => panic!("fact {} should be Bind", i),
            }
        }
    }

    #[test]
    fn test_encode_exit_opinions_clamps_small_values() {
        let mut scales = HashMap::new();
        // Values below 0.001 should be clamped
        let facts = encode_exit_opinions(0.0001, 0.0, 0.55, 0.0, &mut scales);
        assert!(log_value(&facts[0]) >= 0.001);
        assert!(log_value(&facts[1]) >= 0.001);
        assert!(log_value(&facts[3]) >= 0.001);
    }

    #[test]
    fn test_market_struct_to_ast_is_bundle() {
        let thought = MarketOpinionThought::new(0.15, 0.15, 0.62);
        let ast = thought.to_ast();
        match ast {
            ThoughtAST::Bundle(children) => assert_eq!(children.len(), 3),
            _ => panic!("expected Bundle"),
        }
    }

    #[test]
    fn test_exit_struct_to_ast_is_bundle() {
        let thought = ExitOpinionThought::new(0.015, 0.030, 0.55, 0.005);
        let ast = thought.to_ast();
        match ast {
            ThoughtAST::Bundle(children) => assert_eq!(children.len(), 4),
            _ => panic!("expected Bundle"),
        }
    }

    #[test]
    fn test_total_opinion_atoms() {
        let mut scales = HashMap::new();
        let market = encode_market_opinions(0.15, 0.15, 0.62, &mut scales);
        let exit = encode_exit_opinions(0.015, 0.030, 0.55, 0.005, &mut scales);
        assert_eq!(market.len() + exit.len(), 7);
    }
}
