/// Portfolio vocabulary — the broker's own state as indicator rhythms.
///
/// 5 per-candle scalars sampled into a window, each encoded as a
/// bundled-bigram-of-trigrams rhythm AST (Proposal 056).
/// Supersedes Proposal 044's static biography atoms.
///
/// Bounds (min, max, delta_range) define what "normal" means for
/// each scalar. The discriminant learns which rhythms carry signal.

use crate::encoding::thought_encoder::ThoughtAST;
use crate::encoding::rhythm::indicator_rhythm;

/// One-candle snapshot of broker portfolio state. The broker pushes
/// one into its window per candle; `portfolio_rhythm_asts` samples
/// the window into rhythm ASTs.
pub struct PortfolioSnapshot {
    pub avg_age: f64,
    pub avg_tp: f64,
    pub avg_unrealized: f64,
    pub grace_rate: f64,
    pub active_count: f64,
}

/// Build portfolio rhythm ASTs from the snapshot window.
/// Five rhythms, one per portfolio dimension. Bounds are vocabulary —
/// they declare the expected range of each scalar.
pub fn portfolio_rhythm_asts(snapshots: &[PortfolioSnapshot]) -> Vec<ThoughtAST> {
    let extract_and_build = |name: &str,
                             extract: fn(&PortfolioSnapshot) -> f64,
                             min: f64,
                             max: f64,
                             delta_range: f64|
     -> ThoughtAST {
        let values: Vec<f64> = snapshots.iter().map(extract).collect();
        indicator_rhythm(name, &values, min, max, delta_range)
    };

    vec![
        extract_and_build("avg-paper-age",          |s| s.avg_age,        0.0,  500.0, 100.0),
        extract_and_build("avg-time-pressure",      |s| s.avg_tp,         0.0,    1.0,   0.2),
        extract_and_build("avg-unrealized-residue", |s| s.avg_unrealized, -0.1,   0.1,   0.05),
        extract_and_build("grace-rate",             |s| s.grace_rate,     0.0,    1.0,   0.2),
        extract_and_build("active-positions",       |s| s.active_count,   0.0,  500.0, 100.0),
    ]
}
