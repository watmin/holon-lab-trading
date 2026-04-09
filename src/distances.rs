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
