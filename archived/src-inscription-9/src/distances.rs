/// Distances and Levels — exit values as percentages, then absolute prices.

use crate::enums::Side;

/// Four exit values as percentages of price.
#[derive(Clone, Debug)]
pub struct Distances {
    pub trail: f64,
    pub stop: f64,
    pub tp: f64,
    pub runner_trail: f64,
}

impl Distances {
    pub fn new(trail: f64, stop: f64, tp: f64, runner_trail: f64) -> Self {
        Self { trail, stop, tp, runner_trail }
    }
}

/// Absolute price levels for stops.
#[derive(Clone, Debug)]
pub struct Levels {
    pub trail_stop: f64,
    pub safety_stop: f64,
    pub take_profit: f64,
    pub runner_trail_stop: f64,
}

impl Levels {
    pub fn new(trail_stop: f64, safety_stop: f64, take_profit: f64, runner_trail_stop: f64) -> Self {
        Self { trail_stop, safety_stop, take_profit, runner_trail_stop }
    }
}

/// Convert percentages to absolute prices. Side-dependent.
/// Buy: stops below price, TP above.
/// Sell: stops above price, TP below.
pub fn distances_to_levels(d: &Distances, price: f64, side: &Side) -> Levels {
    match side {
        Side::Buy => Levels::new(
            price * (1.0 - d.trail),        // trail-stop below
            price * (1.0 - d.stop),         // safety-stop below
            price * (1.0 + d.tp),           // take-profit above
            price * (1.0 - d.runner_trail), // runner-trail below (wider)
        ),
        Side::Sell => Levels::new(
            price * (1.0 + d.trail),        // trail-stop above
            price * (1.0 + d.stop),         // safety-stop above
            price * (1.0 - d.tp),           // take-profit below
            price * (1.0 + d.runner_trail), // runner-trail above (wider)
        ),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_distances_new() {
        let d = Distances::new(0.01, 0.02, 0.03, 0.015);
        assert_eq!(d.trail, 0.01);
        assert_eq!(d.stop, 0.02);
        assert_eq!(d.tp, 0.03);
        assert_eq!(d.runner_trail, 0.015);
    }

    #[test]
    fn test_levels_new() {
        let l = Levels::new(100.0, 99.0, 103.0, 98.5);
        assert_eq!(l.trail_stop, 100.0);
        assert_eq!(l.safety_stop, 99.0);
        assert_eq!(l.take_profit, 103.0);
        assert_eq!(l.runner_trail_stop, 98.5);
    }

    #[test]
    fn test_distances_to_levels_buy() {
        let d = Distances::new(0.01, 0.02, 0.03, 0.015);
        let price = 100.0;
        let levels = distances_to_levels(&d, price, &Side::Buy);

        // Buy: stops below, TP above
        assert!((levels.trail_stop - 99.0).abs() < 1e-10);
        assert!((levels.safety_stop - 98.0).abs() < 1e-10);
        assert!((levels.take_profit - 103.0).abs() < 1e-10);
        assert!((levels.runner_trail_stop - 98.5).abs() < 1e-10);

        // All stops below price
        assert!(levels.trail_stop < price);
        assert!(levels.safety_stop < price);
        assert!(levels.runner_trail_stop < price);
        // TP above price
        assert!(levels.take_profit > price);
    }

    #[test]
    fn test_distances_to_levels_sell() {
        let d = Distances::new(0.01, 0.02, 0.03, 0.015);
        let price = 100.0;
        let levels = distances_to_levels(&d, price, &Side::Sell);

        // Sell: stops above, TP below
        assert!((levels.trail_stop - 101.0).abs() < 1e-10);
        assert!((levels.safety_stop - 102.0).abs() < 1e-10);
        assert!((levels.take_profit - 97.0).abs() < 1e-10);
        assert!((levels.runner_trail_stop - 101.5).abs() < 1e-10);

        // All stops above price
        assert!(levels.trail_stop > price);
        assert!(levels.safety_stop > price);
        assert!(levels.runner_trail_stop > price);
        // TP below price
        assert!(levels.take_profit < price);
    }

    #[test]
    fn test_buy_sell_signs_opposite() {
        let d = Distances::new(0.01, 0.02, 0.03, 0.015);
        let price = 50000.0;
        let buy = distances_to_levels(&d, price, &Side::Buy);
        let sell = distances_to_levels(&d, price, &Side::Sell);

        // Buy trail is below price, sell trail is above — they bracket
        assert!(buy.trail_stop < price);
        assert!(sell.trail_stop > price);
        // Symmetrically distant
        assert!((price - buy.trail_stop - (sell.trail_stop - price)).abs() < 1e-6);
    }
}
