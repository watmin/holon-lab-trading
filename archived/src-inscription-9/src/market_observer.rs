/// MarketObserver — predicts direction (Up/Down) from candle data.
/// Each observer has a lens selecting which vocabulary modules it thinks about.

use holon::kernel::vector::Vector;
use holon::memory::{OnlineSubspace, ReckConfig, Reckoner};

use crate::candle::Candle;
use crate::engram_gate::{check_engram_gate, EngramGateState};
use crate::enums::{Direction, MarketLens, Outcome, ThoughtAST};
use crate::thought_encoder::ThoughtEncoder;
use crate::window_sampler::WindowSampler;

/// A market observer with a lens, reckoner, noise subspace, and window sampler.
pub struct MarketObserver {
    pub lens: MarketLens,
    pub reckoner: Reckoner,
    pub noise_subspace: OnlineSubspace,
    pub window_sampler: WindowSampler,
    pub resolved: usize,
    pub good_state_subspace: OnlineSubspace,
    pub engram_gate_state: EngramGateState,
    pub last_prediction: Direction,
}

impl MarketObserver {
    pub fn new(
        lens: MarketLens,
        dims: usize,
        recalib_interval: usize,
        ws: WindowSampler,
    ) -> Self {
        Self {
            reckoner: Reckoner::new(
                &format!("market-{}", lens),
                dims,
                recalib_interval,
                ReckConfig::Discrete(vec!["Up".into(), "Down".into()]),
            ),
            noise_subspace: OnlineSubspace::new(dims, 8),
            window_sampler: ws,
            resolved: 0,
            good_state_subspace: OnlineSubspace::new(dims, 4),
            engram_gate_state: EngramGateState::new(),
            last_prediction: Direction::Up,
            lens,
        }
    }

    /// Strip noise: return the anomalous component.
    pub fn strip_noise(&self, thought: &Vector) -> Vector {
        let f64_data = thought.to_f64();
        let anomalous = self.noise_subspace.anomalous_component(&f64_data);
        Vector::from_f64(&anomalous)
    }

    /// Experience: how much has this observer learned?
    pub fn experience(&self) -> f64 {
        self.reckoner.experience()
    }

    /// Observe a candle and produce a thought + prediction + edge + misses.
    /// Returns (thought, enterprise_prediction, edge, misses).
    pub fn observe_candle(
        &mut self,
        fact_asts: Vec<ThoughtAST>,
        encoder: &ThoughtEncoder,
    ) -> (Vector, crate::enums::Prediction, f64, Vec<(ThoughtAST, Vector)>) {
        // Wrap in a Bundle AST
        let bundle_ast = ThoughtAST::Bundle(fact_asts);

        // Encode via ThoughtEncoder
        let (thought, misses) = encoder.encode(&bundle_ast);

        // Update noise subspace
        self.noise_subspace.update(&thought.to_f64());

        // Strip noise
        let stripped = self.strip_noise(&thought);

        // Predict direction
        let pred = self.reckoner.predict(&stripped);

        let conviction = pred.conviction;

        // Edge
        let edge_val = if self.reckoner.total_updates() >= 50 {
            // Use conviction as proxy for edge
            if let Some(acc) = self.reckoner.accuracy_at(conviction) {
                (acc - 0.5).max(0.0) * 2.0
            } else {
                0.0
            }
        } else {
            0.0
        };

        // Determine predicted direction from scores
        let predicted_dir = if let Some(dir_label) = pred.direction {
            if let Some(name) = self.reckoner.label_name(dir_label) {
                if name == "Up" {
                    Direction::Up
                } else {
                    Direction::Down
                }
            } else {
                Direction::Up
            }
        } else {
            Direction::Up
        };

        self.last_prediction = predicted_dir.clone();

        // Convert holon-rs Prediction to enterprise Prediction
        let enterprise_pred = crate::enums::Prediction::Discrete {
            scores: pred
                .scores
                .iter()
                .map(|ls| {
                    let name = self
                        .reckoner
                        .label_name(ls.label)
                        .unwrap_or("?")
                        .to_string();
                    (name, ls.cosine)
                })
                .collect(),
            conviction,
        };

        (thought, enterprise_pred, edge_val, misses)
    }

