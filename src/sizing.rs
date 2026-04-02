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
    _min_sample: usize, // rune:reap(scaffolding) — reserved for configurable minimum; callers pass 50
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

/// Compute the conviction threshold from history and resolved predictions.
///
/// Pure function: takes data in, returns threshold out.
/// Called every `recalib_interval` candles after warmup.
///
/// - `Quantile` mode: sorts conviction history, picks the quantile percentile.
/// - `Auto` mode: fits an exponential conviction-accuracy curve from resolved
///   predictions, then solves for the conviction where accuracy = min_edge.
///   Falls back to quantile during warmup.
pub fn compute_conviction_threshold(
    history: &VecDeque<f64>,
    resolved: &VecDeque<(f64, bool)>,
    mode: super::state::ConvictionMode,
    quantile: f64,
    min_edge: f64,
    warmup: usize,
) -> Option<f64> {
    // Precompute quantile threshold — used by Quantile mode and Auto fallback.
    let quantile_thresh = if quantile > 0.0 {
        let mut sorted: Vec<f64> = history.iter().copied().collect();
        sorted.sort_by(|a, b| a.partial_cmp(b).unwrap());
        let idx = ((sorted.len() as f64 * quantile) as usize)
            .min(sorted.len() - 1);
        Some(sorted[idx])
    } else {
        None
    };

    use super::state::ConvictionMode;
    match mode {
        ConvictionMode::Quantile if quantile_thresh.is_some() => {
            quantile_thresh
        }
        ConvictionMode::Auto if resolved.len() >= warmup * 5 => {
            // Need 5× warmup (~5000 resolved) for stable exponential fit.
            // Fit the exponential conviction-accuracy curve:
            //   accuracy = 0.50 + a × exp(b × conviction)
            // Then solve for threshold: conv = ln((min_edge - 0.50) / a) / b
            //
            // rune:scry(duplication) — bin + log-linear regression duplicated with kelly_frac
            // above. Both implement the same curve-fitting algorithm on resolved predictions.
            // Extract shared helper when this module grows. Recalib-frequency, not hot path.
            let n_bins = 20usize;
            let mut sorted: Vec<(f64, bool)> = resolved.iter().copied().collect();
            sorted.sort_by(|a, b| a.0.partial_cmp(&b.0).unwrap());
            let bin_size = sorted.len() / n_bins;
            if bin_size >= 20 {
                // Compute (mean_conviction, accuracy) per bin.
                let mut bins: Vec<(f64, f64)> = Vec::new();
                for bi in 0..n_bins {
                    let start = bi * bin_size;
                    let end = if bi == n_bins - 1 { sorted.len() } else { (bi + 1) * bin_size };
                    let slice = &sorted[start..end];
                    let mean_c: f64 = slice.iter().map(|(c, _)| c).sum::<f64>() / slice.len() as f64;
                    let acc: f64 = slice.iter().filter(|(_, w)| *w).count() as f64 / slice.len() as f64;
                    bins.push((mean_c, acc));
                }

                // Log-linear regression on bins where acc > 0.505.
                // y = ln(acc - 0.50), x = conviction → y = ln(a) + b*x
                let points: Vec<(f64, f64)> = bins.iter()
                    .filter(|(_, acc)| *acc > 0.505)
                    .map(|(c, acc)| (*c, (acc - 0.50).ln()))
                    .filter(|(_, y)| y.is_finite())
                    .collect();

                if points.len() >= 3 {
                    let n = points.len() as f64;
                    let (sx, sy, sxx, sxy) = points.iter().fold(
                        (0.0, 0.0, 0.0, 0.0),
                        |(sx, sy, sxx, sxy), (x, y)| {
                            (sx + x, sy + y, sxx + x * x, sxy + x * y)
                        },
                    );
                    let denom = n * sxx - sx * sx;
                    if denom.abs() > 1e-10 {
                        let b = (n * sxy - sx * sy) / denom;
                        let ln_a = (sy - b * sx) / n;
                        let a = ln_a.exp();

                        // Solve: min_edge = 0.50 + a * exp(b * conv)
                        // conv = ln((min_edge - 0.50) / a) / b
                        if b > 0.0 && min_edge > 0.50 {
                            let target = (min_edge - 0.50) / a;
                            if target > 0.0 {
                                let new_thresh = target.ln() / b;
                                if new_thresh > 0.0 && new_thresh < 1.0 {
                                    return Some(new_thresh);
                                }
                            }
                        }
                    }
                }
            }
            // Auto curve fit didn't produce a valid threshold — no change.
            None
        }
        // Fallback: during auto warmup, use quantile if available.
        ConvictionMode::Auto if quantile_thresh.is_some()
            && history.len() >= warmup => {
            quantile_thresh
        }
        _ => None,
    }
}

/// Scale an observation by how large the triggering move was vs the running average.
/// Bigger moves teach more strongly than typical moves.
pub fn signal_weight(abs_pct: f64, move_sum: &mut f64, move_count: &mut usize) -> f64 {
    *move_sum += abs_pct;
    *move_count += 1;
    abs_pct / (*move_sum / *move_count as f64)
}
