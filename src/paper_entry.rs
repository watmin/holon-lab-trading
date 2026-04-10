/// PaperEntry — a paper trade tracking both sides simultaneously.

use holon::kernel::vector::Vector;

use crate::distances::Distances;

/// Both-side paper trade. Buy and sell tracked simultaneously.
#[derive(Clone, Debug)]
pub struct PaperEntry {
    pub composed_thought: Vector,
    pub entry_price: f64,
    pub distances: Distances,
    pub buy_extreme: f64,
    pub buy_trail_stop: f64,
    pub sell_extreme: f64,
    pub sell_trail_stop: f64,
    pub buy_resolved: bool,
    pub sell_resolved: bool,
}

impl PaperEntry {
    pub fn new(composed_thought: Vector, entry_price: f64, distances: Distances) -> Self {
        let trail = distances.trail;
        Self {
            composed_thought,
            entry_price,
            distances,
            buy_extreme: entry_price,
            buy_trail_stop: entry_price * (1.0 - trail),
            sell_extreme: entry_price,
            sell_trail_stop: entry_price * (1.0 + trail),
            buy_resolved: false,
            sell_resolved: false,
        }
    }

    /// Tick at the current price. Updates extremes and trailing stops.
    pub fn tick(&mut self, current_price: f64) {
        let trail = self.distances.trail;

        // Buy side: price going up is good
        if !self.buy_resolved {
            self.buy_extreme = self.buy_extreme.max(current_price);
            self.buy_trail_stop = self.buy_trail_stop.max(self.buy_extreme * (1.0 - trail));
            if current_price <= self.buy_trail_stop {
                self.buy_resolved = true;
            }
        }

        // Sell side: price going down is good
        if !self.sell_resolved {
            self.sell_extreme = self.sell_extreme.min(current_price);
            self.sell_trail_stop = self.sell_trail_stop.min(self.sell_extreme * (1.0 + trail));
            if current_price >= self.sell_trail_stop {
                self.sell_resolved = true;
            }
        }
    }

    /// Is this paper fully resolved (both sides done)?
    pub fn is_resolved(&self) -> bool {
        self.buy_resolved && self.sell_resolved
    }

    /// Buy side PnL as fraction of entry price.
    pub fn buy_pnl(&self) -> f64 {
        (self.buy_trail_stop - self.entry_price) / self.entry_price
    }

    /// Sell side PnL as fraction of entry price.
    pub fn sell_pnl(&self) -> f64 {
        (self.entry_price - self.sell_trail_stop) / self.entry_price
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_paper() -> PaperEntry {
        PaperEntry::new(
            Vector::zeros(4096),
            100.0,
            Distances::new(0.02, 0.03, 0.05, 0.025),
        )
    }

    #[test]
    fn test_paper_entry_construct() {
        let p = make_paper();
        assert_eq!(p.entry_price, 100.0);
        assert!(!p.buy_resolved);
        assert!(!p.sell_resolved);
        assert!(!p.is_resolved());
        // Buy trail stop: 100 * (1 - 0.02) = 98.0
        assert!((p.buy_trail_stop - 98.0).abs() < 1e-10);
        // Sell trail stop: 100 * (1 + 0.02) = 102.0
        assert!((p.sell_trail_stop - 102.0).abs() < 1e-10);
    }

    #[test]
    fn test_tick_advances_extremes() {
        let mut p = make_paper();
        // Price goes up — buy extreme rises
        p.tick(105.0);
        assert_eq!(p.buy_extreme, 105.0);
        assert!(p.buy_trail_stop > 98.0); // trail ratcheted up
        // Sell extreme unchanged (min)
        assert_eq!(p.sell_extreme, 100.0);
    }

    #[test]
    fn test_resolution_detection() {
        let mut p = make_paper();
        // Move price down to trigger buy side stop
        p.tick(95.0);
        assert!(p.buy_resolved);
        // Move price up to trigger sell side stop
        p.tick(110.0);
        assert!(p.sell_resolved);
        assert!(p.is_resolved());
    }
}