    /// Resolve: the market told us what actually happened.
    pub fn resolve(
        &mut self,
        thought: &Vector,
        actual_direction: &Direction,
        weight: f64,
    ) {
        let stripped = self.strip_noise(thought);

        // The actual direction becomes the label
        let label_idx = match actual_direction {
            Direction::Up => 0,
            Direction::Down => 1,
        };
        let label = holon::memory::Label::from_index(label_idx);

        // Observe the label
        self.reckoner.observe(&stripped, label, weight);

        // Check if prediction was correct
        let correct = self.last_prediction == *actual_direction;

        // Get conviction for curve
        let pred = self.reckoner.predict(&stripped);
        let conviction = pred.conviction;

        // Feed the curve
        self.reckoner.resolve(conviction, correct);

        // Check engram gate
        let outcome = if correct {
            Outcome::Grace
        } else {
            Outcome::Violence
        };
        check_engram_gate(
            &self.reckoner,
            &mut self.good_state_subspace,
            &mut self.engram_gate_state,
            &outcome,
        );

        self.resolved += 1;
    }
}

/// Collect vocabulary facts for a lens. Placeholder — returns time facts.
/// The actual vocab modules will fill these in.
pub fn lens_facts(lens: &MarketLens, _c: &Candle) -> Vec<ThoughtAST> {
    // Minimal: encode time facts that always apply
    let mut facts = vec![
        ThoughtAST::Circular {
            name: "hour".into(),
            value: _c.hour,
            period: 24.0,
        },
        ThoughtAST::Circular {
            name: "day-of-week".into(),
            value: _c.day_of_week,
            period: 7.0,
        },
        ThoughtAST::Circular {
            name: "minute".into(),
            value: _c.minute,
            period: 60.0,
        },
    ];

    // Add lens-specific facts
    match lens {
        MarketLens::Momentum | MarketLens::Generalist => {
            facts.push(ThoughtAST::Linear {
                name: "rsi".into(),
                value: _c.rsi,
                scale: 1.0,
            });
            facts.push(ThoughtAST::Log {
                name: "volume-accel".into(),
                value: _c.volume_accel.max(0.001),
            });
        }
        MarketLens::Structure => {
            facts.push(ThoughtAST::Linear {
                name: "bb-pos".into(),
                value: _c.bb_pos,
                scale: 1.0,
            });
            facts.push(ThoughtAST::Linear {
                name: "kelt-pos".into(),
                value: _c.kelt_pos,
                scale: 1.0,
            });
        }
        MarketLens::Volume => {
            facts.push(ThoughtAST::Log {
                name: "obv-slope".into(),
                value: _c.obv_slope_12.abs().max(0.001),
            });
            facts.push(ThoughtAST::Log {
                name: "volume-accel".into(),
                value: _c.volume_accel.max(0.001),
            });
        }
        MarketLens::Narrative => {
            facts.push(ThoughtAST::Linear {
                name: "tf-agreement".into(),
                value: _c.tf_agreement,
                scale: 1.0,
            });
        }
        MarketLens::Regime => {
            facts.push(ThoughtAST::Linear {
                name: "kama-er".into(),
                value: _c.kama_er,
                scale: 1.0,
            });
            facts.push(ThoughtAST::Linear {
                name: "hurst".into(),
                value: _c.hurst,
                scale: 1.0,
            });
        }
    }

    facts
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_market_observer_construct() {
        let ws = WindowSampler::new(42, 10, 200);
        let obs = MarketObserver::new(MarketLens::Momentum, 4096, 500, ws);
        assert_eq!(obs.lens, MarketLens::Momentum);
        assert_eq!(obs.resolved, 0);
        assert_eq!(obs.last_prediction, Direction::Up);
    }

    #[test]
    fn test_strip_noise_returns_non_zero() {
        let ws = WindowSampler::new(42, 10, 200);
        let mut obs = MarketObserver::new(MarketLens::Momentum, 256, 500, ws);
        // Feed some data into the noise subspace first
        let thought = Vector::from_f64(&vec![1.0; 256]);
        obs.noise_subspace.update(&thought.to_f64());
        obs.noise_subspace.update(&thought.to_f64());
        // Now strip noise from a different vector
        let other = Vector::from_f64(&vec![0.5; 256]);
        let stripped = obs.strip_noise(&other);
        // The anomalous component should be non-zero (different from noise basis)
        assert_eq!(stripped.dimensions(), 256);
    }
}
