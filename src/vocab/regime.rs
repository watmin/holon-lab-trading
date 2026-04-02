//! vocab/regime — market regime characterization
//!
//! Abstract properties of the price series: is it trending or choppy?
//! Persistent or mean-reverting? Orderly or chaotic?
//!
//! These survive window noise better than candle-level patterns.
//! The regime expert's exclusive vocabulary.

use crate::candle::Candle;
use super::Fact;

/// Simple linear regression slope. Returns None if degenerate.
/// Matches wat/vocab/regime.wat linreg-slope.
fn linreg_slope(xs: &[f64], ys: &[f64]) -> Option<f64> {
    let n = xs.len() as f64;
    let sx: f64 = xs.iter().sum();
    let sy: f64 = ys.iter().sum();
    let sxx: f64 = xs.iter().map(|x| x * x).sum();
    let sxy: f64 = xs.iter().zip(ys.iter()).map(|(x, y)| x * y).sum();
    let denom = n * sxx - sx * sx;
    if denom.abs() > 1e-10 {
        Some((n * sxy - sx * sy) / denom)
    } else {
        None
    }
}

/// KAMA Efficiency Ratio: |net_move| / sum(|step_move|) over 10 periods.
/// Matches wat/vocab/regime.wat kama-er.
fn kama_er(closes: &[f64]) -> f64 {
    let n = closes.len();
    let er_period = 10.min(n - 1);
    let net_move = (closes[n - 1] - closes[n - 1 - er_period]).abs();
    let step_sum: f64 = (n - er_period..n).map(|i| (closes[i] - closes[i - 1]).abs()).sum();
    if step_sum > 1e-10 { net_move / step_sum } else { 0.0 }
}

/// Choppiness Index: 100 * log10(ATR_sum / range) / log10(period). Uses 14 periods.
/// Matches wat/vocab/regime.wat choppiness-index.
fn choppiness_index(candles: &[Candle]) -> f64 {
    let n = candles.len();
    let chop_period = 14.min(n - 1);
    let chop_slice = &candles[n - chop_period..];
    let chop_atr_sum: f64 = (1..chop_period).map(|i| {
        let hl = chop_slice[i].high - chop_slice[i].low;
        let hc = (chop_slice[i].high - chop_slice[i - 1].close).abs();
        let lc = (chop_slice[i].low - chop_slice[i - 1].close).abs();
        hl.max(hc).max(lc)
    }).sum();
    let chop_hi = chop_slice.iter().map(|c| c.high).fold(f64::NEG_INFINITY, f64::max);
    let chop_lo = chop_slice.iter().map(|c| c.low).fold(f64::INFINITY, f64::min);
    let chop_range = chop_hi - chop_lo;
    if chop_range > 1e-10 {
        100.0 * (chop_atr_sum / chop_range).log10() / (chop_period as f64).log10()
    } else {
        100.0
    }
}

/// Detrended fluctuation analysis alpha. Log-log slope at scales [4,6,8,12,16].
/// Returns None if insufficient data or scales.
/// Matches wat/vocab/regime.wat dfa-alpha.
fn dfa_alpha(returns: &[f64]) -> Option<f64> {
    if returns.len() < 16 { return None; }
    let ret_mean = returns.iter().sum::<f64>() / returns.len() as f64;
    let integrated: Vec<f64> = returns.iter()
        .scan(0.0, |acc, &r| { *acc += r - ret_mean; Some(*acc) }).collect();
    let scales: Vec<usize> = vec![4, 6, 8, 12, 16].into_iter()
        .filter(|&s| s <= integrated.len()).collect();
    if scales.len() < 3 { return None; }
    let mut log_f = Vec::new();
    let mut log_s = Vec::new();
    for &s in &scales {
        let num_segs = integrated.len() / s;
        if num_segs == 0 { continue; }
        let mut f2_sum = 0.0;
        for seg in 0..num_segs {
            let start = seg * s;
            let seg_data = &integrated[start..start + s];
            let sx: f64 = (0..s).map(|i| i as f64).sum();
            let sy: f64 = seg_data.iter().sum();
            let sxx: f64 = (0..s).map(|i| (i * i) as f64).sum();
            let sxy: f64 = (0..s).map(|i| i as f64 * seg_data[i]).sum();
            let sn = s as f64;
            let denom = sn * sxx - sx * sx;
            let (a, b) = if denom.abs() > 1e-10 {
                let b = (sn * sxy - sx * sy) / denom;
                let a = (sy - b * sx) / sn;
                (a, b)
            } else { (0.0, 0.0) };
            let rms: f64 = seg_data.iter().enumerate()
                .map(|(i, &y)| { let trend = a + b * i as f64; (y - trend).powi(2) })
                .sum::<f64>() / sn;
            f2_sum += rms;
        }
        let f = (f2_sum / num_segs as f64).sqrt();
        if f > 1e-10 {
            log_f.push(f.ln());
            log_s.push((s as f64).ln());
        }
    }
    if log_f.len() < 3 { return None; }
    linreg_slope(&log_s, &log_f).map(|alpha| alpha.clamp(0.0, 1.5))
}

