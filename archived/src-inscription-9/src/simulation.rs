/// Pure functions for trailing stop simulation.
/// No post state. Vec<f64> in, f64 out.

use crate::distances::Distances;
use crate::enums::Direction;

/// Simulate a trailing stop at the given distance.
/// Returns residue: how much value was captured as fraction of entry.
/// price_history: close prices from entry to now.
/// distance: as fraction of entry price.
pub fn simulate_trail(price_history: &[f64], distance: f64) -> f64 {
    if price_history.is_empty() {
        return 0.0;
    }
    let entry = price_history[0];
    if entry == 0.0 {
        return 0.0;
    }

    let mut extreme = entry;
    let mut trail_stop = entry * (1.0 - distance);

    for &price in &price_history[1..] {
        extreme = extreme.max(price);
        trail_stop = trail_stop.max(extreme * (1.0 - distance));
    }

    (trail_stop - entry) / entry
}

/// Simulate a safety stop at the given distance.
/// Returns residue (negative if stop fires before end).
pub fn simulate_stop(price_history: &[f64], distance: f64) -> f64 {
    if price_history.is_empty() {
        return 0.0;
    }
    let entry = price_history[0];
    if entry == 0.0 {
        return 0.0;
    }

    let stop_level = entry * (1.0 - distance);
    let mut best = 0.0_f64;

    for &price in &price_history[1..] {
        if price <= stop_level {
            best = best.min((stop_level - entry) / entry);
        } else {
            best = best.max((price - entry) / entry);
        }
    }

    best
}

/// Simulate a take-profit at the given distance.
/// Returns distance if TP fires, 0.0 otherwise.
pub fn simulate_tp(price_history: &[f64], distance: f64) -> f64 {
    if price_history.is_empty() {
        return 0.0;
    }
    let entry = price_history[0];
    if entry == 0.0 {
        return 0.0;
    }

    let tp_level = entry * (1.0 + distance);
    let mut best = 0.0_f64;

    for &price in &price_history[1..] {
        if price >= tp_level {
            best = best.max(distance);
        }
    }

    best
}

/// Simulate a runner trailing stop at the given distance.
/// Returns residue captured by the wider trail.
pub fn simulate_runner_trail(price_history: &[f64], distance: f64) -> f64 {
    if price_history.is_empty() {
        return 0.0;
    }
    let entry = price_history[0];
    if entry == 0.0 {
        return 0.0;
    }

    let mut extreme = entry;
    let mut trail_stop = entry * (1.0 - distance);
    let mut best = 0.0_f64;

    for &price in &price_history[1..] {
        extreme = extreme.max(price);
        trail_stop = trail_stop.max(extreme * (1.0 - distance));
        best = best.max((trail_stop - entry) / entry);
    }

    best
}

/// Sweep candidates and find the best distance for a given simulate function.
pub fn best_distance(price_history: &[f64], simulate_fn: fn(&[f64], f64) -> f64) -> f64 {
    let steps = 50;
    let lo = 0.002;
    let hi = 0.10;
    let step_size = (hi - lo) / steps as f64;

    let mut best_d = lo;
    let mut best_r = f64::NEG_INFINITY;

    for i in 0..=steps {
        let candidate = lo + i as f64 * step_size;
        let residue = simulate_fn(price_history, candidate);
        if residue > best_r {
            best_d = candidate;
            best_r = residue;
        }
    }

    best_d
}

/// Compute optimal distances for a given price history and direction.
/// Direction-aware: flips the history for Down trades.
pub fn compute_optimal_distances(price_history: &[f64], dir: &Direction) -> Distances {
    let history: Vec<f64> = match dir {
        Direction::Up => price_history.to_vec(),
        // For Down, invert: work with reciprocal prices
        Direction::Down => price_history.iter().map(|p| 1.0 / p).collect(),
    };

    Distances::new(
        best_distance(&history, simulate_trail),
        best_distance(&history, simulate_stop),
        best_distance(&history, simulate_tp),
        best_distance(&history, simulate_runner_trail),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_simulate_trail_uptrend() {
        // Prices go up steadily
        let prices = vec![100.0, 101.0, 102.0, 103.0, 104.0, 105.0];
        let residue = simulate_trail(&prices, 0.02);
        // Trail should have captured some upside
        assert!(residue > 0.0, "Expected positive residue in uptrend, got {}", residue);
    }

    #[test]
    fn test_simulate_trail_downtrend() {
        // Prices go down steadily
        let prices = vec![100.0, 99.0, 98.0, 97.0, 96.0, 95.0];
        let residue = simulate_trail(&prices, 0.02);
        // Trail should be negative — stopped out
        assert!(residue < 0.0, "Expected negative residue in downtrend, got {}", residue);
    }

    #[test]
    fn test_simulate_stop_fires() {
        let prices = vec![100.0, 99.0, 97.0]; // drops 3%
        let residue = simulate_stop(&prices, 0.02); // 2% stop
        assert!(residue < 0.0, "Expected negative residue when stop fires, got {}", residue);
    }

    #[test]
    fn test_simulate_tp_fires() {
        let prices = vec![100.0, 101.0, 102.0, 103.0, 104.0];
        let residue = simulate_tp(&prices, 0.03); // 3% TP
        assert!(residue > 0.0, "Expected positive residue when TP fires, got {}", residue);
    }

    #[test]
    fn test_simulate_tp_no_fire() {
        let prices = vec![100.0, 100.5, 101.0]; // only 1% up
        let residue = simulate_tp(&prices, 0.05); // 5% TP
        assert_eq!(residue, 0.0, "Expected 0.0 when TP does not fire");
    }

    #[test]
    fn test_simulate_runner_trail() {
        let prices = vec![100.0, 102.0, 104.0, 103.0, 105.0, 106.0];
        let residue = simulate_runner_trail(&prices, 0.03);
        assert!(residue > 0.0, "Expected positive residue for runner trail in uptrend");
    }

    #[test]
    fn test_best_distance_returns_reasonable() {
        let prices = vec![100.0, 101.0, 102.0, 103.0, 104.0, 105.0];
        let d = best_distance(&prices, simulate_trail);
        assert!(d >= 0.002 && d <= 0.10, "Expected distance in [0.002, 0.10], got {}", d);
    }

    #[test]
    fn test_compute_optimal_distances_up() {
        let prices = vec![100.0, 101.0, 102.0, 103.0, 104.0, 105.0];
        let d = compute_optimal_distances(&prices, &Direction::Up);
        assert!(d.trail > 0.0);
        assert!(d.stop > 0.0);
    }

    #[test]
    fn test_compute_optimal_distances_down() {
        // Prices going down — for a short, this is profitable
        let prices = vec![100.0, 99.0, 98.0, 97.0, 96.0, 95.0];
        let d = compute_optimal_distances(&prices, &Direction::Down);
        assert!(d.trail > 0.0);
        assert!(d.stop > 0.0);
    }

    #[test]
    fn test_empty_history() {
        assert_eq!(simulate_trail(&[], 0.02), 0.0);
        assert_eq!(simulate_stop(&[], 0.02), 0.0);
        assert_eq!(simulate_tp(&[], 0.02), 0.0);
        assert_eq!(simulate_runner_trail(&[], 0.02), 0.0);
    }
}
