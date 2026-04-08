//! vocab/standard — facts every observer sees
//!
//! Contextual facts that modify the meaning of all other facts.
//! The noise subspace self-regulates — if a standard fact doesn't
//! matter for this observer, the subspace learns it's boring.
//!
//! Calendar (hour, day-of-week, session) is handled separately in
//! ThoughtEncoder::eval_calendar. This module adds the remaining
//! standard thoughts from proposal 003.

use crate::candle::Candle;
use super::Fact;

// ── Recency — time since last event ─────────────────────────────────────────

const RECENCY_LOOKBACK: usize = 200;
const RECENCY_LOG_DENOM: f64 = 5.303; // ln(201) — normalizes to [0, 1]

/// Count candles backwards from the end of the window until the predicate is true.
/// Returns the distance (1 = previous candle matched, RECENCY_LOOKBACK = nothing matched).
fn candles_since(candles: &[Candle], pred: fn(&Candle) -> bool) -> usize {
    let n = candles.len();
    for i in 1..n.min(RECENCY_LOOKBACK) {
        if pred(&candles[n - 1 - i]) {
            return i;
        }
    }
    n.min(RECENCY_LOOKBACK)
}

/// Encode a recency distance as a scalar in [0, 1] via log scaling.
fn recency_scalar(distance: usize) -> f64 {
    (1.0 + distance as f64).ln() / RECENCY_LOG_DENOM
}

pub fn eval_recency(candles: &[Candle]) -> Vec<Fact<'static>> {
    if candles.len() < 10 { return vec![]; }

    let since_rsi = candles_since(candles, |c| c.rsi > 70.0 || c.rsi < 30.0);
    let since_vol = candles_since(candles, |c| c.vol_accel > 2.0);
    let since_move = candles_since(candles, |c| c.roc_1.abs() > 2.0 * c.atr_r);

    vec![
        Fact::Scalar { indicator: "since-rsi-extreme", value: recency_scalar(since_rsi), scale: 1.0 },
        Fact::Scalar { indicator: "since-vol-spike", value: recency_scalar(since_vol), scale: 1.0 },
        Fact::Scalar { indicator: "since-large-move", value: recency_scalar(since_move), scale: 1.0 },
    ]
}

// ── Distance from structure ─────────────────────────────────────────────────

/// Percentage distance, clamped to ±10% and rescaled to [0, 1].
fn dist_scalar(close: f64, level: f64) -> f64 {
    if close.abs() < 1e-10 { return 0.5; }
    let pct = (close - level) / close;
    pct.clamp(-0.1, 0.1) * 5.0 + 0.5 // maps [-0.1, 0.1] → [0, 1]
}

pub fn eval_distance(candles: &[Candle]) -> Vec<Fact<'static>> {
    if candles.len() < 2 { return vec![]; }

    let close = candles.last().unwrap().close;
    let window_high = candles.iter().map(|c| c.high).fold(f64::NEG_INFINITY, f64::max);
    let window_low = candles.iter().map(|c| c.low).fold(f64::INFINITY, f64::min);
    let midpoint = (window_high + window_low) / 2.0;

    let mut facts = vec![
        Fact::Scalar { indicator: "dist-from-high", value: dist_scalar(close, window_high), scale: 1.0 },
        Fact::Scalar { indicator: "dist-from-low", value: dist_scalar(close, window_low), scale: 1.0 },
        Fact::Scalar { indicator: "dist-from-midpoint", value: dist_scalar(close, midpoint), scale: 1.0 },
    ];

    let sma200 = candles.last().unwrap().sma200;
    if sma200 > 0.0 {
        facts.push(Fact::Scalar { indicator: "dist-from-sma200", value: dist_scalar(close, sma200), scale: 1.0 });
    }

    facts
}

// ── Relative participation ──────────────────────────────────────────────────

pub fn eval_participation(candles: &[Candle]) -> Vec<Fact<'static>> {
    let now = match candles.last() {
        Some(c) if c.volume_sma_20 > 0.0 => c,
        _ => return vec![],
    };

    let ratio = (now.volume / now.volume_sma_20).clamp(0.0, 5.0) / 5.0;
    vec![
        Fact::Scalar { indicator: "volume-ratio", value: ratio, scale: 1.0 },
    ]
}

// ── Session depth ───────────────────────────────────────────────────────────

pub fn eval_session_depth(now: &Candle) -> Vec<Fact<'static>> {
    vec![
        Fact::Scalar { indicator: "session-depth", value: now.hour / 24.0, scale: 1.0 },
    ]
}

// ── Combined ────────────────────────────────────────────────────────────────

