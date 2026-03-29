//! vocab/regime — market regime characterization
//!
//! Abstract properties of the price series: is it trending or choppy?
//! Persistent or mean-reverting? Orderly or chaotic?
//!
//! These survive window noise better than candle-level patterns.
//! The regime expert's exclusive vocabulary.

use crate::candle::Candle;
use super::Fact;

pub fn eval_regime(candles: &[Candle]) -> Vec<Fact<'static>> {
    let n = candles.len();
    let mut facts: Vec<Fact<'static>> = Vec::new();
    if n < 20 { return facts; }

    let closes: Vec<f64> = candles.iter().map(|c| c.close).collect();

    // ── KAMA Efficiency Ratio ─────────────────────────────────────
    let er_period = 10.min(n - 1);
    let net_move = (closes[n - 1] - closes[n - 1 - er_period]).abs();
    let step_sum: f64 = (n - er_period..n).map(|i| (closes[i] - closes[i - 1]).abs()).sum();
    let er = if step_sum > 1e-10 { net_move / step_sum } else { 0.0 };
    facts.push(Fact::Zone { indicator: "kama-er", zone: if er > 0.6 { "efficient-trend" }
        else if er < 0.3 { "inefficient-chop" }
        else { "moderate-efficiency" } });

    // ── Choppiness Index (14-period) ──────────────────────────────
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
    let chop = if chop_range > 1e-10 {
        100.0 * (chop_atr_sum / chop_range).log10() / (chop_period as f64).log10()
    } else { 100.0 };
    facts.push(Fact::Zone { indicator: "chop", zone: if chop < 38.2 { "chop-trending" }
        else if chop > 75.0 { "chop-extreme" }
        else if chop > 61.8 { "chop-choppy" }
        else { "chop-transition" } });

    // ── DFA Alpha (detrended fluctuation analysis) ────────────────
    let returns: Vec<f64> = (1..n).map(|i| (closes[i] / closes[i - 1]).ln()).collect();
    if returns.len() >= 16 {
        let ret_mean = returns.iter().sum::<f64>() / returns.len() as f64;
        let integrated: Vec<f64> = returns.iter()
            .scan(0.0, |acc, &r| { *acc += r - ret_mean; Some(*acc) }).collect();
        let scales: Vec<usize> = vec![4, 6, 8, 12, 16].into_iter()
            .filter(|&s| s <= integrated.len()).collect();
        if scales.len() >= 3 {
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
            if log_f.len() >= 3 {
                let nf = log_f.len() as f64;
                let sx: f64 = log_s.iter().sum();
                let sy: f64 = log_f.iter().sum();
                let sxx: f64 = log_s.iter().map(|x| x * x).sum();
                let sxy: f64 = log_s.iter().zip(log_f.iter()).map(|(x, y)| x * y).sum();
                let denom = nf * sxx - sx * sx;
                if denom.abs() > 1e-10 {
                    let alpha = ((nf * sxy - sx * sy) / denom).clamp(0.0, 1.5);
                    facts.push(Fact::Zone { indicator: "dfa-alpha", zone: if alpha > 0.6 { "persistent-dfa" }
                        else if alpha < 0.4 { "anti-persistent-dfa" }
                        else { "random-walk-dfa" } });
                }
            }
        }
    }

    // ── Variance Ratio (k=5) ─────────────────────────────────────
    if returns.len() >= 10 {
        let var1: f64 = returns.iter().map(|r| r * r).sum::<f64>() / returns.len() as f64;
        let k = 5usize;
        let k_returns: Vec<f64> = (0..returns.len() - k + 1)
            .map(|i| returns[i..i + k].iter().sum::<f64>()).collect();
        if !k_returns.is_empty() && var1 > 1e-20 {
            let var_k: f64 = k_returns.iter().map(|r| r * r).sum::<f64>()
                / k_returns.len() as f64 / k as f64;
            let vr = var_k / var1;
            facts.push(Fact::Zone { indicator: "variance-ratio", zone: if vr > 1.3 { "vr-momentum" }
                else if vr < 0.7 { "vr-mean-revert" }
                else { "vr-neutral" } });
        }
    }

    // ── DeMark TD Sequential ─────────────────────────────────────
    if n >= 5 {
        let mut count: i32 = 0;
        for i in 4..n {
            if closes[i] > closes[i - 4] {
                count = if count > 0 { count + 1 } else { 1 };
            } else if closes[i] < closes[i - 4] {
                count = if count < 0 { count - 1 } else { -1 };
            } else { count = 0; }
        }
        let abs_count = count.unsigned_abs();
        facts.push(Fact::Zone { indicator: "td-count", zone: if abs_count >= 9 { "td-exhausted" }
            else if abs_count >= 7 { "td-mature" }
            else if abs_count >= 4 { "td-building" }
            else { "td-inactive" } });
    }

    // ── Aroon (25-period) ────────────────────────────────────────
    let aroon_period = 25.min(n - 1);
    if n > aroon_period {
        let slice = &candles[n - aroon_period - 1..];
        let mut hi_idx = 0;
        let mut lo_idx = 0;
        for i in 0..=aroon_period {
            if slice[i].high >= slice[hi_idx].high { hi_idx = i; }
            if slice[i].low <= slice[lo_idx].low { lo_idx = i; }
        }
        let aroon_up = 100.0 * hi_idx as f64 / aroon_period as f64;
        let aroon_down = 100.0 * lo_idx as f64 / aroon_period as f64;
        facts.push(Fact::Zone { indicator: "aroon-up", zone: if aroon_up > 80.0 && aroon_down < 30.0 { "aroon-strong-up" }
            else if aroon_down > 80.0 && aroon_up < 30.0 { "aroon-strong-down" }
            else if aroon_up < 20.0 && aroon_down < 20.0 { "aroon-stale" }
            else { "aroon-consolidating" } });
    }

    // ── Fractal Dimension (Katz) ─────────────────────────────────
    {
        let path_len: f64 = (1..n).map(|i| ((closes[i] - closes[i-1]).powi(2) + 1.0).sqrt()).sum();
        let max_dist = closes.iter().map(|&c| (c - closes[0]).abs()).fold(0.0_f64, f64::max);
        if path_len > 1e-10 && max_dist > 1e-10 {
            let nf = n as f64;
            let fd = (nf.ln() / (nf.ln() + (max_dist / path_len).ln())).clamp(1.0, 2.0);
            facts.push(Fact::Zone { indicator: "fractal-dim", zone: if fd < 1.3 { "trending-geometry" }
                else if fd > 1.7 { "mean-reverting-geometry" }
                else { "random-walk-geometry" } });
        }
    }

    // ── Entropy Rate (bigram conditional entropy) ────────────────
    if returns.len() >= 20 {
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
        let h_norm = h_cond / 3.0_f64.ln();
        facts.push(Fact::Zone { indicator: "entropy-rate", zone: if h_norm < 0.7 { "low-entropy-rate" }
            else { "high-entropy-rate" } });
    }

    // ── Gutenberg-Richter b-value (seismology) ───────────────────
    if returns.len() >= 20 {
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
        if log_n.len() >= 3 {
            let nf = log_n.len() as f64;
            let sx: f64 = log_m.iter().sum();
            let sy: f64 = log_n.iter().sum();
            let sxx: f64 = log_m.iter().map(|x| x * x).sum();
            let sxy: f64 = log_m.iter().zip(log_n.iter()).map(|(x, y)| x * y).sum();
            let denom = nf * sxx - sx * sx;
            if denom.abs() > 1e-10 {
                let b = -(nf * sxy - sx * sy) / denom;
                facts.push(Fact::Zone { indicator: "gr-bvalue",
                    zone: if b < 1.0 { "heavy-tails" } else { "light-tails" } });
            }
        }
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
