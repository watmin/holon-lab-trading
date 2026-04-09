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

#[cfg(test)]
mod tests {
    use super::*;

    // ── Side ──────────────────────────────────────────────────────────

    #[test]
    fn test_side_variants_exist() {
        let _buy = Side::Buy;
        let _sell = Side::Sell;
    }

    #[test]
    fn test_side_exhaustive_match() {
        // If a variant is added, this will fail to compile.
        let s = Side::Buy;
        match s {
            Side::Buy => {}
            Side::Sell => {}
        }
    }

    #[test]
    fn test_side_copy_eq() {
        let a = Side::Buy;
        let b = a; // Copy
        assert_eq!(a, b);
    }

    // ── Direction ─────────────────────────────────────────────────────

    #[test]
    fn test_direction_variants_exist() {
        let _up = Direction::Up;
        let _down = Direction::Down;
    }

    #[test]
    fn test_direction_exhaustive_match() {
        let d = Direction::Up;
        match d {
            Direction::Up => {}
            Direction::Down => {}
        }
    }

    // ── Outcome ───────────────────────────────────────────────────────

    #[test]
    fn test_outcome_variants_exist() {
        let _g = Outcome::Grace;
        let _v = Outcome::Violence;
    }

    #[test]
    fn test_outcome_exhaustive_match() {
        let o = Outcome::Grace;
        match o {
            Outcome::Grace => {}
            Outcome::Violence => {}
        }
    }

    // ── TradePhase ────────────────────────────────────────────────────

    #[test]
    fn test_trade_phase_variants_exist() {
        let _a = TradePhase::Active;
        let _r = TradePhase::Runner;
        let _sv = TradePhase::SettledViolence;
        let _sg = TradePhase::SettledGrace;
    }

    #[test]
    fn test_trade_phase_exhaustive_match() {
        let p = TradePhase::Active;
        match p {
            TradePhase::Active => {}
            TradePhase::Runner => {}
            TradePhase::SettledViolence => {}
            TradePhase::SettledGrace => {}
        }
    }

    // ── ReckonerConfig ────────────────────────────────────────────────

    #[test]
    fn test_reckoner_config_discrete() {
        let rc = ReckonerConfig::Discrete {
            labels: vec!["Up".to_string(), "Down".to_string()],
        };
        if let ReckonerConfig::Discrete { labels } = rc {
            assert_eq!(labels.len(), 2);
            assert_eq!(labels[0], "Up");
            assert_eq!(labels[1], "Down");
        } else {
            panic!("Expected Discrete");
        }
    }

    #[test]
    fn test_reckoner_config_continuous() {
        let rc = ReckonerConfig::Continuous {
            default_value: 0.02,
        };
        if let ReckonerConfig::Continuous { default_value } = rc {
            assert!((default_value - 0.02).abs() < 1e-10);
        } else {
            panic!("Expected Continuous");
        }
    }

    // ── PredictionResult ──────────────────────────────────────────────

    #[test]
    fn test_prediction_result_discrete() {
        let pr = PredictionResult::Discrete {
            scores: vec![("Up".to_string(), 0.7), ("Down".to_string(), -0.3)],
            conviction: 0.5,
        };
        if let PredictionResult::Discrete { scores, conviction } = pr {
            assert_eq!(scores.len(), 2);
            assert!((conviction - 0.5).abs() < 1e-10);
        } else {
            panic!("Expected Discrete");
        }
    }

    #[test]
    fn test_prediction_result_continuous() {
        let pr = PredictionResult::Continuous {
            value: 0.03,
            experience: 0.8,
        };
        if let PredictionResult::Continuous { value, experience } = pr {
            assert!((value - 0.03).abs() < 1e-10);
            assert!((experience - 0.8).abs() < 1e-10);
        } else {
            panic!("Expected Continuous");
        }
    }

    // ── ScalarEncoding ────────────────────────────────────────────────

    #[test]
    fn test_scalar_encoding_variants() {
        let _log = ScalarEncoding::Log;
        let _lin = ScalarEncoding::Linear { scale: 1.0 };
        let _circ = ScalarEncoding::Circular { period: 24.0 };
    }

    #[test]
    fn test_scalar_encoding_exhaustive_match() {
        let e = ScalarEncoding::Log;
        match e {
            ScalarEncoding::Log => {}
            ScalarEncoding::Linear { .. } => {}
            ScalarEncoding::Circular { .. } => {}
        }
    }

    // ── MarketLens ────────────────────────────────────────────────────

    #[test]
    fn test_market_lens_six_variants() {
        let lenses = [
            MarketLens::Momentum,
            MarketLens::Structure,
            MarketLens::Volume,
            MarketLens::Narrative,
            MarketLens::Regime,
            MarketLens::Generalist,
        ];
        assert_eq!(lenses.len(), 6);
    }

    // ── ExitLens ──────────────────────────────────────────────────────

    #[test]
    fn test_exit_lens_four_variants() {
        let lenses = [
            ExitLens::Volatility,
            ExitLens::Structure,
            ExitLens::Timing,
            ExitLens::Generalist,
        ];
        assert_eq!(lenses.len(), 4);
    }
}
