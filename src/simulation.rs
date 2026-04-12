/// Pure simulation functions for trailing stop mechanics. Compiled from wat/simulation.wat.
///
/// Vec<f64> in, f64 out. No state. No side effects.

use crate::distances::Distances;
use crate::enums::Direction;

/// Simulate a trailing stop at the given distance. Returns residue.
///
/// The trailing stop ratchets in the direction of movement.
/// Distance is a fraction of the entry price.
/// Residue = (exit_price - entry) / entry.
pub fn simulate_trail(prices: &[f64], distance: f64) -> f64 {
    if prices.is_empty() {
        return 0.0;
    }

    let entry = prices[0];
    let mut extreme = entry;
    let mut trail_level = entry * (1.0 - distance);
    let mut stopped = false;
    let mut exit_price = entry;

    for &price in &prices[1..] {
        if stopped {
            break;
        }
        if price <= trail_level {
            // Stop fired
            exit_price = price;
            stopped = true;
        } else {
            // Ratchet up
            if price > extreme {
                extreme = price;
                trail_level = extreme * (1.0 - distance);
            }
        }
    }

    if !stopped {
        exit_price = *prices.last().unwrap();
    }

    (exit_price - entry) / entry
}

/// Simulate a fixed safety stop at the given distance. Returns residue.
///
/// The safety stop is fixed at entry: stop_level = entry * (1 - distance).
/// If price drops below stop_level, the stop fires.
/// Residue = (exit_price - entry) / entry.
pub fn simulate_stop(prices: &[f64], distance: f64) -> f64 {
    if prices.is_empty() {
        return 0.0;
    }

    let entry = prices[0];
    let stop_level = entry * (1.0 - distance);
    let mut stopped = false;
    let mut exit_price = entry;

    for &price in &prices[1..] {
        if stopped {
            break;
        }
        if price <= stop_level {
            exit_price = price;
            stopped = true;
        }
    }

    if !stopped {
        exit_price = *prices.last().unwrap();
    }

    (exit_price - entry) / entry
}

/// Sweep candidate distances, evaluate each via simulate_fn, return
/// the distance that produces the maximum NET residue (after fees).
/// Candidates: 0.5% to 10% in 0.5% increments (20 candidates).
/// swap_fee: per-swap fee as a fraction (e.g. 0.0035 = 35bps).
/// Net residue = gross_residue - entry_fee - exit_fee.
pub fn best_distance(prices: &[f64], simulate_fn: fn(&[f64], f64) -> f64, swap_fee: f64) -> f64 {
    use rayon::prelude::*;
    (0..20)
        .into_par_iter()
        .map(|i| {
            let d = (i + 1) as f64 * 0.005;
            let gross = simulate_fn(prices, d);
            // Net: subtract entry fee + exit fee (as fractions of entry)
            let entry_fee = swap_fee;
            let exit_fee = (1.0 + gross) * swap_fee;
            let net = gross - entry_fee - exit_fee;
            (d, net)
        })
        .reduce(
            || (0.005, f64::NEG_INFINITY),
            |(d1, r1), (d2, r2)| if r2 > r1 { (d2, r2) } else { (d1, r1) },
        )
        .0
}

