/// Sum types for the enterprise. Compiled from wat/enums.wat.

/// Trading action — on Proposal and Trade.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Side {
    Buy,
    Sell,
}

/// Price movement — used in propagation.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Direction {
    Up,
    Down,
}

/// Accountability — used everywhere.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Outcome {
    Grace,
    Violence,
}

/// Position lifecycle.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TradePhase {
    Active,
    Runner,
    SettledViolence,
    SettledGrace,
}

/// What a reckoner returns. The consumer decides what "best" means.
#[derive(Clone, Debug)]
pub enum Prediction {
    /// Discrete classification with per-label scores and conviction.
    Discrete {
        scores: Vec<(String, f64)>,
        conviction: f64,
    },
    /// Continuous regression with a value and experience level.
    Continuous {
        value: f64,
        experience: f64,
    },
}

/// Scalar encoding — determines how continuous values are encoded into vectors.
/// Used by ScalarAccumulator.
#[derive(Clone, Copy, Debug)]
pub enum ScalarEncoding {
    Log,
    Linear { scale: f64 },
    Circular { period: f64 },
}

/// Market observer lens — which vocabulary modules an observer attends to.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum MarketLens {
    Momentum,
    Structure,
    Volume,
    Regime,
    Narrative,
    Generalist,
}

impl std::fmt::Display for MarketLens {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            MarketLens::Momentum => write!(f, "momentum"),
            MarketLens::Structure => write!(f, "structure"),
            MarketLens::Volume => write!(f, "volume"),
            MarketLens::Regime => write!(f, "regime"),
            MarketLens::Narrative => write!(f, "narrative"),
            MarketLens::Generalist => write!(f, "generalist"),
        }
    }
}

/// Exit observer lens — which trade-state vocabulary an exit observer uses.
/// Proposal 040: two lenses based on trade atoms, not market data.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum ExitLens {
    /// 5 trade atoms — the consensus (excursion, retracement, age, peak-age, signaled).
    Core,
    /// 10 trade atoms — all three voices (core + trail/stop distance, r-multiple, heat, trail-cushion).
    Full,
}

impl std::fmt::Display for ExitLens {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ExitLens::Core => write!(f, "core"),
            ExitLens::Full => write!(f, "full"),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_side_equality() {
        assert_eq!(Side::Buy, Side::Buy);
        assert_ne!(Side::Buy, Side::Sell);
    }

    #[test]
    fn test_direction_equality() {
        assert_eq!(Direction::Up, Direction::Up);
        assert_ne!(Direction::Up, Direction::Down);
    }

    #[test]
    fn test_outcome_equality() {
        assert_eq!(Outcome::Grace, Outcome::Grace);
        assert_ne!(Outcome::Grace, Outcome::Violence);
    }

    #[test]
    fn test_trade_phase_equality() {
        assert_eq!(TradePhase::Active, TradePhase::Active);
        assert_ne!(TradePhase::Active, TradePhase::Runner);
        assert_ne!(TradePhase::SettledViolence, TradePhase::SettledGrace);
    }

    #[test]
    fn test_prediction_discrete() {
        let pred = Prediction::Discrete {
            scores: vec![
                ("Up".to_string(), 0.85),
                ("Down".to_string(), 0.15),
            ],
            conviction: 0.70,
        };
        if let Prediction::Discrete { scores, conviction } = &pred {
            assert_eq!(scores.len(), 2);
            assert_eq!(scores[0].0, "Up");
            assert!((scores[0].1 - 0.85).abs() < 1e-10);
            assert!((conviction - 0.70).abs() < 1e-10);
        } else {
            panic!("Expected Discrete");
        }
    }

    #[test]
    fn test_prediction_continuous() {
        let pred = Prediction::Continuous {
            value: 0.03,
            experience: 0.8,
        };
        if let Prediction::Continuous { value, experience } = &pred {
            assert!((value - 0.03).abs() < 1e-10);
            assert!((experience - 0.8).abs() < 1e-10);
        } else {
            panic!("Expected Continuous");
        }
    }

    #[test]
    fn test_scalar_encoding_variants() {
        assert!(matches!(ScalarEncoding::Log, ScalarEncoding::Log));

        if let ScalarEncoding::Linear { scale } = (ScalarEncoding::Linear { scale: 100.0 }) {
            assert!((scale - 100.0).abs() < 1e-10);
        } else {
            panic!("Expected Linear");
        }

        if let ScalarEncoding::Circular { period } = (ScalarEncoding::Circular { period: 360.0 }) {
            assert!((period - 360.0).abs() < 1e-10);
        } else {
            panic!("Expected Circular");
        }
    }

    #[test]
    fn test_side_copy() {
        let s = Side::Buy;
        let s2 = s;
        assert_eq!(s, s2); // s still usable — Copy
    }

    #[test]
    fn test_market_lens_display() {
        assert_eq!(MarketLens::Momentum.to_string(), "momentum");
        assert_eq!(MarketLens::Structure.to_string(), "structure");
        assert_eq!(MarketLens::Volume.to_string(), "volume");
        assert_eq!(MarketLens::Regime.to_string(), "regime");
        assert_eq!(MarketLens::Narrative.to_string(), "narrative");
        assert_eq!(MarketLens::Generalist.to_string(), "generalist");
    }

    #[test]
    fn test_market_lens_equality() {
        assert_eq!(MarketLens::Momentum, MarketLens::Momentum);
        assert_ne!(MarketLens::Momentum, MarketLens::Structure);
    }

    #[test]
    fn test_exit_lens_display() {
        assert_eq!(ExitLens::Core.to_string(), "core");
        assert_eq!(ExitLens::Full.to_string(), "full");
    }

    #[test]
    fn test_exit_lens_equality() {
        assert_eq!(ExitLens::Core, ExitLens::Core);
        assert_ne!(ExitLens::Core, ExitLens::Full);
    }

    #[test]
    fn test_prediction_clone() {
        let pred = Prediction::Discrete {
            scores: vec![("Up".to_string(), 0.9)],
            conviction: 0.5,
        };
        let cloned = pred.clone();
        if let Prediction::Discrete { scores, conviction } = cloned {
            assert_eq!(scores.len(), 1);
            assert!((conviction - 0.5).abs() < 1e-10);
        } else {
            panic!("Expected Discrete");
        }
    }
}
