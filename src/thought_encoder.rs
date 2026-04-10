// thought_encoder.rs — the AST that vocabulary modules produce.
// The evaluator (encode function) will be added later.

#[derive(Clone, Debug, PartialEq)]
pub enum ThoughtAST {
    Atom(String),
    Linear { name: String, value: f64, scale: f64 },
    Log { name: String, value: f64 },
    Circular { name: String, value: f64, period: f64 },
    Bind(Box<ThoughtAST>, Box<ThoughtAST>),
    Bundle(Vec<ThoughtAST>),
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_thought_ast_variants() {
        let a = ThoughtAST::Atom("rsi".into());
        let l = ThoughtAST::Linear { name: "rsi".into(), value: 0.5, scale: 1.0 };
        let g = ThoughtAST::Log { name: "vol".into(), value: 2.0 };
        let c = ThoughtAST::Circular { name: "hour".into(), value: 14.0, period: 24.0 };
        let b = ThoughtAST::Bind(Box::new(a.clone()), Box::new(l.clone()));
        let u = ThoughtAST::Bundle(vec![a, l, g, c]);
        assert!(matches!(b, ThoughtAST::Bind(_, _)));
        assert!(matches!(u, ThoughtAST::Bundle(_)));
    }
}
