// vocab/exit/time.rs — compiled from wat/vocab/exit/time.wat
//
// Temporal context for exit observers. Subset of shared/time.rs:
// hour and day-of-week only. Circular encoding.
// atoms: hour, day-of-week

use crate::candle::Candle;
use crate::thought_encoder::{ThoughtAST, round_to};

pub fn encode_exit_time_facts(c: &Candle) -> Vec<ThoughtAST> {
    vec![
        // Hour: mod 24.
        ThoughtAST::Circular {
            name: "hour".into(),
            value: round_to(c.hour, 0),
            period: 24.0,
        },
        // Day of week: mod 7. 0 = Monday.
        ThoughtAST::Circular {
            name: "day-of-week".into(),
            value: round_to(c.day_of_week, 0),
            period: 7.0,
        },
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
            ThoughtAST::Circular {
                name,
                value,
                period,
            } => {
                assert_eq!(name, "hour");
                assert_eq!(*value, 14.0);
                assert_eq!(*period, 24.0);
            }
            _ => panic!("expected Circular"),
        }
    }

    #[test]
    fn test_day_of_week_circular() {
        let c = Candle::default();
        let facts = encode_exit_time_facts(&c);
        match &facts[1] {
            ThoughtAST::Circular {
                name,
                value,
                period,
            } => {
                assert_eq!(name, "day-of-week");
                assert_eq!(*period, 7.0);
                // Default candle's day_of_week value
                let _ = value;
            }
            _ => panic!("expected Circular"),
        }
    }
}
