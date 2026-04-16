use std::sync::Arc;
/// Trade atom vocabulary — 13 atoms describing a paper trade's state.
/// Proposal 040 + Phase 3 biography (Proposal 044).
/// Moved from regime_observer_program.rs.

use crate::encoding::thought_encoder::ThoughtAST;
use crate::types::enums::RegimeLens;
use crate::types::pivot::{PhaseLabel, PhaseRecord};
use crate::trades::paper_entry::PaperEntry;

/// Compute trade atoms from a paper's state.
///
/// Returns the full 13-atom vocabulary (10 original + 3 phase biography).
/// The caller selects the subset based on RegimeLens (Core = first 5, Full = all 13).
pub fn compute_trade_atoms(paper: &PaperEntry, current_price: f64, phase_history: &[PhaseRecord]) -> Vec<ThoughtAST> {
    let entry = paper.entry_price.0;
    let extreme = paper.extreme;
    let excursion = ((extreme - entry) / entry).abs();
    let retracement = if excursion > 0.0001 {
        ((extreme - current_price) / (extreme - entry)).abs().min(1.0)
    } else {
        0.0
    };
    let age = paper.age as f64;

    // peak_age: candles since the extreme was last set.
    let peak_age = {
        let mut pa = 0.0;
        for (i, &p) in paper.price_history.iter().enumerate().rev() {
            if (p - extreme).abs() < 1e-10 {
                pa = (paper.price_history.len() - 1 - i) as f64;
                break;
            }
        }
        pa
    };

    let signaled = if paper.signaled { 1.0 } else { 0.0 };
    let trail_distance = paper.distances.trail;
    let stop_distance = paper.distances.stop;
    let initial_risk = paper.distances.stop;
    let r_multiple = if initial_risk > 0.0001 {
        excursion / initial_risk
    } else {
        0.0
    };
    let remaining_profit = (excursion - retracement * excursion).max(0.0);
    let heat = if remaining_profit > 0.0001 {
        trail_distance / remaining_profit
    } else {
        1.0
    };
    let trail_cushion = if excursion > 0.0001 {
        ((current_price - paper.trail_level.0).abs() / (extreme - entry).abs()).min(1.0)
    } else {
        0.0
    };

    // Phase 3 trade biography atoms (Proposal 044)
    let phases_since_entry = {
        let count = phase_history
            .iter()
            .filter(|r| r.start_candle >= paper.entry_candle)
            .count();
        (count as f64).max(1.0)
    };
    let phases_survived = {
        let count = phase_history
            .iter()
            .filter(|r| r.start_candle >= paper.entry_candle && r.label == PhaseLabel::Peak)
            .count();
        (count as f64).max(1.0)
    };
    let entry_vs_phase_avg = {
        let entry = paper.entry_price.0;
        if phase_history.is_empty() || entry == 0.0 {
            0.0
        } else {
            let avg_phase_close: f64 = phase_history
                .iter()
                .map(|r| r.close_avg)
                .sum::<f64>()
                / phase_history.len() as f64;
            (entry - avg_phase_close) / entry
        }
    };

    vec![
        // Core 5 (all three agreed)
        ThoughtAST::Bind(Arc::new(ThoughtAST::Atom("exit-excursion".into())), Arc::new(ThoughtAST::Log { value: excursion.max(0.0001) })),
        ThoughtAST::Bind(Arc::new(ThoughtAST::Atom("exit-retracement".into())), Arc::new(ThoughtAST::Linear { value: retracement, scale: 1.0 })),
        ThoughtAST::Bind(Arc::new(ThoughtAST::Atom("exit-age".into())), Arc::new(ThoughtAST::Log { value: age.max(1.0) })),
        ThoughtAST::Bind(Arc::new(ThoughtAST::Atom("exit-peak-age".into())), Arc::new(ThoughtAST::Log { value: peak_age.max(1.0) })),
        ThoughtAST::Bind(Arc::new(ThoughtAST::Atom("exit-signaled".into())), Arc::new(ThoughtAST::Linear { value: signaled, scale: 1.0 })),
        // Seykota additions
        ThoughtAST::Bind(Arc::new(ThoughtAST::Atom("exit-trail-distance".into())), Arc::new(ThoughtAST::Log { value: trail_distance.max(0.0001) })),
        ThoughtAST::Bind(Arc::new(ThoughtAST::Atom("exit-stop-distance".into())), Arc::new(ThoughtAST::Log { value: stop_distance.max(0.0001) })),
        // Van Tharp additions
        ThoughtAST::Bind(Arc::new(ThoughtAST::Atom("exit-r-multiple".into())), Arc::new(ThoughtAST::Log { value: r_multiple.max(0.0001) })),
        ThoughtAST::Bind(Arc::new(ThoughtAST::Atom("exit-heat".into())), Arc::new(ThoughtAST::Linear { value: heat.min(1.0), scale: 1.0 })),
        // Wyckoff addition
        ThoughtAST::Bind(Arc::new(ThoughtAST::Atom("exit-trail-cushion".into())), Arc::new(ThoughtAST::Linear { value: trail_cushion, scale: 1.0 })),
        // phases-since-entry
        ThoughtAST::Bind(Arc::new(ThoughtAST::Atom("phases-since-entry".into())), Arc::new(ThoughtAST::Log { value: phases_since_entry })),
        // phases-survived
        ThoughtAST::Bind(Arc::new(ThoughtAST::Atom("phases-survived".into())), Arc::new(ThoughtAST::Log { value: phases_survived })),
        // entry-vs-phase-avg
        ThoughtAST::Bind(Arc::new(ThoughtAST::Atom("entry-vs-phase-avg".into())), Arc::new(ThoughtAST::Linear { value: entry_vs_phase_avg, scale: 1.0 })),
    ]
}

/// Select trade atoms for a given position lens.
/// Core = first 5 (the consensus). Full = all 13 (all three voices).
pub fn select_trade_atoms(lens: &RegimeLens, all_atoms: Vec<ThoughtAST>) -> Vec<ThoughtAST> {
    match lens {
        RegimeLens::Core => all_atoms.into_iter().take(5).collect(),
        RegimeLens::Full => all_atoms,
    }
}
