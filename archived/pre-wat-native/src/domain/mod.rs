//! Domain structs. The state that programs own.
//! MarketObserver, RegimeObserver, Broker.
//! Not the programs — the state the programs carry.

pub mod config;
pub mod market_observer;
pub mod regime_observer;
pub mod broker;
#[cfg(feature = "parquet")]
pub mod candle_stream;
pub mod indicator_bank;
pub mod simulation;
pub mod ledger;
pub mod lens;
pub mod treasury;
