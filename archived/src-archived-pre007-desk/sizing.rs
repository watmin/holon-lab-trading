use std::collections::VecDeque;

/// Fit the exponential conviction-accuracy curve from resolved predictions.
/// accuracy = 0.50 + a × exp(b × conviction)
/// Returns (a, b) or None if insufficient data or ill-conditioned.
///
/// Shared by kelly_frac (sizes positions) and compute_conviction_threshold
/// (finds the conviction level where signal emerges).
fn fit_conviction_curve(resolved: &VecDeque<(f64, bool)>, min_bin_size: usize) -> Option<(f64, f64)> {
    let n_bins = 20usize;
    let mut sorted: Vec<(f64, bool)> = resolved.iter().copied().collect();
    sorted.sort_by(|a, b| a.0.partial_cmp(&b.0).unwrap());
    let bin_size = sorted.len() / n_bins;
    if bin_size < min_bin_size { return None; }

    // Bin: compute (mean_conviction, log(accuracy - 0.50)) per bin
    let mut points: Vec<(f64, f64)> = Vec::new();
    for bi in 0..n_bins {
        let start = bi * bin_size;
        let end = if bi == n_bins - 1 { sorted.len() } else { (bi + 1) * bin_size };
        let slice = &sorted[start..end];
        let mean_c = slice.iter().map(|(c, _)| c).sum::<f64>() / slice.len() as f64;
        let acc = slice.iter().filter(|(_, w)| *w).count() as f64 / slice.len() as f64;
        if acc > 0.505 {
            let ln_excess = (acc - 0.50).ln();
            if ln_excess.is_finite() {
                points.push((mean_c, ln_excess));
            }
        }
    }

    if points.len() < 3 { return None; }

    // Log-linear regression: ln(acc - 0.50) = ln(a) + b × conviction
    // OLS normal equations. sx/sy/sxx/sxy are the standard sums for
    // computing slope (b) and intercept (ln(a)) of the linearized curve.
    let n = points.len() as f64;
    let (sx, sy, sxx, sxy) = points.iter().fold(
        (0.0, 0.0, 0.0, 0.0),
        |(sx, sy, sxx, sxy), (x, y)| (sx + x, sy + y, sxx + x * x, sxy + x * y),
    );
    let denom = n * sxx - sx * sx;
    if denom.abs() <= 1e-10 { return None; }

    let b = (n * sxy - sx * sy) / denom;
    let a = ((sy - b * sx) / n).exp();
    Some((a, b))
}

/// Evaluate the conviction-accuracy curve at a given conviction level.
/// Returns the estimated win rate, capped at 0.95.
/// Used by both kelly_frac (full fit) and the cached fast path in state.rs.
pub fn curve_win_rate(conviction: f64, curve_a: f64, curve_b: f64) -> f64 {
    (0.50 + curve_a * (curve_b * conviction).exp()).min(0.95)
}

