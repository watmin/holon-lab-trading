//! mod/oscillators — momentum indicators
//!
//! Implements: Williams %R, Stochastic RSI, Ultimate Oscillator, multi-ROC
//! Spec: wat/mod/oscillators.wat
//!
//! Each function takes a candle window and produces named facts as
//! (label, vector) pairs. The thought encoder bundles them.

use crate::candle::Candle;

/// Williams %R: close relative to high-low range, inverted.
/// Range: [-100, 0]. -20 to 0 = overbought. -100 to -80 = oversold.
pub fn williams_r(candles: &[Candle], lookback: usize) -> Option<f64> {
    if candles.len() < lookback { return None; }
    let window = &candles[candles.len() - lookback..];
    let high = window.iter().map(|c| c.high).fold(f64::NEG_INFINITY, f64::max);
    let low = window.iter().map(|c| c.low).fold(f64::INFINITY, f64::min);
    let span = high - low;
    if span < 1e-10 { return None; }
    let close = candles.last().unwrap().close;
    Some(-100.0 * (high - close) / span)
}

/// Stochastic RSI: stochastic of RSI values.
/// Range: [0, 1]. > 0.8 = overbought. < 0.2 = oversold.
pub fn stochastic_rsi(candles: &[Candle], lookback: usize) -> Option<f64> {
    if candles.len() < lookback { return None; }
    let window = &candles[candles.len() - lookback..];
    let rsi_values: Vec<f64> = window.iter().map(|c| c.rsi).collect();
    let rsi_high = rsi_values.iter().fold(f64::NEG_INFINITY, |a, &b| a.max(b));
    let rsi_low = rsi_values.iter().fold(f64::INFINITY, |a, &b| a.min(b));
    let span = rsi_high - rsi_low;
    if span < 1e-10 { return None; }
    let current_rsi = rsi_values.last()?;
    Some((current_rsi - rsi_low) / span)
}

/// Ultimate Oscillator: weighted average of three timeframes.
/// Range: [0, 100]. > 70 = overbought. < 30 = oversold.
pub fn ultimate_oscillator(candles: &[Candle], p1: usize, p2: usize, p3: usize) -> Option<f64> {
    if candles.len() < p3 + 1 { return None; }
    // Buying pressure = close - min(low, prev_close)
    // True range = max(high, prev_close) - min(low, prev_close)
    let mut bp_sum = [0.0_f64; 3];
    let mut tr_sum = [0.0_f64; 3];
    let periods = [p1, p2, p3];

    for i in 1..candles.len() {
        let prev_close = candles[i - 1].close;
        let low = candles[i].low;
        let high = candles[i].high;
        let close = candles[i].close;

        let bp = close - low.min(prev_close);
        let tr = high.max(prev_close) - low.min(prev_close);

        let offset = candles.len() - i;
        for (pi, &period) in periods.iter().enumerate() {
            if offset < period {
                bp_sum[pi] += bp;
                tr_sum[pi] += tr;
            }
        }
    }

    let avg = |bp: f64, tr: f64| -> f64 {
        if tr.abs() < 1e-10 { 50.0 } else { bp / tr }
    };

    let a1 = avg(bp_sum[0], tr_sum[0]);
    let a2 = avg(bp_sum[1], tr_sum[1]);
    let a3 = avg(bp_sum[2], tr_sum[2]);

    // Weighted: 4× short, 2× medium, 1× long
    Some(100.0 * (4.0 * a1 + 2.0 * a2 + a3) / 7.0)
}

/// Rate of Change at a specific lookback period.
/// Returns percentage change: (close - close_n_ago) / close_n_ago
pub fn roc(candles: &[Candle], period: usize) -> Option<f64> {
    if candles.len() <= period { return None; }
    let current = candles.last()?.close;
    let past = candles[candles.len() - 1 - period].close;
    if past.abs() < 1e-10 { return None; }
    Some((current - past) / past)
}

/// Evaluate all oscillator facts for a candle window.
/// Returns (label, is_zone) pairs. Zone facts are binary (present/absent).
/// Scalar facts are continuous values to be encoded.
pub struct OscillatorFacts {
    pub williams_r: Option<f64>,
    pub williams_zone: Option<&'static str>,  // "williams-overbought" or "williams-oversold"
    pub stoch_rsi: Option<f64>,
    pub stoch_rsi_zone: Option<&'static str>,
    pub ult_osc: Option<f64>,
    pub ult_osc_zone: Option<&'static str>,
    pub roc_5: Option<f64>,
    pub roc_10: Option<f64>,
    pub roc_20: Option<f64>,
    pub roc_accelerating: bool,  // roc_5 > roc_10 > roc_20
    pub roc_decelerating: bool,  // roc_5 < roc_10 < roc_20
}

pub fn eval_oscillators(candles: &[Candle]) -> OscillatorFacts {
    let wr = williams_r(candles, 14);
    let wr_zone = wr.and_then(|v| {
        if v > -20.0 { Some("williams-overbought") }
        else if v < -80.0 { Some("williams-oversold") }
        else { None }
    });

    let srsi = stochastic_rsi(candles, 14);
    let srsi_zone = srsi.and_then(|v| {
        if v > 0.8 { Some("stoch-rsi-overbought") }
        else if v < 0.2 { Some("stoch-rsi-oversold") }
        else { None }
    });

    let uo = ultimate_oscillator(candles, 7, 14, 28);
    let uo_zone = uo.and_then(|v| {
        if v > 70.0 { Some("ult-osc-overbought") }
        else if v < 30.0 { Some("ult-osc-oversold") }
        else { None }
    });

    let r5 = roc(candles, 5);
    let r10 = roc(candles, 10);
    let r20 = roc(candles, 20);

    let accel = match (r5, r10, r20) {
        (Some(a), Some(b), Some(c)) => a > b && b > c,
        _ => false,
    };
    let decel = match (r5, r10, r20) {
        (Some(a), Some(b), Some(c)) => a < b && b < c,
        _ => false,
    };

    OscillatorFacts {
        williams_r: wr,
        williams_zone: wr_zone,
        stoch_rsi: srsi,
        stoch_rsi_zone: srsi_zone,
        ult_osc: uo,
        ult_osc_zone: uo_zone,
        roc_5: r5,
        roc_10: r10,
        roc_20: r20,
        roc_accelerating: accel,
        roc_decelerating: decel,
    }
}
