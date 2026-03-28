use crate::journal::{Outcome, Prediction};

// ─── Orchestration ───────────────────────────────────────────────────────────

pub fn orchestrate(
    mode: &str,
    vis: &Prediction,
    tht: &Prediction,
    vis_roll_acc: f64,
    tht_roll_acc: f64,
) -> (Option<Outcome>, f64) {
    let vd = vis.direction;
    let td = tht.direction;

    match mode {
        "visual-only"  => (vd, vis.conviction),
        "thought-only" => (td, tht.conviction),

        "agree-only" => match (vd, td) {
            (Some(v), Some(t)) if v == t =>
                (Some(v), (vis.conviction + tht.conviction) / 2.0),
            _ => (None, 0.0),
        },

        "meta-boost" => match (vd, td) {
            (Some(v), Some(t)) => {
                if v == t {
                    // Both agree — average conviction with a small boost.
                    (Some(v), (vis.conviction + tht.conviction) / 2.0 * 1.1)
                } else {
                    // Disagree — go with higher conviction at half strength.
                    if vis.conviction >= tht.conviction {
                        (Some(v), vis.conviction * 0.5)
                    } else {
                        (Some(t), tht.conviction * 0.5)
                    }
                }
            }
            (Some(v), None) => (Some(v), vis.conviction * 0.8),
            (None, Some(t)) => (Some(t), tht.conviction * 0.8),
            (None, None)    => (None, 0.0),
        },

        "weighted" => {
            // Weight each journal by how much better than chance it has been recently.
            let vw = (vis_roll_acc - 0.5).max(0.01);
            let tw = (tht_roll_acc - 0.5).max(0.01);
            let total = vw + tw;
            match (vd, td) {
                (Some(v), Some(t)) => {
                    if v == t {
                        (Some(v), vis.conviction * vw / total + tht.conviction * tw / total)
                    } else if vis.conviction * vw >= tht.conviction * tw {
                        (Some(v), vis.conviction * vw / total)
                    } else {
                        (Some(t), tht.conviction * tw / total)
                    }
                }
                (Some(v), None) => (Some(v), vis.conviction * 0.8),
                (None, Some(t)) => (Some(t), tht.conviction * 0.8),
                (None, None)    => (None, 0.0),
            }
        }

        // Thought sets direction and conviction (preserving its high flip threshold).
        // Visual acts as a binary veto: if visual has a direction and disagrees, skip.
        "thought-led" => match td {
            None => (None, 0.0),
            Some(t) => match vd {
                Some(v) if v != t => (None, 0.0), // visual veto
                _ => (Some(t), tht.conviction),
            },
        },

        // Thought direction, conviction amplified by visual conviction magnitude.
        // Visual strength confirms trend clarity regardless of direction.
        "thought-visual-amp" => match td {
            None => (None, 0.0),
            Some(t) => (Some(t), tht.conviction * (1.0 + vis.conviction)),
        },

        // Thought's flip zone, but ONLY when visual explicitly disagrees.
        // Visual disagreement = visual sees a strong trend; thought sees exhaustion.
        // Empirically: vis-disagree trades win 54.1% vs 52.7% when visual agrees.
        "thought-contrarian" => match (td, vd) {
            (Some(t), Some(v)) if v != t => (Some(t), tht.conviction),
            _ => (None, 0.0),
        },

        other => panic!("unknown orchestration mode: {}", other),
    }
}

// ─── Signal weight ───────────────────────────────────────────────────────────

/// Scale an observation by how large the triggering move was vs the running average.
/// Bigger moves teach more strongly than typical moves.
pub fn signal_weight(abs_pct: f64, move_sum: &mut f64, move_count: &mut usize) -> f64 {
    *move_sum += abs_pct;
    *move_count += 1;
    abs_pct / (*move_sum / *move_count as f64)
}
