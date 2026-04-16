// vocab/exit/phase.rs — Phase data for regime observers.
// Proposal 049, Phase 2: regime observer reads phase data from the Candle.
//
// Three outputs:
// 1. Current phase atoms: label binding + duration scalar
// 2. Phase series Sequential thought from phase_history
// 3. Phase scalar summaries: valley trend, peak trend, range trend, spacing trend
//
// Pure function: candle in, ASTs out.

use std::collections::HashMap;
use crate::types::candle::Candle;
use crate::types::pivot::{PhaseDirection, PhaseLabel, PhaseRecord};
use crate::encoding::thought_encoder::{ThoughtAST, round_to};
use crate::encoding::scale_tracker::{ScaleTracker, scaled_linear};

/// Build a Bind(phase, <label>) atom from a PhaseLabel + PhaseDirection.
fn phase_label_atom(label: PhaseLabel, direction: PhaseDirection) -> ThoughtAST {
    let label_name = match label {
        PhaseLabel::Valley => "valley",
        PhaseLabel::Peak => "peak",
        PhaseLabel::Transition => match direction {
            PhaseDirection::Up => "transition-up",
            PhaseDirection::Down => "transition-down",
            PhaseDirection::None => "transition",
        },
    };
    ThoughtAST::Bind(
        Box::new(ThoughtAST::Atom("phase".into())),
        Box::new(ThoughtAST::Atom(label_name.into())),
    )
}

/// Current phase atoms: the label binding + phase duration as a linear scalar.
pub fn encode_phase_current_facts(
    c: &Candle,
    scales: &mut HashMap<String, ScaleTracker>,
) -> Vec<ThoughtAST> {
    vec![
        phase_label_atom(c.phase_label, c.phase_direction),
        scaled_linear("phase-duration", c.phase_duration as f64, scales),
    ]
}

/// Build a Sequential thought from the phase history.
/// Each PhaseRecord becomes a Bundle of its attributes.
/// Oldest to newest (the history is already chronological).
/// Returns an empty Bundle if no history yet.
pub fn phase_series_thought(phase_history: &[PhaseRecord]) -> ThoughtAST {
    if phase_history.is_empty() {
        return ThoughtAST::Bundle(vec![]);
    }

    let items: Vec<ThoughtAST> = phase_history
        .iter()
        .map(|record| {
            let label_atom = phase_label_atom(record.label, record.direction);

            let range = if record.close_avg > 0.0 {
                round_to(
                    (record.close_max - record.close_min) / record.close_avg,
                    4,
                )
            } else {
                0.0
            };

            let move_pct = if record.close_open > 0.0 {
                round_to(
                    (record.close_final - record.close_open) / record.close_open,
                    4,
                )
            } else {
                0.0
            };

            ThoughtAST::Bundle(vec![
                label_atom,
                ThoughtAST::Bind(Box::new(ThoughtAST::Atom("phase-rec-duration".into())), Box::new(ThoughtAST::Log { value: (record.duration as f64).max(1.0) })),
                ThoughtAST::Bind(Box::new(ThoughtAST::Atom("phase-rec-range".into())), Box::new(ThoughtAST::Linear { value: range, scale: 1.0 })),
                ThoughtAST::Bind(Box::new(ThoughtAST::Atom("phase-rec-move".into())), Box::new(ThoughtAST::Linear { value: move_pct, scale: 1.0 })),
                ThoughtAST::Bind(Box::new(ThoughtAST::Atom("phase-rec-volume".into())), Box::new(ThoughtAST::Linear { value: round_to(record.volume_avg, 2), scale: 1.0 })),
            ])
        })
        .collect();

    ThoughtAST::Sequential(items)
}

