/// Configuration — domain knowledge for this enterprise.
/// Which observers exist. How to build them. The kernel refs these.
/// The lenses, seeds, and parameters live here, not in the binary.

use crate::domain::broker::Broker;
use crate::domain::exit_observer::ExitObserver;
use crate::domain::market_observer::MarketObserver;
use crate::learning::scalar_accumulator::ScalarAccumulator;
use crate::learning::window_sampler::WindowSampler;
use crate::types::distances::Distances;
use crate::types::enums::{ExitLens, MarketLens, ScalarEncoding};

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

/// The two exit lenses. One exit observer per lens.
/// Proposal 040: trade-state atoms, not market data.
pub const EXIT_LENSES: &[ExitLens] = &[
    ExitLens::Core,
    ExitLens::Full,
];

/// Create all exit observers with their configured lenses.
pub fn create_exit_observers(dims: usize, recalib_interval: usize) -> Vec<ExitObserver> {
    EXIT_LENSES
        .iter()
        .map(|lens| {
            ExitObserver::new(
                *lens,
                dims,
                recalib_interval,
                0.0001, // near-zero default trail — the market teaches
                0.0001, // near-zero default stop — the market teaches
            )
        })
        .collect()
}

/// Create N×M brokers. One per (market, exit) pair.
pub fn create_brokers(
    num_market: usize,
    num_exit: usize,
    dims: usize,
    swap_fee: f64,
) -> Vec<Broker> {
    let mut brokers = Vec::with_capacity(num_market * num_exit);
    for mi in 0..num_market {
        for ei in 0..num_exit {
            let slot_idx = mi * num_exit + ei;
            let market_name = format!("{}", MARKET_LENSES[mi]);
            let exit_name = format!("{}", EXIT_LENSES[ei]);
            let scalar_accums = vec![
                ScalarAccumulator::new("trail-distance", ScalarEncoding::Log, dims),
                ScalarAccumulator::new("stop-distance", ScalarEncoding::Log, dims),
            ];
            brokers.push(Broker::new(
                vec![market_name, exit_name],
                slot_idx,
                num_exit,
                scalar_accums,
                Distances::new(0.0001, 0.0001),
                swap_fee,
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
        assert_eq!(EXIT_LENSES.len(), 2);
    }

    #[test]
    fn test_create_exit_observers() {
        let observers = create_exit_observers(4096, 500);
        assert_eq!(observers.len(), 2);
        assert_eq!(observers[0].lens, ExitLens::Core);
        assert_eq!(observers[1].lens, ExitLens::Full);
    }

    #[test]
    fn test_exit_observers_start_inexperienced() {
        let observers = create_exit_observers(4096, 500);
        for obs in &observers {
            assert!(!obs.experienced());
        }
    }
}
