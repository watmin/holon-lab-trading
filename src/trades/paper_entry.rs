/// paper_entry.rs — Hypothetical trade inside a broker. A "what if."
/// Compiled from wat/paper-entry.wat.
///
/// One prediction (Up or Down). Two triggers: trail (Grace) and stop (Violence).
/// The paper measures whether the market observer's prediction was correct.

use holon::kernel::vector::Vector;

use crate::types::distances::Distances;
use crate::types::enums::Direction;
use crate::types::newtypes::Price;

/// A hypothetical paper trade tracking one predicted direction.
pub struct PaperEntry {
    /// Unique identifier assigned by the broker.
    pub paper_id: usize,
    /// The composed thought at entry (market + position).
    pub composed_thought: Vector,
    /// The raw market thought (for market observer learning).
    pub market_thought: Vector,
    /// The position observer's own encoded facts (for position observer learning).
    /// Proposal 026: position learns from position_thought, not composed.
    pub position_thought: Vector,
    /// What the market observer predicted.
    pub prediction: Direction,
    /// Price when the paper was created.
    pub entry_price: Price,
    /// Distances from the position observer at entry.
    pub distances: Distances,
    /// Best price in predicted direction so far.
    pub extreme: f64,
    /// Trailing stop level (follows extreme with trail_distance gap).
    pub trail_level: Price,
    /// Fixed stop loss (capital protection).
    pub stop_level: Price,
    /// Has the trail crossed (Grace signal sent)?
    pub signaled: bool,
    /// Has a trigger fired (paper done)?
    pub resolved: bool,
    /// How many candles this paper has lived.
    pub age: usize,
    /// Candle number at which this paper was created (for phase biography).
    pub entry_candle: usize,
    /// Price history — every tick's price. For simulation at resolution.
    pub price_history: Vec<f64>,
}

impl PaperEntry {
    /// Create a new paper entry. Entry price is close.
    /// For Up: trail_level starts at entry, extreme starts at entry,
    ///         stop_level = entry - entry * stop_distance.
    /// For Down: inverse.
    pub fn new(
        paper_id: usize,
        composed_thought: Vector,
        market_thought: Vector,
        position_thought: Vector,
        prediction: Direction,
        entry_price: Price,
        distances: Distances,
        entry_candle: usize,
    ) -> Self {
        let p = entry_price.0;
        let (stop_level, trail_level) = match prediction {
            Direction::Up => (Price(p - p * distances.stop), Price(p)),
            Direction::Down => (Price(p + p * distances.stop), Price(p)),
        };
        Self {
            paper_id,
            composed_thought,
            market_thought,
            position_thought,
            prediction,
            entry_price,
            distances,
            extreme: p,
            trail_level,
            stop_level,
            signaled: false,
            resolved: false,
            age: 0,
            entry_candle,
            price_history: vec![p],
        }
    }

    /// Tick the paper against the current price.
    /// Updates extreme, trail_level, checks triggers.
    pub fn tick(&mut self, current_price: f64) {
        if self.resolved {
            return;
        }
        self.age += 1;
        self.price_history.push(current_price);
        let p = self.entry_price.0;

        match self.prediction {
            Direction::Up => {
                // Track best price in predicted (up) direction
                if current_price > self.extreme {
                    self.extreme = current_price;
                }
                // Trail follows extreme with trail_distance gap
                let new_trail = Price(self.extreme - self.extreme * self.distances.trail);
                if new_trail > self.trail_level {
                    self.trail_level = new_trail;
                }
                // Check stop (Violence): price fell below stop_level
                if current_price <= self.stop_level.0 {
                    self.resolved = true;
                    return;
                }
                // Check Grace: extreme crossed entry + entry * trail_distance
                if self.extreme >= p + p * self.distances.trail {
                    self.signaled = true;
                }
                // If signaled: check trail fire (runner finished)
                if self.signaled && current_price <= self.trail_level.0 {
                    self.resolved = true;
                }
            }
            Direction::Down => {
                // Track best price in predicted (down) direction
                if current_price < self.extreme {
                    self.extreme = current_price;
                }
                // Trail follows extreme with trail_distance gap (upward)
                let new_trail = Price(self.extreme + self.extreme * self.distances.trail);
                if new_trail < self.trail_level {
                    self.trail_level = new_trail;
                }
                // Check stop (Violence): price rose above stop_level
                if current_price >= self.stop_level.0 {
                    self.resolved = true;
                    return;
                }
                // Check Grace: extreme crossed entry - entry * trail_distance
                if self.extreme <= p - p * self.distances.trail {
                    self.signaled = true;
                }
                // If signaled: check trail fire (runner finished)
                if self.signaled && current_price >= self.trail_level.0 {
                    self.resolved = true;
                }
            }
        }
    }

