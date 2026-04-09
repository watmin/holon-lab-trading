//! enums.wat -- Side, Direction, Outcome, TradePhase, ReckConfig, Prediction,
//!              ScalarEncoding, MarketLens, ExitLens
//! Depends on: nothing

/// What the trader does. On Proposal and Trade.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Side {
    Buy,
    Sell,
}

/// What the price did. Used in propagation.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Direction {
    Up,
    Down,
}

/// Did this trade produce value or destroy it?
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Outcome {
    Grace,
    Violence,
}

/// The state machine of a position's lifecycle.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum TradePhase {
    Active,
    Runner,
    SettledViolence,
    SettledGrace,
}

/// Reckoner config -- readout mode only.
/// dims and recalib-interval are separate parameters to the constructor.
#[derive(Clone, Debug, PartialEq)]
pub enum ReckonerConfig {
    /// Discrete classification. labels: e.g. vec!["Up", "Down"]
    Discrete { labels: Vec<String> },
    /// Continuous regression. default_value: the crutch, returned when ignorant.
    Continuous { default_value: f64 },
}

/// What a reckoner returns. Data, not action. The consumer decides.
#[derive(Clone, Debug)]
pub enum PredictionResult {
    /// Discrete readout.
    /// scores: (label name, cosine) per label.
    /// conviction: how strongly the reckoner leans.
    Discrete {
        scores: Vec<(String, f64)>,
        conviction: f64,
    },
    /// Continuous readout.
    /// value: the reckoned scalar.
    /// experience: how much the reckoner knows (0.0 = ignorant).
    Continuous {
        value: f64,
        experience: f64,
    },
}

/// How a scalar accumulator encodes values.
#[derive(Clone, Debug, PartialEq)]
pub enum ScalarEncoding {
    /// Log compresses naturally -- no params.
    Log,
    /// encode-linear with scale.
    Linear { scale: f64 },
    /// encode-circular with period.
    Circular { period: f64 },
}

/// Which vocabulary subset a market observer thinks through.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum MarketLens {
    Momentum,
    Structure,
    Volume,
    Narrative,
    Regime,
    Generalist,
}

/// Which vocabulary subset an exit observer thinks through.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum ExitLens {
    Volatility,
    Structure,
    Timing,
    Generalist,
}