/// Build a phase rhythm AST from the phase history. Proposal 056.
///
/// Each phase record: own properties + prior-bundle deltas + prior-same-phase deltas.
/// Thermometer encoding. Bundled bigrams of trigrams.
/// Returns one ThoughtAST: (bind (atom "phase-rhythm") (bundle ...pairs...))
pub fn phase_rhythm_thought(phase_history: &[PhaseRecord]) -> ThoughtAST {
    if phase_history.len() < 4 {
        return ThoughtAST::Bundle(vec![]);
    }

    let mut last_valley: Option<usize> = None;
    let mut last_peak: Option<usize> = None;
    let mut last_trans_up: Option<usize> = None;
    let mut last_trans_down: Option<usize> = None;

    fn props(r: &PhaseRecord) -> (f64, f64, f64, f64) {
        let dur = r.duration as f64;
        let range = if r.close_avg > 0.0 { (r.close_max - r.close_min) / r.close_avg } else { 0.0 };
        let mv = if r.close_open > 0.0 { (r.close_final - r.close_open) / r.close_open } else { 0.0 };
        (dur, range, mv, r.volume_avg)
    }

    fn rel(a: f64, b: f64) -> f64 {
        if b.abs() > 0.0001 { (a - b) / b.abs() } else { 0.0 }
    }

    let records: Vec<ThoughtAST> = phase_history.iter().enumerate().map(|(i, record)| {
        let (dur, range, mv, vol) = props(record);
        let label = phase_label_atom(record.label, record.direction);

        let mut facts = vec![
            label,
            ThoughtAST::Bind(Box::new(ThoughtAST::Atom("rec-duration".into())),
                Box::new(ThoughtAST::Thermometer { value: dur, min: 0.0, max: 200.0 })),
            ThoughtAST::Bind(Box::new(ThoughtAST::Atom("rec-move".into())),
                Box::new(ThoughtAST::Thermometer { value: mv, min: -0.1, max: 0.1 })),
            ThoughtAST::Bind(Box::new(ThoughtAST::Atom("rec-range".into())),
                Box::new(ThoughtAST::Thermometer { value: range, min: 0.0, max: 0.1 })),
            ThoughtAST::Bind(Box::new(ThoughtAST::Atom("rec-volume".into())),
                Box::new(ThoughtAST::Thermometer { value: vol, min: 0.0, max: 10000.0 })),
        ];

        if i > 0 {
            let (p_dur, _, p_mv, p_vol) = props(&phase_history[i - 1]);
            facts.push(ThoughtAST::Bind(Box::new(ThoughtAST::Atom("prior-duration-delta".into())),
                Box::new(ThoughtAST::Thermometer { value: rel(dur, p_dur), min: -2.0, max: 2.0 })));
            facts.push(ThoughtAST::Bind(Box::new(ThoughtAST::Atom("prior-move-delta".into())),
                Box::new(ThoughtAST::Thermometer { value: mv - p_mv, min: -0.1, max: 0.1 })));
            facts.push(ThoughtAST::Bind(Box::new(ThoughtAST::Atom("prior-volume-delta".into())),
                Box::new(ThoughtAST::Thermometer { value: rel(vol, p_vol), min: -2.0, max: 2.0 })));
        }

        let same_idx = match (record.label, record.direction) {
            (PhaseLabel::Valley, _) => last_valley,
            (PhaseLabel::Peak, _) => last_peak,
            (PhaseLabel::Transition, PhaseDirection::Up) => last_trans_up,
            (PhaseLabel::Transition, PhaseDirection::Down) => last_trans_down,
            _ => None,
        };
        if let Some(si) = same_idx {
            let (s_dur, _, s_mv, s_vol) = props(&phase_history[si]);
            facts.push(ThoughtAST::Bind(Box::new(ThoughtAST::Atom("same-move-delta".into())),
                Box::new(ThoughtAST::Thermometer { value: mv - s_mv, min: -0.1, max: 0.1 })));
            facts.push(ThoughtAST::Bind(Box::new(ThoughtAST::Atom("same-duration-delta".into())),
                Box::new(ThoughtAST::Thermometer { value: rel(dur, s_dur), min: -2.0, max: 2.0 })));
            facts.push(ThoughtAST::Bind(Box::new(ThoughtAST::Atom("same-volume-delta".into())),
                Box::new(ThoughtAST::Thermometer { value: rel(vol, s_vol), min: -2.0, max: 2.0 })));
        }

        match (record.label, record.direction) {
            (PhaseLabel::Valley, _) => last_valley = Some(i),
            (PhaseLabel::Peak, _) => last_peak = Some(i),
            (PhaseLabel::Transition, PhaseDirection::Up) => last_trans_up = Some(i),
            (PhaseLabel::Transition, PhaseDirection::Down) => last_trans_down = Some(i),
            _ => {}
        }

        ThoughtAST::Bundle(facts)
    }).collect();

    let budget = ((10_000 as f64).sqrt()) as usize;
    let max_records = budget + 3;
    let records = if records.len() > max_records {
        &records[records.len() - max_records..]
    } else {
        &records[..]
    };

    let trigrams: Vec<ThoughtAST> = records.windows(3).map(|w| {
        ThoughtAST::Bind(
            Box::new(ThoughtAST::Bind(
                Box::new(w[0].clone()),
                Box::new(ThoughtAST::Permute(Box::new(w[1].clone()), 1)),
            )),
            Box::new(ThoughtAST::Permute(Box::new(w[2].clone()), 2)),
        )
    }).collect();

    let pairs: Vec<ThoughtAST> = trigrams.windows(2).map(|w| {
        ThoughtAST::Bind(Box::new(w[0].clone()), Box::new(w[1].clone()))
    }).collect();

    if pairs.is_empty() {
        return ThoughtAST::Bundle(vec![]);
    }

    let start = if pairs.len() > budget { pairs.len() - budget } else { 0 };
    let trimmed: Vec<ThoughtAST> = pairs[start..].to_vec();

    ThoughtAST::Bind(
        Box::new(ThoughtAST::Atom("phase-rhythm".into())),
        Box::new(ThoughtAST::Bundle(trimmed)),
    )
}

