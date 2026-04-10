/// paper_entry.rs — Hypothetical trade inside a broker. A "what if."
/// Compiled from wat/paper-entry.wat.
///
/// Both sides (buy and sell) are tracked simultaneously. When both sides
/// resolve (their trailing stops fire), the paper teaches the system:
/// what distance would have been optimal?

use holon::kernel::vector::Vector;

use crate::distances::Distances;

/// A hypothetical paper trade tracking both buy and sell sides.
pub struct PaperEntry {
    /// The thought at entry.
    pub composed_thought: Vector,
    /// Price when the paper was created.
    pub entry_price: f64,
    /// Distances from the exit observer at entry.
    pub distances: Distances,
    /// Best price in buy direction so far.
    pub buy_extreme: f64,
    /// Trailing stop level for buy side (from distances.trail).
    pub buy_trail_stop: f64,
    /// Best price in sell direction so far.
    pub sell_extreme: f64,
    /// Trailing stop level for sell side (from distances.trail).
    pub sell_trail_stop: f64,
    /// Buy side's stop has fired.
    pub buy_resolved: bool,
    /// Sell side's stop has fired.
    pub sell_resolved: bool,
}

impl PaperEntry {
    /// Create a new paper entry. Both sides start unresolved.
    /// Buy trail stop is below price, sell trail stop is above.
    pub fn new(composed_thought: Vector, entry_price: f64, distances: Distances) -> Self {
        let trail_dist = entry_price * distances.trail;
        Self {
            composed_thought,
            entry_price,
            distances,
            buy_extreme: entry_price,
            buy_trail_stop: entry_price - trail_dist,
            sell_extreme: entry_price,
            sell_trail_stop: entry_price + trail_dist,
            buy_resolved: false,
            sell_resolved: false,
        }
    }

    /// Tick the paper against the current price. Update extremes,
    /// check trailing stops, mark sides as resolved when stops fire.
    pub fn tick(&mut self, current_price: f64) {
        // Buy side: track highest price, trail stop follows up
        if !self.buy_resolved {
            if current_price > self.buy_extreme {
                self.buy_extreme = current_price;
            }
            let new_trail = self.buy_extreme - self.buy_extreme * self.distances.trail;
            if new_trail > self.buy_trail_stop {
                self.buy_trail_stop = new_trail;
            }
            if current_price <= self.buy_trail_stop {
                self.buy_resolved = true;
            }
        }

        // Sell side: track lowest price, trail stop follows down
        if !self.sell_resolved {
            if current_price < self.sell_extreme {
                self.sell_extreme = current_price;
            }
            let new_trail = self.sell_extreme + self.sell_extreme * self.distances.trail;
            if new_trail < self.sell_trail_stop {
                self.sell_trail_stop = new_trail;
            }
            if current_price >= self.sell_trail_stop {
                self.sell_resolved = true;
            }
        }
    }

    /// True if both sides have resolved (both trailing stops fired).
    pub fn fully_resolved(&self) -> bool {
        self.buy_resolved && self.sell_resolved
    }

    /// Buy side excursion as fraction of entry price.
    pub fn buy_excursion(&self) -> f64 {
        (self.buy_extreme - self.entry_price) / self.entry_price
    }

