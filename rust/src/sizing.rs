use std::collections::VecDeque;

/// Kelly position sizing from the exponential conviction-accuracy curve.
///
/// Uses the fitted curve `accuracy = 0.50 + a × exp(b × conviction)` to
/// estimate win rate at any conviction level — no per-level sample minimum.
/// The curve generalizes from ALL resolved predictions.
///
/// Falls back to cumulative estimate if curve fit not available.
/// Returns (position_frac, curve_a, curve_b) or None.
pub fn kelly_frac(
    conviction: f64,
    resolved: &VecDeque<(f64, bool)>,
    min_sample: usize,
    move_threshold: f64,
) -> Option<(f64, f64, f64)> {
    if resolved.len() < 500 { return None; }

    // Fit the exponential curve from resolved predictions (binned).
    let n_bins = 20usize;
    let mut sorted: Vec<(f64, bool)> = resolved.iter().copied().collect();
    sorted.sort_by(|a, b| a.0.partial_cmp(&b.0).unwrap());
    let bin_size = sorted.len() / n_bins;
    if bin_size < 10 { return None; }

    let mut points: Vec<(f64, f64)> = Vec::new();
    for bi in 0..n_bins {
        let start = bi * bin_size;
        let end = if bi == n_bins - 1 { sorted.len() } else { (bi + 1) * bin_size };
        let slice = &sorted[start..end];
        let mean_c = slice.iter().map(|(c, _)| c).sum::<f64>() / slice.len() as f64;
        let acc = slice.iter().filter(|(_, w)| *w).count() as f64 / slice.len() as f64;
        if acc > 0.505 {
            if let Some(ln_excess) = Some((acc - 0.50).ln()) {
                if ln_excess.is_finite() {
                    points.push((mean_c, ln_excess));
                }
            }
        }
    }

    // Log-linear regression: ln(acc - 0.50) = ln(a) + b * conviction
    let (win_rate, curve_a, curve_b) = if points.len() >= 3 {
        let n = points.len() as f64;
        let sx: f64 = points.iter().map(|(x, _)| x).sum();
        let sy: f64 = points.iter().map(|(_, y)| y).sum();
        let sxx: f64 = points.iter().map(|(x, _)| x * x).sum();
        let sxy: f64 = points.iter().map(|(x, y)| x * y).sum();
        let denom = n * sxx - sx * sx;
        if denom.abs() > 1e-10 {
            let b = (n * sxy - sx * sy) / denom;
            let ln_a = (sy - b * sx) / n;
            let a = ln_a.exp();
            let wr = (0.50 + a * (b * conviction).exp()).min(0.95);
            (wr, a, b)
        } else { return None; }
    } else { return None; };

    let edge = 2.0 * win_rate - 1.0;
    if edge <= 0.0 { return None; }
    let half_kelly_risk = edge / 2.0;
    let position = half_kelly_risk / move_threshold;
    Some((position, curve_a, curve_b))
}
