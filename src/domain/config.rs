/// Configuration — domain knowledge for this enterprise.
/// Which observers exist. How to build them. The kernel refs these.
/// The lenses, seeds, and parameters live here, not in the binary.

use crate::domain::broker::Broker;
use crate::domain::regime_observer::RegimeObserver;
use crate::domain::market_observer::MarketObserver;
use crate::learning::window_sampler::WindowSampler;
use crate::types::enums::{RegimeLens, MarketLens};

/// The eleven market lenses. Three schools, one observer per lens.
/// Proposals 041+042: Dow (4), Pring (4), Wyckoff (3).
pub const MARKET_LENSES: &[MarketLens] = &[
    // Dow school
    MarketLens::DowTrend,
    MarketLens::DowVolume,
    MarketLens::DowCycle,
    MarketLens::DowGeneralist,
    // Pring school
    MarketLens::PringImpulse,
    MarketLens::PringConfirmation,
    MarketLens::PringRegime,
    MarketLens::PringGeneralist,
    // Wyckoff school
    MarketLens::WyckoffEffort,
    MarketLens::WyckoffPersistence,
    MarketLens::WyckoffPosition,
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

/// The two regime lenses. One regime observer per lens.
/// Regime observers are thought middleware — they build regime
/// rhythms and pass them downstream without learning or predicting.
pub const REGIME_LENSES: &[RegimeLens] = &[
    RegimeLens::Core,
    RegimeLens::Full,
];

/// Create all regime observers with their configured lenses.
pub fn create_regime_observers() -> Vec<RegimeObserver> {
    REGIME_LENSES
        .iter()
        .map(|lens| RegimeObserver::new(*lens))
        .collect()
}

/// Create N×M brokers. One per (market, exit) pair.
pub fn create_brokers(
    num_market: usize,
    num_exit: usize,
    dims: usize,
    recalib_interval: usize,
) -> Vec<Broker> {
    let mut brokers = Vec::with_capacity(num_market * num_exit);
    for mi in 0..num_market {
        for ei in 0..num_exit {
            let slot_idx = mi * num_exit + ei;
            let market_name = format!("{}", MARKET_LENSES[mi]);
            let exit_name = format!("{}", REGIME_LENSES[ei]);
            brokers.push(Broker::new(
                vec![market_name, exit_name],
                slot_idx,
                num_exit,
                dims,
                recalib_interval,
            ));
        }
    }
    brokers
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_market_lenses_count() {
        assert_eq!(MARKET_LENSES.len(), 11);
    }

    #[test]
    fn test_market_lenses_order() {
        assert_eq!(MARKET_LENSES[0], MarketLens::DowTrend);
        assert_eq!(MARKET_LENSES[1], MarketLens::DowVolume);
        assert_eq!(MARKET_LENSES[2], MarketLens::DowCycle);
        assert_eq!(MARKET_LENSES[3], MarketLens::DowGeneralist);
        assert_eq!(MARKET_LENSES[4], MarketLens::PringImpulse);
        assert_eq!(MARKET_LENSES[5], MarketLens::PringConfirmation);
        assert_eq!(MARKET_LENSES[6], MarketLens::PringRegime);
        assert_eq!(MARKET_LENSES[7], MarketLens::PringGeneralist);
        assert_eq!(MARKET_LENSES[8], MarketLens::WyckoffEffort);
        assert_eq!(MARKET_LENSES[9], MarketLens::WyckoffPersistence);
        assert_eq!(MARKET_LENSES[10], MarketLens::WyckoffPosition);
    }

    #[test]
    fn test_create_market_observers() {
        let observers = create_market_observers(4096, 500);
        assert_eq!(observers.len(), 11);
        assert_eq!(observers[0].lens, MarketLens::DowTrend);
        assert_eq!(observers[10].lens, MarketLens::WyckoffPosition);
    }

    #[test]
    fn test_observer_seeds_are_unique() {
        let observers = create_market_observers(4096, 500);
        for (i, obs) in observers.iter().enumerate() {
            let expected_seed = 7919 + i * 1000;
            assert_eq!(obs.window_sampler.seed, expected_seed);
        }
    }

    #[test]
    fn test_exit_lenses_count() {
        assert_eq!(REGIME_LENSES.len(), 2);
    }

    #[test]
    fn test_create_regime_observers() {
        let observers = create_regime_observers();
        assert_eq!(observers.len(), 2);
        assert_eq!(observers[0].lens, RegimeLens::Core);
        assert_eq!(observers[1].lens, RegimeLens::Full);
    }
}
