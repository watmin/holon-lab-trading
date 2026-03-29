//! mod/persistence — trend persistence and memory
//!
//! Implements: Hurst exponent estimate, autocorrelation, ADX zones,
//!             regime transition detection
//! Spec: ~/work/holon/wat/mod/persistence.wat
//!
//! These measure PROPERTIES of the price series, not direction.
//! "Is this market trending or mean-reverting? Persistent or random?"

use crate::db::Candle;

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
pub struct PersistenceFacts {
    pub hurst: Option<f64>,
    pub hurst_zone: Option<&'static str>,
    pub autocorr: Option<f64>,
    pub autocorr_zone: Option<&'static str>,
    pub adx_zone: &'static str,
    pub adx_value: f64,
}

pub fn eval_persistence(candles: &[Candle]) -> PersistenceFacts {
    let h = hurst_estimate(candles, candles.len().min(100));
    let h_zone = h.and_then(|v| {
        if v > 0.55 { Some("hurst-trending") }
        else if v < 0.45 { Some("hurst-reverting") }
        else { None }
    });

    let ac = autocorrelation_lag1(candles, candles.len().min(50));
    let ac_zone = ac.and_then(|v| {
        if v > 0.1 { Some("autocorr-positive") }
        else if v < -0.1 { Some("autocorr-negative") }
        else { None }
    });

    let now = candles.last().unwrap();

    PersistenceFacts {
        hurst: h,
        hurst_zone: h_zone,
        autocorr: ac,
        autocorr_zone: ac_zone,
        adx_zone: adx_zone(now.adx),
        adx_value: now.adx,
    }
}
