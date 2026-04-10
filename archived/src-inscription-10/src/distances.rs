/// Two representations of exit thresholds. Compiled from wat/distances.wat.

use crate::enums::Side;

/// Distances: percentage of price. Scale-free.
#[derive(Clone, Copy, Debug)]
pub struct Distances {
    pub trail: f64,
    pub stop: f64,
}

impl Distances {
    pub fn new(trail: f64, stop: f64) -> Self {
        Self { trail, stop }
    }

    /// Convert percentage distances to absolute price levels.
    pub fn to_levels(&self, price: f64, side: Side) -> Levels {
        match side {
            Side::Buy => Levels {
                trail_stop: price - price * self.trail,
                safety_stop: price - price * self.stop,
            },
            Side::Sell => Levels {
                trail_stop: price + price * self.trail,
                safety_stop: price + price * self.stop,
            },
        }
    }
}

/// Levels: absolute price levels. Stored on Trade.
#[derive(Clone, Copy, Debug)]
pub struct Levels {
    pub trail_stop: f64,
    pub safety_stop: f64,
}

impl Levels {
    pub fn new(trail_stop: f64, safety_stop: f64) -> Self {
        Self {
            trail_stop,
            safety_stop,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_distances_new() {
        let d = Distances::new(0.02, 0.05);
        assert!((d.trail - 0.02).abs() < 1e-10);
        assert!((d.stop - 0.05).abs() < 1e-10);
    }

    #[test]
    fn test_levels_new() {
        let l = Levels::new(49000.0, 47500.0);
        assert!((l.trail_stop - 49000.0).abs() < 1e-10);
        assert!((l.safety_stop - 47500.0).abs() < 1e-10);
    }

    #[test]
    fn test_distances_to_levels_buy() {
        let d = Distances::new(0.05, 0.10);
        let levels = d.to_levels(100.0, Side::Buy);
        assert!((levels.trail_stop - 95.0).abs() < 1e-10);
        assert!((levels.safety_stop - 90.0).abs() < 1e-10);
        // Both below price for buys
        assert!(levels.trail_stop < 100.0);
        assert!(levels.safety_stop < 100.0);
        // Trail closer to price than safety
        assert!(levels.trail_stop > levels.safety_stop);
    }

    #[test]
    fn test_distances_to_levels_sell() {
        let d = Distances::new(0.05, 0.10);
        let levels = d.to_levels(100.0, Side::Sell);
        assert!((levels.trail_stop - 105.0).abs() < 1e-10);
        assert!((levels.safety_stop - 110.0).abs() < 1e-10);
        // Both above price for sells
        assert!(levels.trail_stop > 100.0);
        assert!(levels.safety_stop > 100.0);
        // Trail closer to price than safety
        assert!(levels.trail_stop < levels.safety_stop);
    }

    #[test]
    fn test_distances_to_levels_symmetry() {
        let d = Distances::new(0.03, 0.06);
        let price = 40000.0;
        let buy = d.to_levels(price, Side::Buy);
        let sell = d.to_levels(price, Side::Sell);
        // Symmetric around price
        assert!(((buy.trail_stop + sell.trail_stop) / 2.0 - price).abs() < 1e-10);
        assert!(((buy.safety_stop + sell.safety_stop) / 2.0 - price).abs() < 1e-10);
    }

    #[test]
    fn test_distances_copy() {
        let d = Distances::new(0.02, 0.05);
        let d2 = d; // Copy
        assert!((d.trail - d2.trail).abs() < 1e-10); // d still usable
    }
}
