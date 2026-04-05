//! Optimal distance computation — the market's answer.
//!
//! Given a price history (entry to exit), sweep trailing stop distances
//! and find the one that maximizes residue. The distance is a percentage
//! of price. Not a multiplier. Not a formula. A measurement.

/// Result of the optimal distance sweep for one trade.
#[derive(Clone, Copy, Debug)]
pub struct OptimalDistance {
    /// The distance (as fraction of entry price) that maximized residue.
    pub distance_pct: f64,
    /// The residue at that distance (fraction of entry price).
    pub residue: f64,
}

/// Compute the optimal trailing stop distance for a trade's price history.
///
/// `closes`: slice of close prices. Index 0 = entry. Index 1..N = subsequent.
/// `entry_price`: the price at entry (closes[0]).
/// `steps`: number of candidate distances to sweep (resolution).
/// `max_distance_pct`: maximum distance to consider (e.g., 0.05 = 5%).
///
/// Returns the distance that produced the most residue, or None if < 2 candles.
pub fn compute_optimal_distance(
    closes: &[f64],
    entry_price: f64,
    steps: usize,
    max_distance_pct: f64,
) -> Option<OptimalDistance> {
    if closes.len() < 2 || entry_price <= 0.0 { return None; }

    let mut best = OptimalDistance { distance_pct: 0.0, residue: f64::NEG_INFINITY };

    for i in 1..=steps {
        let distance_pct = max_distance_pct * i as f64 / steps as f64;
        let residue = simulate_trail(closes, entry_price, distance_pct);
        if residue > best.residue {
            best = OptimalDistance { distance_pct, residue };
        }
    }

    if best.residue > f64::NEG_INFINITY { Some(best) } else { None }
}

/// Simulate a trailing stop at a given distance and return the residue.
///
/// The trailing stop ratchets upward from entry. When price drops below
/// `extreme * (1 - distance_pct)`, the position closes. The residue is
/// the return at close: `(close_price - entry_price) / entry_price`.
///
/// If the stop never fires, the residue is the final price's return.
fn simulate_trail(closes: &[f64], entry_price: f64, distance_pct: f64) -> f64 {
    let mut extreme = entry_price;
    let mut trail = entry_price * (1.0 - distance_pct);

    for &price in &closes[1..] {
        if price > extreme {
            extreme = price;
            let new_trail = extreme * (1.0 - distance_pct);
            if new_trail > trail { trail = new_trail; }
        }
        if price <= trail {
            // Stop fired. Residue = return at this price.
            return (price - entry_price) / entry_price;
        }
    }

    // Never fired. Residue = return at final price.
    let last = closes[closes.len() - 1];
    (last - entry_price) / entry_price
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn optimal_distance_ascending() {
        // Ascending prices: the optimal stop is tight (ride the trend)
        let closes: Vec<f64> = (0..100).map(|i| 50000.0 + i as f64 * 100.0).collect();
        let opt = compute_optimal_distance(&closes, 50000.0, 100, 0.05).unwrap();
        eprintln!("ascending: optimal distance={:.4}% residue={:.4}%",
            opt.distance_pct * 100.0, opt.residue * 100.0);
        assert!(opt.residue > 0.0, "ascending should produce positive residue");
    }

    #[test]
    fn optimal_distance_reversal() {
        // Up then down: tight stop captures the peak, loose stop gives it back
        let mut closes = Vec::new();
        for i in 0..50 { closes.push(50000.0 + i as f64 * 200.0); } // up
        for i in 0..50 { closes.push(60000.0 - i as f64 * 300.0); } // down hard
        let opt = compute_optimal_distance(&closes, 50000.0, 100, 0.05).unwrap();
        eprintln!("reversal: optimal distance={:.4}% residue={:.4}%",
            opt.distance_pct * 100.0, opt.residue * 100.0);
        // The optimal should be tight enough to capture the peak
        assert!(opt.distance_pct < 0.03, "reversal should want a tight stop");
    }

    #[test]
    fn optimal_distance_choppy() {
        // Choppy: too tight gets stopped out, too loose gives back gains
        let mut closes = Vec::new();
        for i in 0..100 {
            let base = 50000.0 + i as f64 * 20.0; // slight uptrend
            let noise = if i % 3 == 0 { -500.0 } else { 200.0 }; // chop
            closes.push(base + noise);
        }
        let opt = compute_optimal_distance(&closes, 50000.0, 200, 0.05).unwrap();
        eprintln!("choppy: optimal distance={:.4}% residue={:.4}%",
            opt.distance_pct * 100.0, opt.residue * 100.0);
        // Should find a middle ground
        assert!(opt.distance_pct > 0.005, "choppy needs some breathing room");
    }

    #[test]
    fn optimal_distance_from_real_data_shape() {
        // Simulate a realistic BTC-like move: up 3%, retrace 1%, up 2%, crash 5%
        let entry = 50000.0;
        let closes = vec![
            50000.0, 50200.0, 50500.0, 50800.0, 51000.0, 51300.0, 51500.0,
            51200.0, 51000.0, 50800.0, // retrace
            51000.0, 51200.0, 51500.0, 51800.0, // resume
            51500.0, 51000.0, 50500.0, 50000.0, 49500.0, 49000.0, // crash
        ];
        let opt = compute_optimal_distance(&closes, entry, 200, 0.05).unwrap();
        eprintln!("realistic: optimal distance={:.4}% residue={:.4}%",
            opt.distance_pct * 100.0, opt.residue * 100.0);
        eprintln!("  (a {:.2}% stop would have captured the best exit)",
            opt.distance_pct * 100.0);
    }
}
