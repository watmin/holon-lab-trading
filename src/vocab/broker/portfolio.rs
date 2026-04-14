/// Portfolio biography vocabulary — 10 atoms describing a broker's portfolio shape.
/// Phase 3 (Proposal 044). Moved from broker_program.rs.

use crate::encoding::thought_encoder::ThoughtAST;
use crate::types::pivot::{PhaseDirection, PhaseLabel, PhaseRecord};

/// Compute portfolio biography atoms from broker's active papers + phase data.
/// Returns (atoms, updated_max_papers_seen). Values up, not mutations down.
pub fn compute_portfolio_biography(
    papers: &std::collections::VecDeque<crate::trades::paper_entry::PaperEntry>,
    phase_history: &[PhaseRecord],
    max_papers_seen: usize,
) -> (Vec<ThoughtAST>, usize) {
    let active: Vec<&crate::trades::paper_entry::PaperEntry> = papers
        .iter()
        .filter(|p| !p.resolved)
        .collect();
    let active_count = active.len();

    // Return updated max — values up, not mutations down.
    let new_max = if active_count > max_papers_seen {
        active_count
    } else {
        max_papers_seen
    };

    let mut atoms = Vec::with_capacity(10);

    // 1. Active trade count
    atoms.push(ThoughtAST::Bind(Box::new(ThoughtAST::Atom("active-trade-count".into())), Box::new(ThoughtAST::Log { value: (active_count as f64).max(1.0) })));

    // 2. Oldest active trade's phase age (phases since its entry)
    let oldest_phases = active
        .iter()
        .map(|p| {
            phase_history
                .iter()
                .filter(|r| r.start_candle >= p.entry_candle)
                .count()
        })
        .max()
        .unwrap_or(0);
    atoms.push(ThoughtAST::Bind(Box::new(ThoughtAST::Atom("oldest-trade-phases".into())), Box::new(ThoughtAST::Log { value: (oldest_phases as f64).max(1.0) })));

    // 3. Newest active trade's phase age
    let newest_phases = active
        .iter()
        .map(|p| {
            phase_history
                .iter()
                .filter(|r| r.start_candle >= p.entry_candle)
                .count()
        })
        .min()
        .unwrap_or(0);
    atoms.push(ThoughtAST::Bind(Box::new(ThoughtAST::Atom("newest-trade-phases".into())), Box::new(ThoughtAST::Log { value: (newest_phases as f64).max(1.0) })));

    // 4. Weighted average excursion across active trades
    let avg_excursion = if active_count > 0 {
        active.iter().map(|p| p.excursion()).sum::<f64>() / active_count as f64
    } else {
        0.0
    };
    atoms.push(ThoughtAST::Bind(Box::new(ThoughtAST::Atom("portfolio-excursion".into())), Box::new(ThoughtAST::Log { value: avg_excursion.abs().max(0.0001) })));

    // 5. Portfolio heat: active_count / max_seen
    let heat = if new_max > 0 {
        active_count as f64 / new_max as f64
    } else {
        0.0
    };
    atoms.push(ThoughtAST::Bind(Box::new(ThoughtAST::Atom("portfolio-heat".into())), Box::new(ThoughtAST::Linear { value: heat, scale: 1.0 })));

    // Fused single pass over phase_history: collect valleys, peaks, durations,
    // duration stats, and favorable entry records in one iteration.
    let mut last_two_valleys: [Option<f64>; 2] = [None; 2];
    let mut last_two_peaks: [Option<f64>; 2] = [None; 2];
    let mut duration_sum: f64 = 0.0;
    let mut duration_sq_sum: f64 = 0.0;
    let mut phase_count: usize = 0;
    let mut favorable_phases: Vec<(usize, usize)> = Vec::new();

    for r in phase_history.iter() {
        let dur = r.duration as f64;
        duration_sum += dur;
        duration_sq_sum += dur * dur;
        phase_count += 1;

        match r.label {
            PhaseLabel::Valley => {
                last_two_valleys[0] = last_two_valleys[1];
                last_two_valleys[1] = Some(r.close_avg);
            }
            PhaseLabel::Peak => {
                last_two_peaks[0] = last_two_peaks[1];
                last_two_peaks[1] = Some(r.close_avg);
            }
            _ => {}
        }

        if r.label == PhaseLabel::Valley
            || (r.label == PhaseLabel::Transition && r.direction == PhaseDirection::Up)
        {
            favorable_phases.push((r.start_candle, r.end_candle));
        }
    }

    // 6. Valley trend
    let valley_trend = match (last_two_valleys[0], last_two_valleys[1]) {
        (Some(prev), Some(last)) if prev > 0.0 => (last - prev) / prev,
        _ => 0.0,
    };
    atoms.push(ThoughtAST::Bind(Box::new(ThoughtAST::Atom("broker-phase-valley-trend".into())), Box::new(ThoughtAST::Linear { value: valley_trend, scale: 1.0 })));

    // 7. Peak trend
    let peak_trend = match (last_two_peaks[0], last_two_peaks[1]) {
        (Some(prev), Some(last)) if prev > 0.0 => (last - prev) / prev,
        _ => 0.0,
    };
    atoms.push(ThoughtAST::Bind(Box::new(ThoughtAST::Atom("broker-phase-peak-trend".into())), Box::new(ThoughtAST::Linear { value: peak_trend, scale: 1.0 })));

    // 8. Regularity: CV of phase durations
    let regularity = if phase_count >= 2 {
        let mean = duration_sum / phase_count as f64;
        if mean > 0.0 {
            let variance = duration_sq_sum / phase_count as f64 - mean * mean;
            variance.max(0.0).sqrt() / mean
        } else {
            0.0
        }
    } else {
        0.0
    };
    atoms.push(ThoughtAST::Bind(Box::new(ThoughtAST::Atom("broker-phase-regularity".into())), Box::new(ThoughtAST::Linear { value: regularity, scale: 1.0 })));

    // 9. Entry ratio
    let entry_ratio = if active_count > 0 {
        let favorable = active
            .iter()
            .filter(|p| {
                favorable_phases.iter().any(|(start, end)| {
                    p.entry_candle >= *start && p.entry_candle <= *end
                })
            })
            .count();
        favorable as f64 / active_count as f64
    } else {
        0.0
    };
    atoms.push(ThoughtAST::Bind(Box::new(ThoughtAST::Atom("broker-phase-entry-ratio".into())), Box::new(ThoughtAST::Linear { value: entry_ratio, scale: 1.0 })));

    // 10. Average spacing
    let avg_spacing = if phase_count > 0 {
        duration_sum / phase_count as f64
    } else {
        1.0
    };
    atoms.push(ThoughtAST::Bind(Box::new(ThoughtAST::Atom("broker-phase-avg-spacing".into())), Box::new(ThoughtAST::Log { value: avg_spacing.max(1.0) })));

    (atoms, new_max)
}
