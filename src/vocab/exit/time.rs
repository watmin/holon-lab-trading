// vocab/exit/time.rs — compiled from wat/vocab/exit/time.wat
//
// Temporal context for exit observers. Subset of shared/time.rs:
// hour and day-of-week only. Circular encoding.
// atoms: hour, day-of-week

use crate::types::candle::Candle;
use crate::encoding::thought_encoder::{ThoughtAST, round_to};

pub struct ExitTimeThought {
    pub hour: f64,
    pub day_of_week: f64,
}

impl ExitTimeThought {
    pub fn from_candle(c: &Candle) -> Self {
        Self {
            hour: round_to(c.hour, 0),
            day_of_week: round_to(c.day_of_week, 0),
        }
    }
}

pub fn encode_exit_time_facts(c: &Candle) -> Vec<ThoughtAST> {
    let t = ExitTimeThought::from_candle(c);
    vec![
        ThoughtAST::Bind(Box::new(ThoughtAST::Atom("hour".into())), Box::new(ThoughtAST::Circular { value: t.hour, period: 24.0 })),
        ThoughtAST::Bind(Box::new(ThoughtAST::Atom("day-of-week".into())), Box::new(ThoughtAST::Circular { value: t.day_of_week, period: 7.0 })),
    ]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_encode_exit_time_facts_nonempty() {
        let c = Candle::default();
        let facts = encode_exit_time_facts(&c);
        assert_eq!(facts.len(), 2);
    }

    #[test]
    fn test_hour_circular() {
        let c = Candle::default();
        let facts = encode_exit_time_facts(&c);
        match &facts[0] {
            ThoughtAST::Bind(left, right) => {
                match (left.as_ref(), right.as_ref()) {
                    (ThoughtAST::Atom(name), ThoughtAST::Circular { value, period }) => {
                        assert_eq!(name, "hour");
                        assert_eq!(*value, 14.0);
                        assert_eq!(*period, 24.0);
                    }
                    _ => panic!("expected Bind(Atom, Circular)"),
                }
            }
            _ => panic!("expected Bind"),
        }
    }

    #[test]
    fn test_day_of_week_circular() {
        let c = Candle::default();
        let facts = encode_exit_time_facts(&c);
        match &facts[1] {
            ThoughtAST::Bind(left, right) => {
                match (left.as_ref(), right.as_ref()) {
                    (ThoughtAST::Atom(name), ThoughtAST::Circular { period, .. }) => {
                        assert_eq!(name, "day-of-week");
                        assert_eq!(*period, 7.0);
                    }
                    _ => panic!("expected Bind(Atom, Circular)"),
                }
            }
            _ => panic!("expected Bind"),
        }
    }
}
