// vocab/exit/self_assessment.rs — compiled from wat/vocab/exit/self-assessment.wat
//
// The exit observer's own recent performance. Two atoms.
// atoms: exit-grace-rate, exit-avg-residue

use crate::thought_encoder::{ThoughtAST, round_to};

pub fn encode_exit_self_assessment_facts(grace_rate: f64, avg_residue: f64) -> Vec<ThoughtAST> {
    vec![
        // Grace rate: fraction of recent outcomes that were Grace. [0, 1].
        ThoughtAST::Linear {
            name: "exit-grace-rate".into(),
            value: round_to(grace_rate.clamp(0.0, 1.0), 3),
            scale: 1.0,
        },
        // Average residue per resolution. Small positive. Log-encoded.
        ThoughtAST::Log {
            name: "exit-avg-residue".into(),
            value: round_to(avg_residue.max(0.001), 4),
        },
    ]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_encode_exit_self_assessment_facts_nonempty() {
        let facts = encode_exit_self_assessment_facts(0.6, 0.0005);
        assert_eq!(facts.len(), 2);
    }

    #[test]
    fn test_grace_rate_linear() {
        let facts = encode_exit_self_assessment_facts(0.75, 0.0005);
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
        let facts = encode_exit_self_assessment_facts(0.5, 0.0005);
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
        let facts = encode_exit_self_assessment_facts(1.5, 0.01);
        match &facts[0] {
            ThoughtAST::Linear { name, value, .. } => {
                assert_eq!(name, "exit-grace-rate");
                assert!(*value <= 1.0);
            }
            _ => panic!("expected Linear"),
        }
    }
}