pub fn eval_standard(candles: &[Candle]) -> Vec<Fact<'static>> {
    let mut facts = eval_recency(candles);
    facts.extend(eval_distance(candles));
    facts.extend(eval_participation(candles));
    if let Some(now) = candles.last() {
        facts.extend(eval_session_depth(now));
    }
    facts
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_candle(close: f64, rsi: f64, vol_accel: f64, roc_1: f64, atr_r: f64) -> Candle {
        Candle {
            ts: String::new(), open: close, high: close + 1.0, low: close - 1.0,
            close, volume: 100.0,
            sma20: close, sma50: close, sma200: close * 0.95,
            bb_upper: close + 5.0, bb_lower: close - 5.0, bb_width: 0.0, bb_pos: 0.5,
            rsi, macd_line: 0.0, macd_signal: 0.0, macd_hist: 0.0,
            dmi_plus: 20.0, dmi_minus: 15.0, adx: 25.0,
            atr: 1.0, atr_r,
            stoch_k: 50.0, stoch_d: 45.0, williams_r: -50.0,
            cci: 0.0, mfi: 50.0,
            roc_1, roc_3: 0.0, roc_6: 0.0, roc_12: 0.0,
            obv_slope_12: 0.0, volume_sma_20: 100.0, vol_accel,
            tf_1h_close: 0.0, tf_1h_high: 0.0, tf_1h_low: 0.0,
            tf_1h_ret: 0.0, tf_1h_body: 0.0,
            tf_4h_close: 0.0, tf_4h_high: 0.0, tf_4h_low: 0.0,
            tf_4h_ret: 0.0, tf_4h_body: 0.0,
            tenkan_sen: 0.0, kijun_sen: 0.0, senkou_span_a: 0.0,
            senkou_span_b: 0.0, cloud_top: 0.0, cloud_bottom: 0.0,
            kelt_upper: 0.0, kelt_lower: 0.0, kelt_pos: 0.5,
            squeeze: false,
            range_pos_12: 0.5, range_pos_24: 0.5, range_pos_48: 0.5,
            trend_consistency_6: 0.5, trend_consistency_12: 0.5,
            trend_consistency_24: 0.5,
            atr_roc_6: 0.0, atr_roc_12: 0.0,
            hour: 14.0, day_of_week: 3.0,
        }
    }

    #[test]
    fn recency_finds_recent_rsi_extreme() {
        let mut candles: Vec<Candle> = (0..20).map(|_| make_candle(100.0, 50.0, 1.0, 0.001, 0.01)).collect();
        // RSI extreme 5 candles ago
        candles[14].rsi = 75.0;
        let facts = eval_recency(&candles);
        let rsi_fact = facts.iter().find(|f| matches!(f, Fact::Scalar { indicator: "since-rsi-extreme", .. })).unwrap();
        if let Fact::Scalar { value, .. } = rsi_fact {
            // 5 candles ago → ln(6)/ln(201) ≈ 0.338
            assert!(*value > 0.3 && *value < 0.4, "since-rsi-extreme should be ~0.34, got {}", value);
        }
    }

    #[test]
    fn recency_max_when_no_event() {
        let candles: Vec<Candle> = (0..20).map(|_| make_candle(100.0, 50.0, 1.0, 0.001, 0.01)).collect();
        let facts = eval_recency(&candles);
        let rsi_fact = facts.iter().find(|f| matches!(f, Fact::Scalar { indicator: "since-rsi-extreme", .. })).unwrap();
        if let Fact::Scalar { value, .. } = rsi_fact {
            // No RSI extreme in window → distance = window length → high scalar
            assert!(*value > 0.5, "no event should give high recency, got {}", value);
        }
    }

    #[test]
    fn distance_from_high_is_negative_or_zero() {
        let candles: Vec<Candle> = (0..10).map(|i| {
            make_candle(100.0 + i as f64, 50.0, 1.0, 0.001, 0.01)
        }).collect();
        let facts = eval_distance(&candles);
        let high_fact = facts.iter().find(|f| matches!(f, Fact::Scalar { indicator: "dist-from-high", .. })).unwrap();
        if let Fact::Scalar { value, .. } = high_fact {
            // Close is at the high → distance ≈ 0, scalar ≈ 0.5
            assert!(*value >= 0.4 && *value <= 0.55, "at window high, dist should be ~0.5, got {}", value);
        }
    }

    #[test]
    fn participation_scales_correctly() {
        let mut candles = vec![make_candle(100.0, 50.0, 1.0, 0.001, 0.01)];
        candles[0].volume = 250.0;       // 2.5× average
        candles[0].volume_sma_20 = 100.0;
        let facts = eval_participation(&candles);
        let ratio_fact = facts.iter().find(|f| matches!(f, Fact::Scalar { indicator: "volume-ratio", .. })).unwrap();
        if let Fact::Scalar { value, .. } = ratio_fact {
            // 250/100 = 2.5, clamped to [0,5], /5 = 0.5
            assert!((*value - 0.5).abs() < 0.01, "volume-ratio should be 0.5, got {}", value);
        }
    }

    #[test]
    fn session_depth_at_noon() {
        let c = make_candle(100.0, 50.0, 1.0, 0.001, 0.01);
        // hour = 14.0 from make_candle
        let facts = eval_session_depth(&c);
        if let Fact::Scalar { value, .. } = &facts[0] {
            assert!((*value - 14.0/24.0).abs() < 0.01, "session-depth at hour 14 should be ~0.583, got {}", value);
        }
    }

    #[test]
    fn eval_standard_produces_all_categories() {
        let candles: Vec<Candle> = (0..20).map(|i| {
            make_candle(100.0 + i as f64 * 0.5, 50.0, 1.0, 0.001, 0.01)
        }).collect();
        let facts = eval_standard(&candles);

        let has = |name: &str| facts.iter().any(|f| matches!(f, Fact::Scalar { indicator, .. } if *indicator == name));
        assert!(has("since-rsi-extreme"), "missing recency");
        assert!(has("dist-from-high"), "missing distance");
        assert!(has("volume-ratio"), "missing participation");
        assert!(has("session-depth"), "missing session depth");
    }
}
