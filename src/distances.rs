//! distances.wat -- Distances and Levels
//! Depends on: enums.wat (Side)

use crate::enums::Side;

/// The four exit values. Percentage of price, not absolute levels.
/// Observers think in Distances. Trades execute at Levels.
#[derive(Clone, Debug)]
pub struct Distances {
    pub trail: f64,
    pub stop: f64,
    pub tp: f64,
    pub runner_trail: f64,
}

impl Distances {
    pub fn new(trail: f64, stop: f64, tp: f64, runner_trail: f64) -> Self {
        Self {
            trail,
            stop,
            tp,
            runner_trail,
        }
    }

    /// Converts percentage distances to absolute price levels.
    /// Side-dependent: buy stops are below price, sell stops are above.
    /// One place to get the signs right.
    pub fn to_levels(&self, price: f64, side: Side) -> Levels {
        match side {
            Side::Buy => Levels {
                trail_stop: price * (1.0 - self.trail),
                safety_stop: price * (1.0 - self.stop),
                take_profit: price * (1.0 + self.tp),
                runner_trail_stop: price * (1.0 - self.runner_trail),
            },
            Side::Sell => Levels {
                trail_stop: price * (1.0 + self.trail),
                safety_stop: price * (1.0 + self.stop),
                take_profit: price * (1.0 - self.tp),
                runner_trail_stop: price * (1.0 + self.runner_trail),
            },
        }
    }
}

/// Absolute price levels. Computed from distance x price.
#[derive(Clone, Debug)]
pub struct Levels {
    pub trail_stop: f64,
    pub safety_stop: f64,
    pub take_profit: f64,
    pub runner_trail_stop: f64,
}

impl Levels {
    pub fn new(
        trail_stop: f64,
        safety_stop: f64,
        take_profit: f64,
        runner_trail_stop: f64,
    ) -> Self {
        Self {
            trail_stop,
            safety_stop,
            take_profit,
            runner_trail_stop,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn approx(a: f64, b: f64) -> bool {
        (a - b).abs() < 1e-10
    }

    #[test]
    fn test_distances_construct() {
        let d = Distances::new(0.02, 0.05, 0.03, 0.01);
        assert_eq!(d.trail, 0.02);
        assert_eq!(d.stop, 0.05);
        assert_eq!(d.tp, 0.03);
        assert_eq!(d.runner_trail, 0.01);
    }

    #[test]
    fn test_levels_construct() {
        let l = Levels::new(98.0, 95.0, 103.0, 99.0);
        assert_eq!(l.trail_stop, 98.0);
        assert_eq!(l.safety_stop, 95.0);
        assert_eq!(l.take_profit, 103.0);
        assert_eq!(l.runner_trail_stop, 99.0);
    }

    // ── The critical test: Buy side signs ─────────────────────────────

    #[test]
    fn test_distances_to_levels_buy() {
        let d = Distances::new(0.02, 0.05, 0.03, 0.01);
        let price = 100.0;
        let levels = d.to_levels(price, Side::Buy);

        // Buy: trail-stop BELOW price
        assert!(approx(levels.trail_stop, 98.0)); // 100 * (1 - 0.02)
        assert!(levels.trail_stop < price, "Buy trail-stop must be below price");

        // Buy: safety-stop BELOW price
        assert!(approx(levels.safety_stop, 95.0)); // 100 * (1 - 0.05)
        assert!(levels.safety_stop < price, "Buy safety-stop must be below price");

        // Buy: take-profit ABOVE price
        assert!(approx(levels.take_profit, 103.0)); // 100 * (1 + 0.03)
        assert!(levels.take_profit > price, "Buy take-profit must be above price");

        // Buy: runner-trail-stop BELOW price
        assert!(approx(levels.runner_trail_stop, 99.0)); // 100 * (1 - 0.01)
        assert!(levels.runner_trail_stop < price, "Buy runner-trail must be below price");
    }

    // ── The critical test: Sell side signs ─────────────────────────────

    #[test]
    fn test_distances_to_levels_sell() {
        let d = Distances::new(0.02, 0.05, 0.03, 0.01);
        let price = 100.0;
        let levels = d.to_levels(price, Side::Sell);

        // Sell: trail-stop ABOVE price
        assert!(approx(levels.trail_stop, 102.0)); // 100 * (1 + 0.02)
        assert!(levels.trail_stop > price, "Sell trail-stop must be above price");

        // Sell: safety-stop ABOVE price
        assert!(approx(levels.safety_stop, 105.0)); // 100 * (1 + 0.05)
        assert!(levels.safety_stop > price, "Sell safety-stop must be above price");

        // Sell: take-profit BELOW price
        assert!(approx(levels.take_profit, 97.0)); // 100 * (1 - 0.03)
        assert!(levels.take_profit < price, "Sell take-profit must be below price");

        // Sell: runner-trail-stop ABOVE price
        assert!(approx(levels.runner_trail_stop, 101.0)); // 100 * (1 + 0.01)
        assert!(levels.runner_trail_stop > price, "Sell runner-trail must be above price");
    }

    // ── Buy and Sell are mirror images ────────────────────────────────

    #[test]
    fn test_buy_sell_mirror() {
        let d = Distances::new(0.02, 0.05, 0.03, 0.01);
        let price = 50000.0; // BTC-like price
        let buy = d.to_levels(price, Side::Buy);
        let sell = d.to_levels(price, Side::Sell);

        // Trail-stop: buy below, sell above, symmetric around price
        assert!(approx(price - buy.trail_stop, sell.trail_stop - price));
        // Safety-stop: buy below, sell above, symmetric around price
        assert!(approx(price - buy.safety_stop, sell.safety_stop - price));
        // Take-profit: buy above, sell below, symmetric around price
        assert!(approx(buy.take_profit - price, price - sell.take_profit));
        // Runner-trail: buy below, sell above, symmetric around price
        assert!(approx(price - buy.runner_trail_stop, sell.runner_trail_stop - price));
    }

    // ── Safety stop wider than trail stop ────────────────────────────

    #[test]
    fn test_safety_stop_wider_than_trail_buy() {
        let d = Distances::new(0.02, 0.05, 0.03, 0.01);
        let price = 100.0;
        let levels = d.to_levels(price, Side::Buy);
        // Safety stop is farther from price than trail stop
        assert!(levels.safety_stop < levels.trail_stop,
                "Buy: safety-stop should be farther below price than trail-stop");
    }

    #[test]
    fn test_safety_stop_wider_than_trail_sell() {
        let d = Distances::new(0.02, 0.05, 0.03, 0.01);
        let price = 100.0;
        let levels = d.to_levels(price, Side::Sell);
        // Safety stop is farther from price than trail stop
        assert!(levels.safety_stop > levels.trail_stop,
                "Sell: safety-stop should be farther above price than trail-stop");
    }
}
