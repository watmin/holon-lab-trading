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

/// The four exit lenses. One exit observer per lens.
pub const EXIT_LENSES: &[ExitLens] = &[
    ExitLens::Volatility,
    ExitLens::Timing,
    ExitLens::Structure,
    ExitLens::Generalist,
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

    #[test]
    fn test_exit_lenses_count() {
        assert_eq!(EXIT_LENSES.len(), 4);
    }

    #[test]
    fn test_create_exit_observers() {
        let observers = create_exit_observers(4096, 500);
        assert_eq!(observers.len(), 4);
        assert_eq!(observers[0].lens, ExitLens::Volatility);
        assert_eq!(observers[1].lens, ExitLens::Timing);
        assert_eq!(observers[2].lens, ExitLens::Structure);
        assert_eq!(observers[3].lens, ExitLens::Generalist);
    }

    #[test]
    fn test_exit_observers_start_inexperienced() {
        let observers = create_exit_observers(4096, 500);
        for obs in &observers {
            assert!(!obs.experienced());
        }
    }
}
