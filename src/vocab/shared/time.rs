// vocab/shared/time.rs — compiled from wat/vocab/shared/time.wat
//
// Temporal context. All circular scalars — the value wraps.
// atoms: minute, hour, day-of-week, day-of-month, month-of-year

use crate::types::candle::Candle;
use crate::encoding::thought_encoder::{ThoughtAST, round_to};

pub fn encode_time_facts(c: &Candle) -> Vec<ThoughtAST> {
    vec![
        // Minute: mod 60.
        ThoughtAST::Bind(
            Box::new(ThoughtAST::Atom("minute".into())),
            Box::new(ThoughtAST::Circular { value: round_to(c.minute, 0), period: 60.0 }),
        ),
        // Hour: mod 24.
        ThoughtAST::Bind(
            Box::new(ThoughtAST::Atom("hour".into())),
            Box::new(ThoughtAST::Circular { value: round_to(c.hour, 0), period: 24.0 }),
        ),
        // Day of week: mod 7. 0 = Monday.
        ThoughtAST::Bind(
            Box::new(ThoughtAST::Atom("day-of-week".into())),
            Box::new(ThoughtAST::Circular { value: round_to(c.day_of_week, 0), period: 7.0 }),
        ),
        // Day of month: mod 31.
        ThoughtAST::Bind(
            Box::new(ThoughtAST::Atom("day-of-month".into())),
            Box::new(ThoughtAST::Circular { value: round_to(c.day_of_month, 0), period: 31.0 }),
        ),
        // Month of year: mod 12. 1 = January.
        ThoughtAST::Bind(
            Box::new(ThoughtAST::Atom("month-of-year".into())),
            Box::new(ThoughtAST::Circular { value: round_to(c.month_of_year, 0), period: 12.0 }),
        ),
    ]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_encode_time_facts_nonempty() {
        let c = Candle::default();
        let facts = encode_time_facts(&c);
        assert_eq!(facts.len(), 5);
    }

    #[test]
    fn test_hour_circular() {
        let c = Candle::default();
        let facts = encode_time_facts(&c);
        match &facts[1] {
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
}