    /// Grace: the market confirmed the prediction (trail crossed before resolution).
    pub fn is_grace(&self) -> bool {
        self.signaled
    }

    /// Violence: resolved without ever being signaled (stop fired before trail crossed).
    pub fn is_violence(&self) -> bool {
        self.resolved && !self.signaled
    }

    /// Runner: trail crossed, still running (not yet resolved).
    pub fn is_runner(&self) -> bool {
        self.signaled && !self.resolved
    }

    /// How far price moved in predicted direction as fraction of entry.
    pub fn excursion(&self) -> f64 {
        let p = self.entry_price.0;
        match self.prediction {
            Direction::Up => (self.extreme - p) / p,
            Direction::Down => (p - self.extreme) / p,
        }
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

    fn make_market_thought() -> Vector {
        let vm = VectorManager::new(DIMS);
        vm.get_vector("market_thought")
    }

    fn make_position_thought() -> Vector {
        let vm = VectorManager::new(DIMS);
        vm.get_vector("position_thought")
    }

    #[test]
    fn test_paper_entry_new_up() {
        let thought = make_thought();
        let mt = make_market_thought();
        let distances = Distances::new(0.05, 0.10);
        let paper = PaperEntry::new(0, thought, mt, make_position_thought(), Direction::Up, Price(100.0), distances, 0);

        assert!((paper.entry_price.0 - 100.0).abs() < 1e-10);
        assert!((paper.extreme - 100.0).abs() < 1e-10);
        // Stop below entry for Up prediction
        assert!((paper.stop_level.0 - 90.0).abs() < 1e-10);
        // Trail starts at entry
        assert!((paper.trail_level.0 - 100.0).abs() < 1e-10);
        assert!(!paper.signaled);
        assert!(!paper.resolved);
        assert_eq!(paper.prediction, Direction::Up);
    }

    #[test]
    fn test_paper_entry_new_down() {
        let thought = make_thought();
        let mt = make_market_thought();
        let distances = Distances::new(0.05, 0.10);
        let paper = PaperEntry::new(0, thought, mt, make_position_thought(), Direction::Down, Price(100.0), distances, 0);

        // Stop above entry for Down prediction
        assert!((paper.stop_level.0 - 110.0).abs() < 1e-10);
        // Trail starts at entry
        assert!((paper.trail_level.0 - 100.0).abs() < 1e-10);
        assert_eq!(paper.prediction, Direction::Down);
    }

    #[test]
    fn test_tick_up_grace_signal() {
        let thought = make_thought();
        let mt = make_market_thought();
        let distances = Distances::new(0.05, 0.10);
        let mut paper = PaperEntry::new(0, thought, mt, make_position_thought(), Direction::Up, Price(100.0), distances, 0);

        // Price rises above entry + entry * trail_distance = 105
        paper.tick(106.0);
        assert!(paper.signaled); // Grace: market confirmed
        assert!(!paper.resolved); // Still running
        assert!(paper.is_runner());
        assert!((paper.extreme - 106.0).abs() < 1e-10);
    }

    #[test]
    fn test_tick_up_violence() {
        let thought = make_thought();
        let mt = make_market_thought();
        let distances = Distances::new(0.05, 0.10);
        let mut paper = PaperEntry::new(0, thought, mt, make_position_thought(), Direction::Up, Price(100.0), distances, 0);

        // Price drops to stop_level (90)
        paper.tick(89.0);
        assert!(paper.resolved);
        assert!(!paper.signaled);
        assert!(paper.is_violence());
    }

    #[test]
    fn test_tick_up_runner_then_resolved() {
        let thought = make_thought();
        let mt = make_market_thought();
        let distances = Distances::new(0.05, 0.10);
        let mut paper = PaperEntry::new(0, thought, mt, make_position_thought(), Direction::Up, Price(100.0), distances, 0);

        // Price rises to 110 → extreme=110, trail_level = 110 - 110*0.05 = 104.5
        paper.tick(110.0);
        assert!(paper.signaled); // 110 >= 105 (entry + entry*trail)
        assert!(!paper.resolved);

        // Price drops to 104 → below trail_level 104.5
        paper.tick(104.0);
        assert!(paper.resolved);
        assert!(paper.signaled);
        // Not violence — was signaled before resolution
        assert!(!paper.is_violence());
    }

    #[test]
    fn test_tick_down_grace_signal() {
        let thought = make_thought();
        let mt = make_market_thought();
        let distances = Distances::new(0.05, 0.10);
        let mut paper = PaperEntry::new(0, thought, mt, make_position_thought(), Direction::Down, Price(100.0), distances, 0);

        // Price drops below entry - entry * trail_distance = 95
        paper.tick(94.0);
        assert!(paper.signaled);
        assert!(!paper.resolved);
        assert!(paper.is_runner());
    }

    #[test]
    fn test_tick_down_violence() {
        let thought = make_thought();
        let mt = make_market_thought();
        let distances = Distances::new(0.05, 0.10);
        let mut paper = PaperEntry::new(0, thought, mt, make_position_thought(), Direction::Down, Price(100.0), distances, 0);

        // Price rises to stop_level (110)
        paper.tick(111.0);
        assert!(paper.resolved);
        assert!(!paper.signaled);
        assert!(paper.is_violence());
    }

    #[test]
    fn test_tick_down_runner_then_resolved() {
        let thought = make_thought();
        let mt = make_market_thought();
        let distances = Distances::new(0.05, 0.10);
        let mut paper = PaperEntry::new(0, thought, mt, make_position_thought(), Direction::Down, Price(100.0), distances, 0);

        // Price drops to 90 → extreme=90, trail_level = 90 + 90*0.05 = 94.5
        paper.tick(90.0);
        assert!(paper.signaled); // 90 <= 95 (entry - entry*trail)
        assert!(!paper.resolved);

        // Price rises to 95 → above trail_level 94.5
        paper.tick(95.0);
        assert!(paper.resolved);
        assert!(paper.signaled);
    }

    #[test]
    fn test_excursion_up() {
        let thought = make_thought();
        let mt = make_market_thought();
        let distances = Distances::new(0.20, 0.30);
        let mut paper = PaperEntry::new(0, thought, mt, make_position_thought(), Direction::Up, Price(100.0), distances, 0);

        paper.tick(110.0);
        assert!((paper.excursion() - 0.10).abs() < 1e-10);
    }

    #[test]
    fn test_excursion_down() {
        let thought = make_thought();
        let mt = make_market_thought();
        let distances = Distances::new(0.20, 0.30);
        let mut paper = PaperEntry::new(0, thought, mt, make_position_thought(), Direction::Down, Price(100.0), distances, 0);

        paper.tick(90.0);
        assert!((paper.excursion() - 0.10).abs() < 1e-10);
    }

    #[test]
    fn test_resolved_stops_tracking() {
        let thought = make_thought();
        let mt = make_market_thought();
        let distances = Distances::new(0.05, 0.10);
        let mut paper = PaperEntry::new(0, thought, mt, make_position_thought(), Direction::Up, Price(100.0), distances, 0);

        // Violence
        paper.tick(89.0);
        assert!(paper.resolved);

        let extreme_after = paper.extreme;
        // Further ticks should not update
        paper.tick(120.0);
        assert!((paper.extreme - extreme_after).abs() < 1e-10);
    }

    #[test]
    fn test_initial_excursion_zero() {
        let thought = make_thought();
        let mt = make_market_thought();
        let distances = Distances::new(0.05, 0.10);
        let paper = PaperEntry::new(0, thought, mt, make_position_thought(), Direction::Up, Price(100.0), distances, 0);
        assert!((paper.excursion() - 0.0).abs() < 1e-10);
    }
}
