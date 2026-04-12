//! Domain structs. The state that programs own.
//! MarketObserver, ExitObserver, Broker.
//! Not the programs — the state the programs carry.

pub mod market_observer;
pub mod exit_observer;
pub mod broker;
#[cfg(feature = "parquet")]
pub mod candle_stream;
pub mod indicator_bank;
pub mod simulation;
