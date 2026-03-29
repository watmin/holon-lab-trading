//! PELT change-point detection on scalar time series.
//!
//! Finds structural breaks in indicator streams. The segments between
//! changepoints become the narrative facts that experts think about.

/// PELT change-point detection on raw scalar values.
/// Returns changepoint indices (boundaries between segments).
pub fn pelt_changepoints(values: &[f64], penalty: f64) -> Vec<usize> {
    let n = values.len();
    if n < 3 { return vec![]; }

    let mut cum_sum = vec![0.0; n + 1];
    let mut cum_sq = vec![0.0; n + 1];
    for i in 0..n {
        cum_sum[i + 1] = cum_sum[i] + values[i];
        cum_sq[i + 1] = cum_sq[i] + values[i] * values[i];
    }

    let seg_cost = |s: usize, t: usize| -> f64 {
        let len = (t - s) as f64;
        if len < 1.0 { return 0.0; }
        let sm = cum_sum[t] - cum_sum[s];
        let sq = cum_sq[t] - cum_sq[s];
        sq - sm * sm / len
    };

    let mut best_cost = vec![0.0_f64; n + 1];
    let mut last_change = vec![0usize; n + 1];
    let mut candidates: Vec<usize> = vec![0];

    for t in 1..=n {
        let mut best = f64::MAX;
        let mut best_s = 0;
        for &s in &candidates {
            let cost = best_cost[s] + seg_cost(s, t) + penalty;
            if cost < best {
                best = cost;
                best_s = s;
            }
        }
        best_cost[t] = best;
        last_change[t] = best_s;

        candidates.retain(|&s| best_cost[s] + seg_cost(s, t) <= best_cost[t] + penalty);
        candidates.push(t);
    }

    let mut cps = vec![];
    let mut t = n;
    while t > 0 {
        let s = last_change[t];
        if s > 0 { cps.push(s); }
        t = s;
    }
    cps.reverse();
    cps
}

/// BIC-derived penalty: 2 * variance * log(n)
pub fn bic_penalty(values: &[f64]) -> f64 {
    let n = values.len() as f64;
    if n < 2.0 { return 1e10; }
    let mean = values.iter().sum::<f64>() / n;
    let var = values.iter().map(|v| (v - mean).powi(2)).sum::<f64>() / n;
    if var < 1e-20 { return 1e10; }
    2.0 * var * n.ln()
}

/// Direction of the most recent PELT segment: "up", "down", or None if degenerate.
pub fn most_recent_segment_dir(values: &[f64]) -> Option<&'static str> {
    if values.len() < 5 { return None; }
    let penalty = bic_penalty(values);
    let cps = pelt_changepoints(values, penalty);
    let start = cps.last().copied().unwrap_or(0);
    let end = values.len();
    if end <= start { return None; }
    let change = values[end - 1] - values[start];
    if change.abs() < 1e-10 { None }
    else if change > 0.0 { Some("up") }
    else { Some("down") }
}