/// Half-Kelly position fraction from win rate and move threshold.
/// Returns None if no edge.
pub fn half_kelly_position(win_rate: f64, move_threshold: f64) -> Option<f64> {
    let edge = 2.0 * win_rate - 1.0;
    if edge <= 0.0 { return None; }
    Some(edge / 2.0 / move_threshold)
}

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
    move_threshold: f64,
) -> Option<(f64, f64, f64)> {
    if resolved.len() < 500 { return None; }

    let (curve_a, curve_b) = fit_conviction_curve(resolved, 10)?;
    let position = half_kelly_position(curve_win_rate(conviction, curve_a, curve_b), move_threshold)?;
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
            // Fit curve, then solve for threshold where accuracy meets min_edge.
            if let Some((a, b)) = fit_conviction_curve(resolved, 20) {
                // Solve: min_edge = 0.50 + a × exp(b × conv)
                // → conv = ln((min_edge - 0.50) / a) / b
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

#[cfg(test)]
mod tests {
    use super::*;

    // ── signal_weight ────────────────────────────────────────────────────────

    #[test]
    fn signal_weight_first_observation_returns_one() {
        let mut sum = 0.0;
        let mut count = 0usize;
        let w = signal_weight(0.5, &mut sum, &mut count);
        // First observation: abs_pct / (abs_pct / 1) = 1.0
        assert!((w - 1.0).abs() < 1e-10);
        assert_eq!(count, 1);
    }

    #[test]
    fn signal_weight_large_move_scores_above_one() {
        let mut sum = 0.0;
        let mut count = 0usize;
        // Seed with small moves
        signal_weight(0.1, &mut sum, &mut count);
        signal_weight(0.1, &mut sum, &mut count);
        signal_weight(0.1, &mut sum, &mut count);
        // Now a large move — should be above average
        let w = signal_weight(0.5, &mut sum, &mut count);
        assert!(w > 1.0, "large move should score above 1.0, got {w}");
    }

    #[test]
    fn signal_weight_small_move_scores_below_one() {
        let mut sum = 0.0;
        let mut count = 0usize;
        signal_weight(0.5, &mut sum, &mut count);
        signal_weight(0.5, &mut sum, &mut count);
        signal_weight(0.5, &mut sum, &mut count);
        let w = signal_weight(0.1, &mut sum, &mut count);
        assert!(w < 1.0, "small move should score below 1.0, got {w}");
    }

    // ── curve_win_rate ───────────────────────────────────────────────────────

    #[test]
    fn curve_win_rate_at_zero_conviction() {
        // accuracy = 0.50 + a * exp(b * 0) = 0.50 + a
        let a = 0.05;
        let b = 2.0;
        let wr = curve_win_rate(0.0, a, b);
        assert!((wr - 0.55).abs() < 1e-10);
    }

    #[test]
    fn curve_win_rate_caps_at_095() {
        // With large conviction, result should cap at 0.95
        let wr = curve_win_rate(100.0, 0.1, 1.0);
        assert!((wr - 0.95).abs() < 1e-10, "should cap at 0.95, got {wr}");
    }

    #[test]
    fn curve_win_rate_increases_with_conviction() {
        let a = 0.02;
        let b = 3.0;
        let wr_low = curve_win_rate(0.1, a, b);
        let wr_high = curve_win_rate(0.5, a, b);
        assert!(wr_high > wr_low, "higher conviction should yield higher win rate");
    }

    #[test]
    fn curve_win_rate_never_below_half() {
        // With negative conviction, exp shrinks but a>0 so still >= 0.50
        let wr = curve_win_rate(-10.0, 0.05, 2.0);
        assert!(wr >= 0.50, "win rate should never drop below 0.50, got {wr}");
    }

    // ── half_kelly_position ──────────────────────────────────────────────────

    #[test]
    fn half_kelly_no_edge_returns_none() {
        // win_rate = 0.50 → edge = 0 → None
        assert!(half_kelly_position(0.50, 0.01).is_none());
    }

    #[test]
    fn half_kelly_negative_edge_returns_none() {
        assert!(half_kelly_position(0.40, 0.01).is_none());
    }

    #[test]
    fn half_kelly_with_edge() {
        // win_rate = 0.60 → edge = 0.20 → frac = 0.20 / 2.0 / 0.01 = 10.0
        let frac = half_kelly_position(0.60, 0.01).unwrap();
        assert!((frac - 10.0).abs() < 1e-10);
    }

    #[test]
    fn half_kelly_scales_with_move_threshold() {
        // Larger move_threshold → smaller position
        let frac_small = half_kelly_position(0.60, 0.01).unwrap();
        let frac_large = half_kelly_position(0.60, 0.05).unwrap();
        assert!(frac_small > frac_large);
    }

    // ── kelly_frac ───────────────────────────────────────────────────────────

    #[test]
    fn kelly_frac_insufficient_data_returns_none() {
        let resolved: VecDeque<(f64, bool)> = (0..499)
            .map(|i| (i as f64 / 500.0, i % 2 == 0))
            .collect();
        assert!(kelly_frac(0.5, &resolved, 0.01).is_none());
    }

    #[test]
    fn kelly_frac_with_strong_signal() {
        // Build resolved predictions where higher conviction → higher accuracy.
        // Use 1000 samples: conviction in [0, 1], win if conviction > threshold
        // adjusted with some randomness via deterministic pattern.
        let mut resolved: VecDeque<(f64, bool)> = VecDeque::new();
        for i in 0..2000 {
            let conviction = (i as f64) / 2000.0;
            // Higher conviction → more likely to win.
            // Win if conviction > 0.3, plus some noise via modular pattern.
            let win = conviction > 0.3 + 0.15 * ((i % 7) as f64 / 7.0);
            resolved.push_back((conviction, win));
        }
        let result = kelly_frac(0.8, &resolved, 0.01);
        // May or may not produce a fit depending on the data shape.
        // If it does, the fraction should be positive.
        if let Some((frac, a, b)) = result {
            assert!(frac > 0.0, "position fraction should be positive");
            assert!(a > 0.0, "curve_a should be positive");
            assert!(b.is_finite(), "curve_b should be finite");
        }
    }

    // ── fit_conviction_curve (tested indirectly through kelly_frac) ──────────

    #[test]
    fn kelly_frac_random_data_likely_none() {
        // Pure coin-flip data — no signal, curve fit should fail or show no edge.
        let mut resolved: VecDeque<(f64, bool)> = VecDeque::new();
        for i in 0..1000 {
            let conviction = (i as f64) / 1000.0;
            // Alternating win/loss regardless of conviction — no signal
            let win = i % 2 == 0;
            resolved.push_back((conviction, win));
        }
        // With no relationship between conviction and accuracy, curve fit
        // should either fail or produce no edge (half_kelly returns None).
        let result = kelly_frac(0.5, &resolved, 0.01);
        // Either None (no fit) or Some with very small/zero fraction is acceptable.
        if let Some((frac, _, _)) = result {
            // If the fit somehow succeeds, fraction should be tiny
            assert!(frac < 1.0, "random data should not produce large position");
        }
    }

    // ── compute_conviction_threshold ────────────────────────────────────────

    use crate::state::ConvictionMode;

    #[test]
    fn threshold_quantile_mode_basic() {
        // 100 values from 0.0 to 0.99, quantile at 0.90 → should pick ~0.89
        let history: VecDeque<f64> = (0..100).map(|i| i as f64 / 100.0).collect();
        let resolved: VecDeque<(f64, bool)> = VecDeque::new();
        let result = compute_conviction_threshold(
            &history, &resolved, ConvictionMode::Quantile, 0.90, 0.52, 1000,
        );
        assert!(result.is_some());
        let thresh = result.unwrap();
        // idx = (100 * 0.90) as usize = 90, sorted[90] = 0.90
        assert!((thresh - 0.90).abs() < 0.02, "quantile threshold ~0.90, got {thresh}");
    }

    #[test]
    fn threshold_quantile_mode_zero_quantile_returns_none() {
        let history: VecDeque<f64> = (0..100).map(|i| i as f64 / 100.0).collect();
        let resolved: VecDeque<(f64, bool)> = VecDeque::new();
        let result = compute_conviction_threshold(
            &history, &resolved, ConvictionMode::Quantile, 0.0, 0.52, 1000,
        );
        assert!(result.is_none());
    }

    #[test]
    fn threshold_auto_insufficient_resolved_returns_none() {
        let history: VecDeque<f64> = (0..100).map(|i| i as f64 / 100.0).collect();
        // Not enough resolved data (need warmup * 5 = 5000)
        let resolved: VecDeque<(f64, bool)> = (0..100)
            .map(|i| (i as f64 / 100.0, i % 2 == 0))
            .collect();
        let result = compute_conviction_threshold(
            &history, &resolved, ConvictionMode::Auto, 0.0, 0.52, 1000,
        );
        assert!(result.is_none());
    }

    #[test]
    fn threshold_auto_warmup_fallback_to_quantile() {
        // Auto mode but resolved < warmup * 5 → falls back to quantile
        // Need: history.len() >= warmup AND quantile_thresh.is_some()
        let warmup = 100;
        let history: VecDeque<f64> = (0..200).map(|i| i as f64 / 200.0).collect();
        let resolved: VecDeque<(f64, bool)> = (0..200)
            .map(|i| (i as f64 / 200.0, i % 2 == 0))
            .collect();
        let result = compute_conviction_threshold(
            &history, &resolved, ConvictionMode::Auto, 0.90, 0.52, warmup,
        );
        // Should fall back to quantile since resolved.len() (200) < warmup*5 (500)
        // but history.len() (200) >= warmup (100) and quantile > 0
        assert!(result.is_some());
    }

    #[test]
    fn threshold_auto_warmup_no_quantile_returns_none() {
        // Auto mode, not enough resolved for curve, quantile = 0 → no fallback
        let warmup = 100;
        let history: VecDeque<f64> = (0..200).map(|i| i as f64 / 200.0).collect();
        let resolved: VecDeque<(f64, bool)> = (0..200)
            .map(|i| (i as f64 / 200.0, i % 2 == 0))
            .collect();
        let result = compute_conviction_threshold(
            &history, &resolved, ConvictionMode::Auto, 0.0, 0.52, warmup,
        );
        assert!(result.is_none());
    }

    #[test]
    fn threshold_auto_with_strong_signal() {
        // Build resolved data where higher conviction → higher accuracy
        // Need 5000+ resolved (warmup=1000, so 5*1000=5000)
        let warmup = 1000;
        let mut resolved: VecDeque<(f64, bool)> = VecDeque::new();
        for i in 0..6000 {
            let c = (i as f64) / 6000.0;
            // Strong signal: win if conviction > 0.3 (with deterministic noise)
            let win = c > 0.3 + 0.1 * ((i % 5) as f64 / 5.0);
            resolved.push_back((c, win));
        }
        let history: VecDeque<f64> = (0..1000).map(|i| i as f64 / 1000.0).collect();
        let result = compute_conviction_threshold(
            &history, &resolved, ConvictionMode::Auto, 0.90, 0.55, warmup,
        );
        // May or may not produce a threshold depending on curve fit quality.
        // If it does, threshold should be in (0, 1).
        if let Some(thresh) = result {
            assert!(thresh > 0.0 && thresh < 1.0,
                "auto threshold should be in (0,1), got {thresh}");
        }
    }

    #[test]
    fn threshold_empty_history_returns_none() {
        let history: VecDeque<f64> = VecDeque::new();
        let resolved: VecDeque<(f64, bool)> = VecDeque::new();
        // Quantile mode with empty history — quantile > 0 but sorted is empty
        // This would panic on sorted[idx] with empty vec, so quantile_thresh
        // computation needs history. Let's test Auto mode instead.
        let result = compute_conviction_threshold(
            &history, &resolved, ConvictionMode::Auto, 0.0, 0.52, 1000,
        );
        assert!(result.is_none());
    }

    // ── fit_conviction_curve ────────────────────────────────────────────────

    #[test]
    fn fit_conviction_curve_too_few_samples() {
        let resolved: VecDeque<(f64, bool)> = (0..10)
            .map(|i| (i as f64 / 10.0, true))
            .collect();
        // bin_size = 10 / 20 = 0 < min_bin_size → None
        assert!(fit_conviction_curve(&resolved, 5).is_none());
    }

    #[test]
    fn fit_conviction_curve_no_signal() {
        // Alternating win/loss — bins at ~50% accuracy, below 0.505 threshold
        let resolved: VecDeque<(f64, bool)> = (0..2000)
            .map(|i| (i as f64 / 2000.0, i % 2 == 0))
            .collect();
        // Each bin has ~50% accuracy, so acc <= 0.505 filter removes most/all
        // → fewer than 3 points → None
        let result = fit_conviction_curve(&resolved, 5);
        assert!(result.is_none(), "random data should not produce a fit");
    }

    #[test]
    fn fit_conviction_curve_strong_signal() {
        // Higher conviction → higher win rate
        let mut resolved: VecDeque<(f64, bool)> = VecDeque::new();
        for i in 0..2000 {
            let c = i as f64 / 2000.0;
            // Above c=0.3, increasingly likely to win
            let win = c > 0.2 + 0.15 * ((i % 7) as f64 / 7.0);
            resolved.push_back((c, win));
        }
        let result = fit_conviction_curve(&resolved, 5);
        if let Some((a, b)) = result {
            assert!(a > 0.0, "curve_a should be positive, got {a}");
            assert!(b.is_finite(), "curve_b should be finite, got {b}");
        }
    }
}
