/// Configuration — domain knowledge for this enterprise.
/// Which observers exist. How to build them. The kernel refs these.
/// The lenses, seeds, and parameters live here, not in the binary.

use crate::domain::market_observer::MarketObserver;
use crate::learning::window_sampler::WindowSampler;
use crate::types::enums::MarketLens;

/// The six market lenses. One observer per lens.
pub const MARKET_LENSES: &[MarketLens] = &[
    MarketLens::Momentum,
    MarketLens::Structure,
    MarketLens::Volume,
    MarketLens::Narrative,
    MarketLens::Regime,
    MarketLens::Generalist,
];

/// Create all market observers with their configured lenses and window samplers.
/// Each observer gets a unique seed for its window sampler.
pub fn create_market_observers(dims: usize, recalib_interval: usize) -> Vec<MarketObserver> {
    MARKET_LENSES
        .iter()
        .enumerate()
        .map(|(i, lens)| {
            let seed = 7919 + i * 1000;
            MarketObserver::new(
                *lens,
                dims,
                recalib_interval,
                WindowSampler::new(seed, 12, 2016),
            )
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_market_lenses_count() {
        assert_eq!(MARKET_LENSES.len(), 6);
    }

    #[test]
    fn test_market_lenses_order() {
        assert_eq!(MARKET_LENSES[0], MarketLens::Momentum);
        assert_eq!(MARKET_LENSES[1], MarketLens::Structure);
        assert_eq!(MARKET_LENSES[2], MarketLens::Volume);
        assert_eq!(MARKET_LENSES[3], MarketLens::Narrative);
        assert_eq!(MARKET_LENSES[4], MarketLens::Regime);
        assert_eq!(MARKET_LENSES[5], MarketLens::Generalist);
    }

    #[test]
    fn test_create_market_observers() {
        let observers = create_market_observers(4096, 500);
        assert_eq!(observers.len(), 6);
        assert_eq!(observers[0].lens, MarketLens::Momentum);
        assert_eq!(observers[5].lens, MarketLens::Generalist);
    }

    #[test]
    fn test_observer_seeds_are_unique() {
        let observers = create_market_observers(4096, 500);
        for (i, obs) in observers.iter().enumerate() {
            let expected_seed = 7919 + i * 1000;
            assert_eq!(obs.window_sampler.seed, expected_seed);
        }
    }
}
