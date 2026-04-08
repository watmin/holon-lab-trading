//! vocab/divergence — structural divergence between price and indicators
//!
//! Uses PELT changepoints to find structural peaks and troughs,
//! then detects when price and RSI disagree at turning points.
//! Foundation for multi-indicator divergence framework.

use crate::candle::Candle;
use crate::thought::pelt::{pelt_changepoints, bic_penalty};

/// A detected divergence event.
pub struct Divergence {
    /// "bearish" or "bullish"
    pub kind: &'static str,
    /// Which indicator diverges from price
    pub indicator: &'static str,
    /// Price direction at the divergence point
    pub price_dir: &'static str,
    /// Indicator direction at the divergence point
    pub indicator_dir: &'static str,
    /// How many candles ago the divergence occurred (from window end)
    pub candles_ago: usize,
}

/// Sliding pairs: [a, b, c] → [(a, b), (b, c)].
fn pairs(xs: &[usize]) -> Vec<(usize, usize)> {
    xs.windows(2).map(|w| (w[0], w[1])).collect()
}

/// Direction of segment `i`: +1 (up), -1 (down), 0 (flat).
/// Compares value at segment end to segment start.
fn segment_direction(boundaries: &[usize], i: usize, values: &[f64]) -> i8 {
    let change = values[boundaries[i + 1] - 1] - values[boundaries[i]];
    if change > 1e-10 { 1 } else if change < -1e-10 { -1 } else { 0 }
}

/// Indices where an up-segment meets a down-segment (structural highs).
fn find_peaks(seg_dirs: &[i8], boundaries: &[usize]) -> Vec<usize> {
    (0..seg_dirs.len() - 1)
        .filter(|&i| seg_dirs[i] == 1 && seg_dirs[i + 1] == -1)
        .map(|i| boundaries[i + 1] - 1)
        .collect()
}

/// Indices where a down-segment meets an up-segment (structural lows).
fn find_troughs(seg_dirs: &[i8], boundaries: &[usize]) -> Vec<usize> {
    (0..seg_dirs.len() - 1)
        .filter(|&i| seg_dirs[i] == -1 && seg_dirs[i + 1] == 1)
        .map(|i| boundaries[i + 1] - 1)
        .collect()
}

/// Consecutive peaks where price makes higher high but RSI makes lower high.
fn check_bearish_pairs(peaks: &[(usize, usize)], candles: &[Candle], n: usize) -> Vec<Divergence> {
    peaks.iter()
        .filter(|&&(prev, curr)| {
            candles[curr].close > candles[prev].close
                && candles[curr].rsi < candles[prev].rsi
        })
        .map(|&(_prev, curr)| Divergence {
            kind: "bearish",
            indicator: "rsi",
            price_dir: "up",
            indicator_dir: "down",
            candles_ago: n - 1 - curr,
        })
        .collect()
}

/// Consecutive troughs where price makes lower low but RSI makes higher low.
fn check_bullish_pairs(troughs: &[(usize, usize)], candles: &[Candle], n: usize) -> Vec<Divergence> {
    troughs.iter()
        .filter(|&&(prev, curr)| {
            candles[curr].close < candles[prev].close
                && candles[curr].rsi > candles[prev].rsi
        })
        .map(|&(_prev, curr)| Divergence {
            kind: "bullish",
            indicator: "rsi",
            price_dir: "down",
            indicator_dir: "up",
            candles_ago: n - 1 - curr,
        })
        .collect()
}

pub fn eval_divergence(candles: &[Candle]) -> Vec<Divergence> {
    if candles.len() < 10 { return Vec::new(); }

    // PELT on ln(close) to find structural segments
    let close_ln: Vec<f64> = candles.iter().map(|c| c.close.ln()).collect();
    let penalty = bic_penalty(&close_ln);
    let cps = pelt_changepoints(&close_ln, penalty);

    let n = close_ln.len();
    let mut boundaries = vec![0usize];
    boundaries.extend_from_slice(&cps);
    boundaries.push(n);

    let n_segs = boundaries.len() - 1;
    if n_segs < 3 { return Vec::new(); }

    // Pipeline: boundaries → segment directions → peaks/troughs → check pairs
    let seg_dirs: Vec<i8> = (0..n_segs)
        .map(|i| segment_direction(&boundaries, i, &close_ln))
        .collect();

    let peaks = find_peaks(&seg_dirs, &boundaries);
    let troughs = find_troughs(&seg_dirs, &boundaries);

    let mut results = check_bearish_pairs(&pairs(&peaks), candles, n);
    results.extend(check_bullish_pairs(&pairs(&troughs), candles, n));
    results
}
