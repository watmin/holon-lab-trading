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

/// Read a direction out of a holon prediction. Label index 0 is Up,
/// index 1 is Down. Defaults to Up when no direction is set (the
/// reckoner hasn't calibrated yet).
impl From<&holon::memory::Prediction> for Direction {
    fn from(pred: &holon::memory::Prediction) -> Self {
        if pred.direction.map_or(true, |d| d.index() == 0) {
            Direction::Up
        } else {
            Direction::Down
        }
    }
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
/// Proposals 041+042: three schools (Dow, Pring, Wyckoff), 11 lenses total.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum MarketLens {
    // Dow school
    DowTrend,
    DowVolume,
    DowCycle,
    DowGeneralist,
    // Pring school
    PringImpulse,
    PringConfirmation,
    PringRegime,
    PringGeneralist,
    // Wyckoff school
    WyckoffEffort,
    WyckoffPersistence,
    WyckoffPosition,
}

impl std::fmt::Display for MarketLens {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            MarketLens::DowTrend => write!(f, "dow-trend"),
            MarketLens::DowVolume => write!(f, "dow-volume"),
            MarketLens::DowCycle => write!(f, "dow-cycle"),
            MarketLens::DowGeneralist => write!(f, "dow-generalist"),
            MarketLens::PringImpulse => write!(f, "pring-impulse"),
            MarketLens::PringConfirmation => write!(f, "pring-confirmation"),
            MarketLens::PringRegime => write!(f, "pring-regime"),
            MarketLens::PringGeneralist => write!(f, "pring-generalist"),
            MarketLens::WyckoffEffort => write!(f, "wyckoff-effort"),
            MarketLens::WyckoffPersistence => write!(f, "wyckoff-persistence"),
            MarketLens::WyckoffPosition => write!(f, "wyckoff-position"),
        }
    }
}

/// Regime observer lens — which trade-state vocabulary a regime observer uses.
/// Proposal 040: two lenses based on trade atoms, not market data.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum RegimeLens {
    /// 5 trade atoms — the consensus (excursion, retracement, age, peak-age, signaled).
    Core,
    /// 13 trade atoms (10 original + 3 phase biography) — all three voices plus phase context.
    Full,
}

impl std::fmt::Display for RegimeLens {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            RegimeLens::Core => write!(f, "core"),
            RegimeLens::Full => write!(f, "full"),
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
        assert_eq!(MarketLens::DowTrend.to_string(), "dow-trend");
        assert_eq!(MarketLens::DowVolume.to_string(), "dow-volume");
        assert_eq!(MarketLens::DowCycle.to_string(), "dow-cycle");
        assert_eq!(MarketLens::DowGeneralist.to_string(), "dow-generalist");
        assert_eq!(MarketLens::PringImpulse.to_string(), "pring-impulse");
        assert_eq!(MarketLens::PringConfirmation.to_string(), "pring-confirmation");
        assert_eq!(MarketLens::PringRegime.to_string(), "pring-regime");
        assert_eq!(MarketLens::PringGeneralist.to_string(), "pring-generalist");
        assert_eq!(MarketLens::WyckoffEffort.to_string(), "wyckoff-effort");
        assert_eq!(MarketLens::WyckoffPersistence.to_string(), "wyckoff-persistence");
        assert_eq!(MarketLens::WyckoffPosition.to_string(), "wyckoff-position");
    }

    #[test]
    fn test_market_lens_equality() {
        assert_eq!(MarketLens::DowTrend, MarketLens::DowTrend);
        assert_ne!(MarketLens::DowTrend, MarketLens::PringImpulse);
    }

    #[test]
    fn test_regime_lens_display() {
        assert_eq!(RegimeLens::Core.to_string(), "core");
        assert_eq!(RegimeLens::Full.to_string(), "full");
    }

    #[test]
    fn test_regime_lens_equality() {
        assert_eq!(RegimeLens::Core, RegimeLens::Core);
        assert_ne!(RegimeLens::Core, RegimeLens::Full);
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
