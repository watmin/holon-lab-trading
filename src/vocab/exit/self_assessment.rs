// vocab/exit/self_assessment.rs — compiled from wat/vocab/exit/self-assessment.wat
//
// The exit observer's own recent performance. Two atoms.
// atoms: exit-grace-rate, exit-avg-residue

use std::collections::HashMap;
use crate::thought_encoder::{ThoughtAST, ToAst, round_to};
use crate::scale_tracker::{ScaleTracker, scaled_linear};

pub struct ExitSelfAssessmentThought {
    pub exit_grace_rate: f64,
    pub exit_avg_residue: f64,
}

impl ExitSelfAssessmentThought {
    pub fn new(grace_rate: f64, avg_residue: f64) -> Self {
        Self {
            exit_grace_rate: round_to(grace_rate.clamp(0.0, 1.0), 3),
            exit_avg_residue: round_to(avg_residue.max(0.001), 4),
        }
    }
}

impl ToAst for ExitSelfAssessmentThought {
    fn to_ast(&self) -> ThoughtAST {
        ThoughtAST::Bundle(self.forms())
    }

    fn forms(&self) -> Vec<ThoughtAST> {
        vec![
            ThoughtAST::Linear { name: "exit-grace-rate".into(), value: self.exit_grace_rate, scale: 1.0 },
            ThoughtAST::Log { name: "exit-avg-residue".into(), value: self.exit_avg_residue },
        ]
    }
}

pub fn encode_exit_self_assessment_facts(grace_rate: f64, avg_residue: f64, scales: &mut HashMap<String, ScaleTracker>) -> Vec<ThoughtAST> {
    let t = ExitSelfAssessmentThought::new(grace_rate, avg_residue);
    vec![
        scaled_linear("exit-grace-rate", t.exit_grace_rate, scales),
        ThoughtAST::Log { name: "exit-avg-residue".into(), value: t.exit_avg_residue },
    ]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_encode_exit_self_assessment_facts_nonempty() {
        let mut scales = HashMap::new();
        let facts = encode_exit_self_assessment_facts(0.6, 0.0005, &mut scales);
        assert_eq!(facts.len(), 2);
    }

    #[test]
    fn test_grace_rate_linear() {
        let mut scales = HashMap::new();
        let facts = encode_exit_self_assessment_facts(0.75, 0.0005, &mut scales);
        match &facts[0] {
            ThoughtAST::Linear { name, value, .. } => {
                assert_eq!(name, "exit-grace-rate");
                assert!((value - 0.75).abs() < 1e-3);
            }
            _ => panic!("expected Linear"),
        }
    }

    #[test]
    fn test_avg_residue_log() {
        let mut scales = HashMap::new();
        let facts = encode_exit_self_assessment_facts(0.5, 0.0005, &mut scales);
        match &facts[1] {
            ThoughtAST::Log { name, value } => {
                assert_eq!(name, "exit-avg-residue");
                assert_eq!(*value, 0.001); // clamped to min 0.001
            }
            _ => panic!("expected Log"),
        }
    }

    #[test]
    fn test_grace_rate_clamped() {
        let mut scales = HashMap::new();
        let facts = encode_exit_self_assessment_facts(1.5, 0.01, &mut scales);
        match &facts[0] {
            ThoughtAST::Linear { name, value, .. } => {
                assert_eq!(name, "exit-grace-rate");
                assert!(*value <= 1.0);
            }
            _ => panic!("expected Linear"),
        }
    }
}
