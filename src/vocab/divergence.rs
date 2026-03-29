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

pub fn eval_divergence(candles: &[Candle]) -> Vec<Divergence> {
    let mut results = Vec::new();
    if candles.len() < 10 { return results; }

    // PELT on ln(close) to find structural segments
    let close_ln: Vec<f64> = candles.iter().map(|c| c.close.ln()).collect();
    let penalty = bic_penalty(&close_ln);
    let cps = pelt_changepoints(&close_ln, penalty);

    let n = close_ln.len();
    let mut boundaries = vec![0usize];
    boundaries.extend_from_slice(&cps);
    boundaries.push(n);
    let n_segs = boundaries.len() - 1;
    if n_segs < 3 { return results; }

    // Segment directions: +1 up, -1 down, 0 flat
    let seg_dirs: Vec<i8> = (0..n_segs)
        .map(|i| {
            let change = close_ln[boundaries[i + 1] - 1] - close_ln[boundaries[i]];
            if change > 1e-10 { 1 } else if change < -1e-10 { -1 } else { 0 }
        })
        .collect();

    // Peaks: up→down boundary. Troughs: down→up boundary.
    let mut peaks: Vec<usize> = Vec::new();
    let mut troughs: Vec<usize> = Vec::new();
    for i in 0..n_segs - 1 {
        if seg_dirs[i] == 1 && seg_dirs[i + 1] == -1 {
            peaks.push(boundaries[i + 1] - 1);
        } else if seg_dirs[i] == -1 && seg_dirs[i + 1] == 1 {
            troughs.push(boundaries[i + 1] - 1);
        }
    }

    // Bearish: price higher high, RSI lower high
    for pair in peaks.windows(2) {
        let (i_prev, i_curr) = (pair[0], pair[1]);
        if candles[i_curr].close > candles[i_prev].close
            && candles[i_curr].rsi < candles[i_prev].rsi
        {
            results.push(Divergence {
                kind: "bearish",
                indicator: "rsi",
                price_dir: "up",
                indicator_dir: "down",
                candles_ago: n - 1 - i_curr,
            });
        }
    }

    // Bullish: price lower low, RSI higher low
    for pair in troughs.windows(2) {
        let (i_prev, i_curr) = (pair[0], pair[1]);
        if candles[i_curr].close < candles[i_prev].close
            && candles[i_curr].rsi > candles[i_prev].rsi
        {
            results.push(Divergence {
                kind: "bullish",
                indicator: "rsi",
                price_dir: "down",
                indicator_dir: "up",
                candles_ago: n - 1 - i_curr,
            });
        }
    }

    results
}