/// Compute optimal trail and stop distances for a price history.
/// Fee-aware: optimizes for NET residue after entry + exit swap fees.
///
/// For Direction::Down, the price history is inverted (1/price) so the same
/// trailing-stop logic applies symmetrically.
pub fn compute_optimal_distances(price_history: &[f64], direction: Direction, swap_fee: f64) -> Distances {
    let oriented: Vec<f64> = match direction {
        Direction::Up => price_history.to_vec(),
        Direction::Down => price_history.iter().map(|&p| 1.0 / p).collect(),
    };

    let trail = best_distance(&oriented, simulate_trail, swap_fee);
    let stop = best_distance(&oriented, simulate_stop, swap_fee);

    Distances::new(trail, stop)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_simulate_trail_empty() {
        assert_eq!(simulate_trail(&[], 0.05), 0.0);
    }

    #[test]
    fn test_simulate_stop_empty() {
        assert_eq!(simulate_stop(&[], 0.05), 0.0);
    }

    #[test]
    fn test_simulate_trail_rising_prices() {
        // Price goes up steadily -- trail ratchets up, never fires
        let prices: Vec<f64> = (0..10).map(|i| 100.0 + i as f64).collect();
        let residue = simulate_trail(&prices, 0.05);
        // Last price is 109, entry is 100
        assert!((residue - 0.09).abs() < 1e-10, "got {}", residue);
    }

    #[test]
    fn test_simulate_trail_drop_fires() {
        // Price rises to 110 then drops to 100
        let prices = vec![100.0, 105.0, 110.0, 105.0, 100.0];
        let residue = simulate_trail(&prices, 0.05);
        // Trail at peak 110: 110 * 0.95 = 104.5
        // Price 105 > 104.5 (no fire), price 100 < 104.5 (fire at 100)
        // Residue = (100 - 100) / 100 = 0.0
        assert!((residue - 0.0).abs() < 1e-10, "got {}", residue);
    }

    #[test]
    fn test_simulate_stop_drop_fires() {
        // Price drops below safety stop
        let prices = vec![100.0, 98.0, 94.0, 90.0];
        let residue = simulate_stop(&prices, 0.05);
        // Stop level = 100 * 0.95 = 95.0
        // Price 98 > 95 (no fire), price 94 < 95 (fire at 94)
        // Residue = (94 - 100) / 100 = -0.06
        assert!((residue - (-0.06)).abs() < 1e-10, "got {}", residue);
    }

    #[test]
    fn test_simulate_stop_no_fire() {
        // Price stays above safety stop
        let prices = vec![100.0, 98.0, 99.0, 101.0, 103.0];
        let residue = simulate_stop(&prices, 0.05);
        // Stop level = 95.0, never breached. Use last price 103.
        // Residue = (103 - 100) / 100 = 0.03
        assert!((residue - 0.03).abs() < 1e-10, "got {}", residue);
    }

    #[test]
    fn test_best_distance_selects_max_residue() {
        // Steady rise -- larger distance means trail never fires, all distances
        // produce the same residue (last price). best_distance returns a valid candidate.
        let prices: Vec<f64> = (0..50).map(|i| 100.0 + i as f64 * 0.5).collect();
        let d = best_distance(&prices, simulate_trail, 0.0);
        // Should be a valid candidate in [0.005, 0.100]
        assert!(d >= 0.005 && d <= 0.100, "got {}", d);
    }

    #[test]
    fn test_compute_optimal_distances_up() {
        // Rising prices
        let prices: Vec<f64> = (0..100).map(|i| 100.0 + i as f64 * 0.3).collect();
        let dist = compute_optimal_distances(&prices, Direction::Up, 0.0035);
        assert!(dist.trail > 0.0 && dist.trail <= 0.10);
        assert!(dist.stop > 0.0 && dist.stop <= 0.10);
    }

    #[test]
    fn test_compute_optimal_distances_down_inverts() {
        // Falling prices -- Down inverts them
        let prices: Vec<f64> = (0..100).map(|i| 100.0 - i as f64 * 0.3).collect();
        let dist = compute_optimal_distances(&prices, Direction::Down, 0.0035);
        // After inversion, it looks like rising prices
        assert!(dist.trail > 0.0 && dist.trail <= 0.10);
        assert!(dist.stop > 0.0 && dist.stop <= 0.10);
    }

    #[test]
    fn test_trail_fires_at_correct_level() {
        // Entry 100, peak 120, then drop
        let prices = vec![100.0, 110.0, 120.0, 115.0, 110.0, 105.0];
        let residue = simulate_trail(&prices, 0.10);
        // Trail at peak 120: 120 * 0.90 = 108.0
        // 115 > 108 (ok), 110 > 108 (ok), 105 < 108 (fire at 105)
        // Residue = (105 - 100) / 100 = 0.05
        assert!((residue - 0.05).abs() < 1e-10, "got {}", residue);
    }
}
