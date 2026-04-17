use std::sync::Arc;
// vocab/shared/time.rs — compiled from wat/vocab/shared/time.wat
//
// Temporal context. All circular scalars — the value wraps.
// atoms: minute, hour, day-of-week, day-of-month, month-of-year
//
// Exports two functions:
//   - encode_time_facts: 5 leaf binds (one per time component)
//   - time_facts: 5 leaves + 3 compositions
//     (minute×hour, hour×day-of-week, day-of-week×month)
//
// Both are vocabulary. The thinker bundles whatever set it wants.
// The discriminant picks the winners.

use crate::types::candle::Candle;
use crate::encoding::thought_encoder::{ThoughtAST, ThoughtASTKind, round_to};

fn bind(left: ThoughtAST, right: ThoughtAST) -> ThoughtAST {
    ThoughtAST::new(ThoughtASTKind::Bind(Arc::new(left), Arc::new(right)))
}

fn atom(name: &str) -> ThoughtAST {
    ThoughtAST::new(ThoughtASTKind::Atom(name.into()))
}

fn circ(value: f64, period: f64) -> ThoughtAST {
    ThoughtAST::new(ThoughtASTKind::Circular {
        value: round_to(value, 0),
        period,
    })
}

/// Five leaf time binds — one per circular time component.
pub fn encode_time_facts(c: &Candle) -> Vec<ThoughtAST> {
    vec![
        bind(atom("minute"),        circ(c.minute,        60.0)),
        bind(atom("hour"),          circ(c.hour,          24.0)),
        bind(atom("day-of-week"),   circ(c.day_of_week,   7.0)),
        bind(atom("day-of-month"),  circ(c.day_of_month,  31.0)),
        bind(atom("month-of-year"), circ(c.month_of_year, 12.0)),
    ]
}

/// Rich time vocabulary: 5 leaf binds + 3 pairwise compositions.
/// Compositions express "this pair matters together" — the discriminant
/// learns whether the composite carries signal the leaves don't.
///
/// The three compositions: minute×hour, hour×day-of-week, day-of-week×month.
pub fn time_facts(c: &Candle) -> Vec<ThoughtAST> {
    let minute = bind(atom("minute"),        circ(c.minute,        60.0));
    let hour   = bind(atom("hour"),          circ(c.hour,          24.0));
    let dow    = bind(atom("day-of-week"),   circ(c.day_of_week,   7.0));
    let dom    = bind(atom("day-of-month"),  circ(c.day_of_month,  31.0));
    let month  = bind(atom("month-of-year"), circ(c.month_of_year, 12.0));

    let minute_x_hour = bind(minute.clone(), hour.clone());
    let hour_x_dow    = bind(hour.clone(),   dow.clone());
    let dow_x_month   = bind(dow.clone(),    month.clone());

    vec![minute, hour, dow, dom, month, minute_x_hour, hour_x_dow, dow_x_month]
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
        match &facts[1].kind {
            ThoughtASTKind::Bind(left, right) => {
                match (&left.kind, &right.kind) {
                    (ThoughtASTKind::Atom(name), ThoughtASTKind::Circular { value, period }) => {
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
    fn test_time_facts_count() {
        let c = Candle::default();
        let facts = time_facts(&c);
        assert_eq!(facts.len(), 8); // 5 leaves + 3 compositions
    }

    #[test]
    fn test_time_facts_compositions_are_binds_of_binds() {
        let c = Candle::default();
        let facts = time_facts(&c);
        // Index 5: minute×hour. Should be Bind(Bind, Bind).
        match &facts[5].kind {
            ThoughtASTKind::Bind(left, right) => {
                assert!(matches!(left.kind, ThoughtASTKind::Bind(_, _)));
                assert!(matches!(right.kind, ThoughtASTKind::Bind(_, _)));
            }
            _ => panic!("expected Bind"),
        }
    }
}