    /// Sell side excursion as fraction of entry price.
    pub fn sell_excursion(&self) -> f64 {
        (self.entry_price - self.sell_extreme) / self.entry_price
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use holon::kernel::vector_manager::VectorManager;

    const DIMS: usize = 4096;

    fn make_thought() -> Vector {
        let vm = VectorManager::new(DIMS);
        vm.get_vector("test_thought")
    }

    #[test]
    fn test_paper_entry_new() {
        let thought = make_thought();
        let distances = Distances::new(0.05, 0.10);
        let paper = PaperEntry::new(thought, 100.0, distances);

        assert!((paper.entry_price - 100.0).abs() < 1e-10);
        assert!((paper.buy_extreme - 100.0).abs() < 1e-10);
        assert!((paper.sell_extreme - 100.0).abs() < 1e-10);
        // Buy trail stop below price
        assert!((paper.buy_trail_stop - 95.0).abs() < 1e-10);
        // Sell trail stop above price
        assert!((paper.sell_trail_stop - 105.0).abs() < 1e-10);
        assert!(!paper.buy_resolved);
        assert!(!paper.sell_resolved);
    }

    #[test]
    fn test_tick_rising_prices_updates_buy_extreme() {
        let thought = make_thought();
        let distances = Distances::new(0.05, 0.10);
        let mut paper = PaperEntry::new(thought, 100.0, distances);

        paper.tick(110.0);
        assert!((paper.buy_extreme - 110.0).abs() < 1e-10);
        // Trail stop should ratchet up: 110 - 110*0.05 = 104.5
        assert!((paper.buy_trail_stop - 104.5).abs() < 1e-10);
        assert!(!paper.buy_resolved);
    }

    #[test]
    fn test_tick_buy_stop_fires() {
        let thought = make_thought();
        let distances = Distances::new(0.05, 0.10);
        let mut paper = PaperEntry::new(thought, 100.0, distances);

        // Price rises to 110, trail stop at 104.5
        paper.tick(110.0);
        // Price drops to 104 -- below 104.5
        paper.tick(104.0);
        assert!(paper.buy_resolved);
    }

    #[test]
    fn test_tick_sell_stop_fires() {
        let thought = make_thought();
        let distances = Distances::new(0.05, 0.10);
        let mut paper = PaperEntry::new(thought, 100.0, distances);

        // Price drops to 90, sell trail stop ratchets: 90 + 90*0.05 = 94.5
        paper.tick(90.0);
        assert!((paper.sell_extreme - 90.0).abs() < 1e-10);
        // Price rises to 95 -- above 94.5
        paper.tick(95.0);
        assert!(paper.sell_resolved);
    }

    #[test]
    fn test_fully_resolved() {
        let thought = make_thought();
        // Trail=0.20: buy_trail_stop=80, sell_trail_stop=120
        let distances = Distances::new(0.20, 0.30);
        let mut paper = PaperEntry::new(thought, 100.0, distances);

        assert!(!paper.fully_resolved());

        // Step 1: Trigger sell side first by rising above sell_trail_stop=120
        paper.tick(125.0);
        // buy_extreme=125, buy_trail_stop=max(80, 125-25)=100
        // sell fires because 125 >= 120
        assert!(paper.sell_resolved);
        assert!(!paper.buy_resolved);
        assert!(!paper.fully_resolved());

        // Step 2: Trigger buy side by falling below buy_trail_stop=100
        paper.tick(99.0);
        assert!(paper.buy_resolved);
        assert!(paper.fully_resolved());
    }

    #[test]
    fn test_excursions() {
        let thought = make_thought();
        // Use large trail so tick doesn't resolve sides immediately
        let distances = Distances::new(0.20, 0.30);
        let mut paper = PaperEntry::new(thought, 100.0, distances);

        paper.tick(110.0); // buy extreme = 110, sell trail at 100+20=120 > 110, no fire
        paper.tick(90.0);  // sell extreme = 90, buy trail at max(80, 110-22)=88 < 90, no fire

        assert!((paper.buy_excursion() - 0.10).abs() < 1e-10);
        assert!((paper.sell_excursion() - 0.10).abs() < 1e-10);
    }

    #[test]
    fn test_resolved_side_stops_tracking() {
        let thought = make_thought();
        let distances = Distances::new(0.05, 0.10);
        let mut paper = PaperEntry::new(thought, 100.0, distances);

        // Trigger buy side
        paper.tick(110.0);
        paper.tick(104.0);
        assert!(paper.buy_resolved);

        let buy_extreme_after = paper.buy_extreme;
        // Further price movement should not update buy extreme
        paper.tick(120.0);
        assert!((paper.buy_extreme - buy_extreme_after).abs() < 1e-10);
    }

    #[test]
    fn test_initial_excursions_zero() {
        let thought = make_thought();
        let distances = Distances::new(0.05, 0.10);
        let paper = PaperEntry::new(thought, 100.0, distances);
        assert!((paper.buy_excursion() - 0.0).abs() < 1e-10);
        assert!((paper.sell_excursion() - 0.0).abs() < 1e-10);
    }
}
