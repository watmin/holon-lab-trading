/// Broker opinion vocabulary. The decisions of the leaf observers, encoded as
/// scalar facts so the broker's reckoner can learn what predicts Grace.
///
/// Market opinions: 3 atoms (signed-conviction, conviction, edge).
/// Exit opinions: 4 atoms (trail, stop, grace-rate, avg-residue).
///
/// These compose with the extracted context and self-assessment to give the
/// broker ~142 atoms. The noise subspace strips what doesn't matter.

use crate::thought_encoder::{round_to, ThoughtAST, ToAst};

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
            ThoughtAST::linear(
                "market-direction",
                round_to(self.signed_conviction, 3),
                1.0,
            ),
            ThoughtAST::linear("market-conviction", round_to(self.conviction, 3), 1.0),
            ThoughtAST::linear("market-edge", round_to(self.edge, 3), 1.0),
        ]
    }
}

/// Encode the market observer's decisions as scalar facts.
/// Delegates to MarketOpinionThought.
pub fn encode_market_opinions(
    signed_conviction: f64,
    conviction: f64,
    edge: f64,
) -> Vec<ThoughtAST> {
    MarketOpinionThought::new(signed_conviction, conviction, edge).forms()
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
            ThoughtAST::log("exit-trail", round_to(self.trail.max(0.001), 4)),
            ThoughtAST::log("exit-stop", round_to(self.stop.max(0.001), 4)),
            ThoughtAST::linear("exit-grace-rate", round_to(self.grace_rate, 2), 1.0),
            ThoughtAST::log("exit-avg-residue", round_to(self.avg_residue.max(0.001), 4)),
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
) -> Vec<ThoughtAST> {
    ExitOpinionThought::new(trail, stop, grace_rate, avg_residue).forms()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_encode_market_opinions_count() {
        let facts = encode_market_opinions(0.15, 0.15, 0.62);
        assert_eq!(facts.len(), 3);
    }

    #[test]
    fn test_encode_market_opinions_names() {
        let facts = encode_market_opinions(-0.08, 0.08, 0.55);
        let names: Vec<String> = facts.iter().map(|f| f.name()).collect();
        assert_eq!(names, vec!["market-direction", "market-conviction", "market-edge"]);
    }

    #[test]
    fn test_encode_market_opinions_signed_conviction() {
        // Up at 0.15 → +0.15
        let facts = encode_market_opinions(0.15, 0.15, 0.62);
        match &facts[0] {
            ThoughtAST::Linear { value, .. } => assert!(*value > 0.0),
            _ => panic!("expected Linear"),
        }
        // Down at 0.08 → -0.08
        let facts = encode_market_opinions(-0.08, 0.08, 0.55);
        match &facts[0] {
            ThoughtAST::Linear { value, .. } => assert!(*value < 0.0),
            _ => panic!("expected Linear"),
        }
    }

    #[test]
    fn test_encode_market_opinions_rounding() {
        let facts = encode_market_opinions(0.12345, 0.6789, 0.4321);
        match &facts[0] {
            ThoughtAST::Linear { value, .. } => assert_eq!(*value, 0.123),
            _ => panic!("expected Linear"),
        }
        match &facts[1] {
            ThoughtAST::Linear { value, .. } => assert_eq!(*value, 0.679),
            _ => panic!("expected Linear"),
        }
        match &facts[2] {
            ThoughtAST::Linear { value, .. } => assert_eq!(*value, 0.432),
            _ => panic!("expected Linear"),
        }
    }

    #[test]
    fn test_encode_exit_opinions_count() {
        let facts = encode_exit_opinions(0.015, 0.030, 0.55, 0.005);
        assert_eq!(facts.len(), 4);
    }

    #[test]
    fn test_encode_exit_opinions_names() {
        let facts = encode_exit_opinions(0.015, 0.030, 0.55, 0.005);
        let names: Vec<String> = facts.iter().map(|f| f.name()).collect();
        assert_eq!(
            names,
            vec!["exit-trail", "exit-stop", "exit-grace-rate", "exit-avg-residue"]
        );
    }

    #[test]
    fn test_encode_exit_opinions_log_encoding() {
        let facts = encode_exit_opinions(0.015, 0.030, 0.55, 0.005);
        assert!(matches!(&facts[0], ThoughtAST::Log { .. }));
        assert!(matches!(&facts[1], ThoughtAST::Log { .. }));
        assert!(matches!(&facts[2], ThoughtAST::Linear { .. }));
        assert!(matches!(&facts[3], ThoughtAST::Log { .. }));
    }

    #[test]
    fn test_encode_exit_opinions_clamps_small_values() {
        // Values below 0.001 should be clamped
        let facts = encode_exit_opinions(0.0001, 0.0, 0.55, 0.0);
        match &facts[0] {
            ThoughtAST::Log { value, .. } => assert!(*value >= 0.001),
            _ => panic!("expected Log"),
        }
        match &facts[1] {
            ThoughtAST::Log { value, .. } => assert!(*value >= 0.001),
            _ => panic!("expected Log"),
        }
        match &facts[3] {
            ThoughtAST::Log { value, .. } => assert!(*value >= 0.001),
            _ => panic!("expected Log"),
        }
    }

    #[test]
    fn test_market_struct_forms_matches_function() {
        let thought = MarketOpinionThought::new(0.15, 0.15, 0.62);
        let struct_forms = thought.forms();
        let fn_forms = encode_market_opinions(0.15, 0.15, 0.62);
        assert_eq!(struct_forms, fn_forms);
    }

    #[test]
    fn test_exit_struct_forms_matches_function() {
        let thought = ExitOpinionThought::new(0.015, 0.030, 0.55, 0.005);
        let struct_forms = thought.forms();
        let fn_forms = encode_exit_opinions(0.015, 0.030, 0.55, 0.005);
        assert_eq!(struct_forms, fn_forms);
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
        let market = encode_market_opinions(0.15, 0.15, 0.62);
        let exit = encode_exit_opinions(0.015, 0.030, 0.55, 0.005);
        assert_eq!(market.len() + exit.len(), 7);
    }
}
