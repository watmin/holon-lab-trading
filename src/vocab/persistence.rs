//! mod/persistence — trend persistence and memory
//!
//! Implements: Hurst exponent estimate, autocorrelation, ADX zones,
//!             regime transition detection
//! Spec: ~/work/holon/wat/mod/persistence.wat
//!
//! These measure PROPERTIES of the price series, not direction.
//! "Is this market trending or mean-reverting? Persistent or random?"

use crate::candle::Candle;
use super::Fact;

/// Simplified Hurst exponent estimate via rescaled range (R/S).
/// H > 0.5: persistent (trends continue). H < 0.5: anti-persistent.
/// H = 0.5: random walk.
pub fn hurst_estimate(candles: &[Candle], lookback: usize) -> Option<f64> {
    if candles.len() < lookback || lookback < 10 { return None; }
    let window = &candles[candles.len() - lookback..];
    let returns: Vec<f64> = (1..window.len())
        .map(|i| (window[i].close / window[i-1].close).ln())
        .collect();
    if returns.is_empty() { return None; }

    let n = returns.len() as f64;
    let mean = returns.iter().sum::<f64>() / n;
    let std = (returns.iter().map(|r| (r - mean).powi(2)).sum::<f64>() / n).sqrt();
    if std < 1e-15 { return None; }

    // Cumulative deviation from mean
    let mut cum = 0.0_f64;
    let mut max_cum = f64::NEG_INFINITY;
    let mut min_cum = f64::INFINITY;
    for r in &returns {
        cum += r - mean;
        max_cum = max_cum.max(cum);
        min_cum = min_cum.min(cum);
    }
    let rs = (max_cum - min_cum) / std;
    if rs <= 0.0 { return None; }

    // H = log(R/S) / log(N)
    Some(rs.ln() / n.ln())
}

/// Lag-1 autocorrelation of returns.
/// Positive = momentum. Negative = mean-reversion. Near zero = random.
pub fn autocorrelation_lag1(candles: &[Candle], lookback: usize) -> Option<f64> {
    if candles.len() < lookback + 1 || lookback < 5 { return None; }
    let window = &candles[candles.len() - lookback - 1..];
    let returns: Vec<f64> = (1..window.len())
        .map(|i| (window[i].close - window[i-1].close) / window[i-1].close)
        .collect();
    if returns.len() < 5 { return None; }

    let mean = returns.iter().sum::<f64>() / returns.len() as f64;
    let var: f64 = returns.iter().map(|r| (r - mean).powi(2)).sum::<f64>();
    if var.abs() < 1e-15 { return None; }

    let cov: f64 = (1..returns.len())
        .map(|i| (returns[i] - mean) * (returns[i-1] - mean))
        .sum();

    Some(cov / var)
}

/// ADX zone classification from pre-computed candle field.
pub fn adx_zone(adx: f64) -> &'static str {
    if adx > 25.0 { "strong-trend" }
    else if adx < 20.0 { "weak-trend" }
    else { "moderate-trend" }
}

/// All persistence facts.
pub fn eval_persistence(candles: &[Candle]) -> Vec<Fact<'static>> {
    let mut facts: Vec<Fact<'static>> = Vec::new();

    let h = hurst_estimate(candles, candles.len().min(100));
    if let Some(v) = h {
        facts.push(Fact::Scalar { indicator: "hurst", value: v.clamp(0.0, 1.0), scale: 1.0 });
        if v > 0.55 {
            facts.push(Fact::Zone { indicator: "hurst", zone: "hurst-trending" });
        } else if v < 0.45 {
            facts.push(Fact::Zone { indicator: "hurst", zone: "hurst-reverting" });
        }
    }

    let ac = autocorrelation_lag1(candles, candles.len().min(50));
    if let Some(v) = ac {
        facts.push(Fact::Scalar { indicator: "autocorr", value: v.clamp(-1.0, 1.0) * 0.5 + 0.5, scale: 1.0 });
        if v > 0.1 {
            facts.push(Fact::Zone { indicator: "autocorr", zone: "autocorr-positive" });
        } else if v < -0.1 {
            facts.push(Fact::Zone { indicator: "autocorr", zone: "autocorr-negative" });
        }
    }

    let now = candles.last().unwrap();
    facts.push(Fact::Zone { indicator: "adx", zone: adx_zone(now.adx) });

    facts
}