/// Variance ratio: var(k-period returns) / (k * var(1-period returns)).
/// VR > 1: momentum. VR < 1: mean-reversion. Returns None if degenerate.
/// Matches wat/vocab/regime.wat variance-ratio.
fn variance_ratio(returns: &[f64], k: usize) -> Option<f64> {
    if returns.len() < 10 { return None; }
    let var1: f64 = returns.iter().map(|r| r * r).sum::<f64>() / returns.len() as f64;
    if var1 <= 1e-20 { return None; }
    let k_returns: Vec<f64> = (0..returns.len() - k + 1)
        .map(|i| returns[i..i + k].iter().sum::<f64>()).collect();
    if k_returns.is_empty() { return None; }
    let var_k: f64 = k_returns.iter().map(|r| r * r).sum::<f64>()
        / k_returns.len() as f64 / k as f64;
    Some(var_k / var1)
}

/// DeMark TD Sequential count. Consecutive closes above/below close[i-4].
/// Resets on direction change.
/// Matches wat/vocab/regime.wat td-count.
fn td_count(closes: &[f64]) -> i32 {
    let n = closes.len();
    let mut count: i32 = 0;
    for i in 4..n {
        if closes[i] > closes[i - 4] {
            count = if count > 0 { count + 1 } else { 1 };
        } else if closes[i] < closes[i - 4] {
            count = if count < 0 { count - 1 } else { -1 };
        } else {
            count = 0;
        }
    }
    count
}

/// Aroon up/down as (up, down) pair. Returns None if insufficient data.
/// Matches wat/vocab/regime.wat aroon.
fn aroon(candles: &[Candle], period: usize) -> Option<(f64, f64)> {
    let n = candles.len();
    if n <= period { return None; }
    let slice = &candles[n - period - 1..];
    let mut hi_idx = 0;
    let mut lo_idx = 0;
    for i in 0..=period {
        if slice[i].high >= slice[hi_idx].high { hi_idx = i; }
        if slice[i].low <= slice[lo_idx].low { lo_idx = i; }
    }
    let aroon_up = 100.0 * hi_idx as f64 / period as f64;
    let aroon_down = 100.0 * lo_idx as f64 / period as f64;
    Some((aroon_up, aroon_down))
}

/// Katz fractal dimension: ln(N) / (ln(N) + ln(max_dist/path_len)).
/// Returns None if degenerate.
/// Matches wat/vocab/regime.wat fractal-dimension.
fn fractal_dimension(closes: &[f64]) -> Option<f64> {
    let n = closes.len();
    let mut path_len = 0.0_f64;
    let mut max_dist = 0.0_f64;
    for i in 1..n {
        path_len += ((closes[i] - closes[i - 1]).powi(2) + 1.0).sqrt();
        let dist = (closes[i] - closes[0]).abs();
        if dist > max_dist { max_dist = dist; }
    }
    if path_len > 1e-10 && max_dist > 1e-10 {
        let nf = n as f64;
        Some((nf.ln() / (nf.ln() + (max_dist / path_len).ln())).clamp(1.0, 2.0))
    } else {
        None
    }
}

