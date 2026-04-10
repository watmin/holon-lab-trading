// vocab/shared/time.rs — compiled from wat/vocab/shared/time.wat
//
// Temporal context. All circular scalars — the value wraps.
// atoms: minute, hour, day-of-week, day-of-month, month-of-year

use crate::candle::Candle;
use crate::thought_encoder::ThoughtAST;

pub fn encode_time_facts(c: &Candle) -> Vec<ThoughtAST> {
    vec![
        // Minute: mod 60.
        ThoughtAST::Circular {
            name: "minute".into(),
            value: c.minute,
            period: 60.0,
        },
        // Hour: mod 24.
        ThoughtAST::Circular {
            name: "hour".into(),
            value: c.hour,
            period: 24.0,
        },
        // Day of week: mod 7. 0 = Monday.
        ThoughtAST::Circular {
            name: "day-of-week".into(),
            value: c.day_of_week,
            period: 7.0,
        },
        // Day of month: mod 31.
        ThoughtAST::Circular {
            name: "day-of-month".into(),
            value: c.day_of_month,
            period: 31.0,
        },
        // Month of year: mod 12. 1 = January.
        ThoughtAST::Circular {
            name: "month-of-year".into(),
            value: c.month_of_year,
            period: 12.0,
        },
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
}