/// Scalar summary facts computed from the phase history.
/// Complements the Sequential's implicit geometry with explicit measurements.
pub fn phase_scalar_facts(
    phase_history: &[PhaseRecord],
    scales: &mut HashMap<String, ScaleTracker>,
) -> Vec<ThoughtAST> {
    let mut facts = Vec::new();

    if phase_history.len() < 2 {
        return facts;
    }

    // Valley-to-valley trend: are the valleys rising?
    let valleys: Vec<&PhaseRecord> = phase_history
        .iter()
        .filter(|r| r.label == PhaseLabel::Valley)
        .collect();
    if valleys.len() >= 2 {
        let last = valleys[valleys.len() - 1];
        let prev = valleys[valleys.len() - 2];
        if prev.close_avg > 0.0 {
            let trend = round_to((last.close_avg - prev.close_avg) / prev.close_avg, 4);
            facts.push(scaled_linear("phase-valley-trend", trend, scales));
        }
    }

    // Peak-to-peak trend: are the peaks compressing?
    let peaks: Vec<&PhaseRecord> = phase_history
        .iter()
        .filter(|r| r.label == PhaseLabel::Peak)
        .collect();
    if peaks.len() >= 2 {
        let last = peaks[peaks.len() - 1];
        let prev = peaks[peaks.len() - 2];
        if prev.close_avg > 0.0 {
            let trend = round_to((last.close_avg - prev.close_avg) / prev.close_avg, 4);
            facts.push(scaled_linear("phase-peak-trend", trend, scales));
        }
    }

    // Range trend: are the swings expanding or contracting?
    let last = &phase_history[phase_history.len() - 1];
    let prev = &phase_history[phase_history.len() - 2];
    let last_range = last.close_max - last.close_min;
    let prev_range = prev.close_max - prev.close_min;
    if prev_range > 0.0 {
        let ratio = round_to(last_range / prev_range, 2);
        facts.push(scaled_linear("phase-range-trend", ratio, scales));
    }

    // Spacing trend: are phases getting shorter or longer?
    if prev.duration > 0 {
        let ratio = round_to(last.duration as f64 / prev.duration as f64, 2);
        facts.push(scaled_linear("phase-spacing-trend", ratio, scales));
    }

    facts
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_phase_label_atom_valley() {
        let atom = phase_label_atom(PhaseLabel::Valley, PhaseDirection::None);
        match atom {
            ThoughtAST::Bind(left, right) => {
                assert_eq!(*left, ThoughtAST::Atom("phase".into()));
                assert_eq!(*right, ThoughtAST::Atom("valley".into()));
            }
            _ => panic!("expected Bind"),
        }
    }

    #[test]
    fn test_phase_label_atom_peak() {
        let atom = phase_label_atom(PhaseLabel::Peak, PhaseDirection::None);
        match atom {
            ThoughtAST::Bind(_, right) => {
                assert_eq!(*right, ThoughtAST::Atom("peak".into()));
            }
            _ => panic!("expected Bind"),
        }
    }

    #[test]
    fn test_phase_label_atom_transition_up() {
        let atom = phase_label_atom(PhaseLabel::Transition, PhaseDirection::Up);
        match atom {
            ThoughtAST::Bind(_, right) => {
                assert_eq!(*right, ThoughtAST::Atom("transition-up".into()));
            }
            _ => panic!("expected Bind"),
        }
    }

    #[test]
    fn test_phase_label_atom_transition_down() {
        let atom = phase_label_atom(PhaseLabel::Transition, PhaseDirection::Down);
        match atom {
            ThoughtAST::Bind(_, right) => {
                assert_eq!(*right, ThoughtAST::Atom("transition-down".into()));
            }
            _ => panic!("expected Bind"),
        }
    }

    #[test]
    fn test_current_phase_facts() {
        let c = Candle::default();
        let mut scales = HashMap::new();
        let facts = encode_phase_current_facts(&c, &mut scales);
        assert_eq!(facts.len(), 2);
        // First is the label binding
        assert!(matches!(&facts[0], ThoughtAST::Bind(_, _)));
        // Second is the duration (Bind(Atom("phase-duration"), Linear{..}))
        match &facts[1] {
            ThoughtAST::Bind(left, right) => {
                match (left.as_ref(), right.as_ref()) {
                    (ThoughtAST::Atom(name), ThoughtAST::Linear { .. }) => {
                        assert_eq!(name, "phase-duration");
                    }
                    _ => panic!("expected Bind(Atom, Linear)"),
                }
            }
            _ => panic!("expected Bind for phase-duration"),
        }
    }

    #[test]
    fn test_phase_series_empty() {
        let thought = phase_series_thought(&[]);
        assert!(matches!(thought, ThoughtAST::Bundle(ref v) if v.is_empty()));
    }

    #[test]
    fn test_phase_series_one_record() {
        let record = PhaseRecord {
            label: PhaseLabel::Valley,
            direction: PhaseDirection::None,
            start_candle: 0,
            end_candle: 5,
            duration: 5,
            close_min: 100.0,
            close_max: 105.0,
            close_avg: 102.0,
            close_open: 100.0,
            close_final: 104.0,
            volume_avg: 50.0,
        };
        let thought = phase_series_thought(&[record]);
        assert!(matches!(thought, ThoughtAST::Sequential(ref items) if items.len() == 1));
    }

    #[test]
    fn test_phase_series_multiple_records() {
        let records = vec![
            PhaseRecord {
                label: PhaseLabel::Valley,
                direction: PhaseDirection::None,
                start_candle: 0, end_candle: 5, duration: 5,
                close_min: 100.0, close_max: 105.0, close_avg: 102.0,
                close_open: 100.0, close_final: 104.0, volume_avg: 50.0,
            },
            PhaseRecord {
                label: PhaseLabel::Transition,
                direction: PhaseDirection::Up,
                start_candle: 5, end_candle: 8, duration: 3,
                close_min: 104.0, close_max: 110.0, close_avg: 107.0,
                close_open: 104.0, close_final: 110.0, volume_avg: 60.0,
            },
            PhaseRecord {
                label: PhaseLabel::Peak,
                direction: PhaseDirection::None,
                start_candle: 8, end_candle: 12, duration: 4,
                close_min: 108.0, close_max: 112.0, close_avg: 110.0,
                close_open: 110.0, close_final: 109.0, volume_avg: 55.0,
            },
        ];
        let thought = phase_series_thought(&records);
        match thought {
            ThoughtAST::Sequential(items) => {
                assert_eq!(items.len(), 3);
                // Each item is a Bundle
                for item in &items {
                    assert!(matches!(item, ThoughtAST::Bundle(_)));
                }
            }
            _ => panic!("expected Sequential"),
        }
    }

    #[test]
    fn test_phase_scalar_facts_insufficient_history() {
        let mut scales = HashMap::new();
        // 0 records
        let facts = phase_scalar_facts(&[], &mut scales);
        assert!(facts.is_empty());
        // 1 record
        let record = PhaseRecord {
            label: PhaseLabel::Valley, direction: PhaseDirection::None,
            start_candle: 0, end_candle: 5, duration: 5,
            close_min: 100.0, close_max: 105.0, close_avg: 102.0,
            close_open: 100.0, close_final: 104.0, volume_avg: 50.0,
        };
        let facts = phase_scalar_facts(&[record], &mut scales);
        assert!(facts.is_empty());
    }

    #[test]
    fn test_phase_scalar_facts_with_valleys() {
        let mut scales = HashMap::new();
        let records = vec![
            PhaseRecord {
                label: PhaseLabel::Valley, direction: PhaseDirection::None,
                start_candle: 0, end_candle: 5, duration: 5,
                close_min: 95.0, close_max: 100.0, close_avg: 97.0,
                close_open: 96.0, close_final: 99.0, volume_avg: 50.0,
            },
            PhaseRecord {
                label: PhaseLabel::Transition, direction: PhaseDirection::Up,
                start_candle: 5, end_candle: 8, duration: 3,
                close_min: 99.0, close_max: 108.0, close_avg: 104.0,
                close_open: 99.0, close_final: 108.0, volume_avg: 60.0,
            },
            PhaseRecord {
                label: PhaseLabel::Valley, direction: PhaseDirection::None,
                start_candle: 8, end_candle: 14, duration: 6,
                close_min: 100.0, close_max: 105.0, close_avg: 102.0,
                close_open: 103.0, close_final: 101.0, volume_avg: 55.0,
            },
        ];
        let facts = phase_scalar_facts(&records, &mut scales);
        // Should have valley-trend + range-trend + spacing-trend (at least)
        assert!(!facts.is_empty());
        // Extract atom names from Bind(Atom(name), _) nodes
        let names: Vec<String> = facts.iter().map(|f| {
            match f {
                ThoughtAST::Bind(left, _) => match left.as_ref() {
                    ThoughtAST::Atom(name) => name.clone(),
                    _ => f.name(),
                },
                _ => f.name(),
            }
        }).collect();
        assert!(names.contains(&"phase-valley-trend".to_string()));
        assert!(names.contains(&"phase-range-trend".to_string()));
        assert!(names.contains(&"phase-spacing-trend".to_string()));
    }
}