/// Bigram conditional entropy of return classes (up/flat/down).
/// Normalized by ln(3). Returns None if < 20 returns.
/// Matches wat/vocab/regime.wat entropy-rate.
fn entropy_rate(returns: &[f64]) -> Option<f64> {
    if returns.len() < 20 { return None; }
    let classes: Vec<u8> = returns.iter().map(|&r| {
        if r > 0.0001 { 2 } else if r < -0.0001 { 0 } else { 1 }
    }).collect();
    let mut bigrams = [[0u32; 3]; 3];
    let mut unigrams = [0u32; 3];
    for w in classes.windows(2) {
        bigrams[w[0] as usize][w[1] as usize] += 1;
        unigrams[w[0] as usize] += 1;
    }
    let total = (classes.len() - 1) as f64;
    let mut h_cond = 0.0_f64;
    for i in 0..3 {
        if unigrams[i] == 0 { continue; }
        let p_i = unigrams[i] as f64 / total;
        for j in 0..3 {
            if bigrams[i][j] == 0 { continue; }
            let p_j_given_i = bigrams[i][j] as f64 / unigrams[i] as f64;
            h_cond -= p_i * p_j_given_i * p_j_given_i.ln();
        }
    }
    Some(h_cond / 3.0_f64.ln())
}

/// Gutenberg-Richter b-value. Seismology frequency-magnitude relationship.
/// b < 1 = heavy tails. Returns None if < 20 returns or insufficient thresholds.
/// Matches wat/vocab/regime.wat gr-bvalue.
fn gr_bvalue(returns: &[f64]) -> Option<f64> {
    if returns.len() < 20 { return None; }
    let mut abs_returns: Vec<f64> = returns.iter().map(|r| r.abs()).collect();
    abs_returns.sort_by(|a, b| a.partial_cmp(b).unwrap());
    let nr = abs_returns.len();
    let thresholds: Vec<f64> = (1..5).map(|i| abs_returns[nr * i / 5]).collect();
    let mut log_n = Vec::new();
    let mut log_m = Vec::new();
    for &t in &thresholds {
        if t < 1e-10 { continue; }
        let count = abs_returns.iter().filter(|&&r| r >= t).count();
        if count > 0 {
            log_n.push((count as f64).ln());
            log_m.push(t.ln());
        }
    }
    if log_n.len() < 3 { return None; }
    linreg_slope(&log_m, &log_n).map(|slope| -slope)
}

pub fn eval_regime(candles: &[Candle]) -> Vec<Fact<'static>> {
    let n = candles.len();
    let mut facts: Vec<Fact<'static>> = Vec::new();
    if n < 20 { return facts; }

    let closes: Vec<f64> = candles.iter().map(|c| c.close).collect();

    // ── KAMA Efficiency Ratio ─────────────────────────────────────
    let er = kama_er(&closes);
    facts.push(Fact::Zone { indicator: "kama-er", zone: if er > 0.6 { "efficient-trend" }
        else if er < 0.3 { "inefficient-chop" }
        else { "moderate-efficiency" } });

    // ── Choppiness Index (14-period) ──────────────────────────────
    let chop = choppiness_index(candles);
    facts.push(Fact::Zone { indicator: "chop", zone: if chop < 38.2 { "chop-trending" }
        else if chop > 75.0 { "chop-extreme" }
        else if chop > 61.8 { "chop-choppy" }
        else { "chop-transition" } });

    // ── DFA Alpha (detrended fluctuation analysis) ────────────────
    let returns: Vec<f64> = (1..n).map(|i| (closes[i] / closes[i - 1]).ln()).collect();
    if let Some(alpha) = dfa_alpha(&returns) {
        facts.push(Fact::Zone { indicator: "dfa-alpha", zone: if alpha > 0.6 { "persistent-dfa" }
            else if alpha < 0.4 { "anti-persistent-dfa" }
            else { "random-walk-dfa" } });
    }

    // ── Variance Ratio (k=5) ─────────────────────────────────────
    if let Some(vr) = variance_ratio(&returns, 5) {
        facts.push(Fact::Zone { indicator: "variance-ratio", zone: if vr > 1.3 { "vr-momentum" }
            else if vr < 0.7 { "vr-mean-revert" }
            else { "vr-neutral" } });
    }

    // ── DeMark TD Sequential ─────────────────────────────────────
    if n >= 5 {
        let count = td_count(&closes);
        let abs_count = count.unsigned_abs();
        facts.push(Fact::Zone { indicator: "td-count", zone: if abs_count >= 9 { "td-exhausted" }
            else if abs_count >= 7 { "td-mature" }
            else if abs_count >= 4 { "td-building" }
            else { "td-inactive" } });
    }

    // ── Aroon (25-period) ────────────────────────────────────────
    let aroon_period = 25.min(n - 1);
    if let Some((aroon_up, aroon_down)) = aroon(candles, aroon_period) {
        facts.push(Fact::Zone { indicator: "aroon-up", zone: if aroon_up > 80.0 && aroon_down < 30.0 { "aroon-strong-up" }
            else if aroon_down > 80.0 && aroon_up < 30.0 { "aroon-strong-down" }
            else if aroon_up < 20.0 && aroon_down < 20.0 { "aroon-stale" }
            else { "aroon-consolidating" } });
    }

    // ── Fractal Dimension (Katz) ─────────────────────────────────
    if let Some(fd) = fractal_dimension(&closes) {
        facts.push(Fact::Zone { indicator: "fractal-dim", zone: if fd < 1.3 { "trending-geometry" }
            else if fd > 1.7 { "mean-reverting-geometry" }
            else { "random-walk-geometry" } });
    }

    // ── Entropy Rate (bigram conditional entropy) ────────────────
    if let Some(h_norm) = entropy_rate(&returns) {
        facts.push(Fact::Zone { indicator: "entropy-rate", zone: if h_norm < 0.7 { "low-entropy-rate" }
            else { "high-entropy-rate" } });
    }

    // ── Gutenberg-Richter b-value (seismology) ───────────────────
    if let Some(b) = gr_bvalue(&returns) {
        facts.push(Fact::Zone { indicator: "gr-bvalue",
            zone: if b < 1.0 { "heavy-tails" } else { "light-tails" } });
    }

    // ── Trend consistency (pre-computed on Candle) ─────────────────
    // What fraction of recent candles closed in the same direction?
    // High consistency = trending. Low = choppy.
    let now = candles.last().unwrap();
    facts.push(Fact::Scalar { indicator: "trend-consistency-6", value: now.trend_consistency_6, scale: 1.0 });
    facts.push(Fact::Scalar { indicator: "trend-consistency-12", value: now.trend_consistency_12, scale: 1.0 });
    facts.push(Fact::Scalar { indicator: "trend-consistency-24", value: now.trend_consistency_24, scale: 1.0 });

    // Strong trend at multiple scales = conviction. Disagreement = noise.
    if now.trend_consistency_6 > 0.8 && now.trend_consistency_12 > 0.7 {
        facts.push(Fact::Zone { indicator: "trend", zone: "trend-strong" });
    } else if now.trend_consistency_6 < 0.35 && now.trend_consistency_12 < 0.4 {
        facts.push(Fact::Zone { indicator: "trend", zone: "trend-choppy" });
    }

    // ── Volatility acceleration (pre-computed on Candle) ─────────
    // Is ATR expanding or contracting? Expanding = breakout. Contracting = squeeze building.
    facts.push(Fact::Scalar { indicator: "atr-roc-6", value: now.atr_roc_6.clamp(-1.0, 1.0) * 0.5 + 0.5, scale: 1.0 });
    facts.push(Fact::Scalar { indicator: "atr-roc-12", value: now.atr_roc_12.clamp(-1.0, 1.0) * 0.5 + 0.5, scale: 1.0 });

    if now.atr_roc_6 > 0.2 {
        facts.push(Fact::Zone { indicator: "volatility", zone: "vol-expanding" });
    } else if now.atr_roc_6 < -0.15 {
        facts.push(Fact::Zone { indicator: "volatility", zone: "vol-contracting" });
    }

    // ── Range position at multiple scales (pre-computed on Candle) ──
    // Where is price in the range? 0.0 = at low. 1.0 = at high.
    facts.push(Fact::Scalar { indicator: "range-pos-12", value: now.range_pos_12, scale: 1.0 });
    facts.push(Fact::Scalar { indicator: "range-pos-24", value: now.range_pos_24, scale: 1.0 });
    facts.push(Fact::Scalar { indicator: "range-pos-48", value: now.range_pos_48, scale: 1.0 });

    facts
}
