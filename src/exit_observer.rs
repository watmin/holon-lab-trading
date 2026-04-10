/// ExitObserver — predicts distances for exit stops.
/// Four continuous reckoners: trail, stop, tp, runner-trail.

use holon::kernel::primitives::Primitives;
use holon::kernel::vector::Vector;
use holon::memory::{ReckConfig, Reckoner};

use crate::candle::Candle;
use crate::distances::Distances;
use crate::enums::{ExitLens, ThoughtAST};
use crate::scalar_accumulator::ScalarAccumulator;
use crate::thought_encoder::ThoughtEncoder;

/// An exit observer with a lens and four continuous reckoners.
pub struct ExitObserver {
    pub lens: ExitLens,
    pub trail_reckoner: Reckoner,
    pub stop_reckoner: Reckoner,
    pub tp_reckoner: Reckoner,
    pub runner_reckoner: Reckoner,
    pub default_distances: Distances,
}

impl ExitObserver {
    pub fn new(
        lens: ExitLens,
        dims: usize,
        recalib_interval: usize,
        default_trail: f64,
        default_stop: f64,
        default_tp: f64,
        default_runner_trail: f64,
    ) -> Self {
        let name_prefix = format!("exit-{}", lens);
        Self {
            trail_reckoner: Reckoner::new(
                &format!("{}-trail", name_prefix),
                dims,
                recalib_interval,
                ReckConfig::Continuous(default_trail),
            ),
            stop_reckoner: Reckoner::new(
                &format!("{}-stop", name_prefix),
                dims,
                recalib_interval,
                ReckConfig::Continuous(default_stop),
            ),
            tp_reckoner: Reckoner::new(
                &format!("{}-tp", name_prefix),
                dims,
                recalib_interval,
                ReckConfig::Continuous(default_tp),
            ),
            runner_reckoner: Reckoner::new(
                &format!("{}-runner", name_prefix),
                dims,
                recalib_interval,
                ReckConfig::Continuous(default_runner_trail),
            ),
            default_distances: Distances::new(
                default_trail,
                default_stop,
                default_tp,
                default_runner_trail,
            ),
            lens,
        }
    }

    /// Collect exit vocabulary facts for this lens.
    pub fn encode_exit_facts(&self, c: &Candle) -> Vec<ThoughtAST> {
        match &self.lens {
            ExitLens::Volatility => vec![
                ThoughtAST::Log {
                    name: "atr-ratio".into(),
                    value: c.atr_r.max(0.001),
                },
                ThoughtAST::Linear {
                    name: "atr-roc-6".into(),
                    value: c.atr_roc_6,
                    scale: 1.0,
                },
                ThoughtAST::Linear {
                    name: "atr-roc-12".into(),
                    value: c.atr_roc_12,
                    scale: 1.0,
                },
            ],
            ExitLens::Structure => vec![
                ThoughtAST::Linear {
                    name: "trend-consistency-6".into(),
                    value: c.trend_consistency_6,
                    scale: 1.0,
                },
                ThoughtAST::Linear {
                    name: "trend-consistency-12".into(),
                    value: c.trend_consistency_12,
                    scale: 1.0,
                },
                ThoughtAST::Linear {
                    name: "trend-consistency-24".into(),
                    value: c.trend_consistency_24,
                    scale: 1.0,
                },
            ],
            ExitLens::Timing => vec![
                ThoughtAST::Linear {
                    name: "rsi".into(),
                    value: c.rsi,
                    scale: 1.0,
                },
                ThoughtAST::Log {
                    name: "volume-accel".into(),
                    value: c.volume_accel.max(0.001),
                },
            ],
            ExitLens::Generalist => {
                let mut facts = vec![
                    ThoughtAST::Log {
                        name: "atr-ratio".into(),
                        value: c.atr_r.max(0.001),
                    },
                    ThoughtAST::Linear {
                        name: "atr-roc-6".into(),
                        value: c.atr_roc_6,
                        scale: 1.0,
                    },
                    ThoughtAST::Linear {
                        name: "trend-consistency-6".into(),
                        value: c.trend_consistency_6,
                        scale: 1.0,
                    },
                    ThoughtAST::Linear {
                        name: "trend-consistency-12".into(),
                        value: c.trend_consistency_12,
                        scale: 1.0,
                    },
                ];
                facts.push(ThoughtAST::Linear {
                    name: "rsi".into(),
                    value: c.rsi,
                    scale: 1.0,
                });
                facts
            }
        }
    }

    /// Evaluate exit ASTs and compose with market thought.
    /// Returns (composed_vector, misses).
    pub fn evaluate_and_compose(
        &self,
        market_thought: &Vector,
        exit_fact_asts: Vec<ThoughtAST>,
        encoder: &ThoughtEncoder,
    ) -> (Vector, Vec<(ThoughtAST, Vector)>) {
        let mut all_vecs = vec![market_thought.clone()];
        let mut all_misses = Vec::new();

        for ast in &exit_fact_asts {
            let (v, m) = encoder.encode(ast);
            all_vecs.push(v);
            all_misses.extend(m);
        }

        let refs: Vec<&Vector> = all_vecs.iter().collect();
        let composed = Primitives::bundle(&refs);
        (composed, all_misses)
    }

    /// Is the exit observer experienced? All four reckoners must have experience.
    pub fn is_experienced(&self) -> bool {
        self.trail_reckoner.experience() > 0.0
            && self.stop_reckoner.experience() > 0.0
            && self.tp_reckoner.experience() > 0.0
            && self.runner_reckoner.experience() > 0.0
    }

    /// Recommend distances for a composed thought.
    /// Returns (Distances, min_experience).
    pub fn recommended_distances(
        &self,
        composed: &Vector,
        broker_accums: &[ScalarAccumulator],
    ) -> (Distances, f64) {
        let trail_val = cascade_distance(
            &self.trail_reckoner,
            composed,
            broker_accums.get(0),
            self.default_distances.trail,
        );
        let stop_val = cascade_distance(
            &self.stop_reckoner,
            composed,
            broker_accums.get(1),
            self.default_distances.stop,
        );
        let tp_val = cascade_distance(
            &self.tp_reckoner,
            composed,
            broker_accums.get(2),
            self.default_distances.tp,
        );
        let runner_val = cascade_distance(
            &self.runner_reckoner,
            composed,
            broker_accums.get(3),
            self.default_distances.runner_trail,
        );

        let exp = self
            .trail_reckoner
            .experience()
            .min(self.stop_reckoner.experience())
            .min(self.tp_reckoner.experience())
            .min(self.runner_reckoner.experience());

        (Distances::new(trail_val, stop_val, tp_val, runner_val), exp)
    }

    /// Observe optimal distances from a resolution.
    pub fn observe_distances(
        &mut self,
        composed: &Vector,
        optimal: &Distances,
        weight: f64,
    ) {
        self.trail_reckoner
            .observe_scalar(composed, optimal.trail, weight);
        self.stop_reckoner
            .observe_scalar(composed, optimal.stop, weight);
        self.tp_reckoner
            .observe_scalar(composed, optimal.tp, weight);
        self.runner_reckoner
            .observe_scalar(composed, optimal.runner_trail, weight);
    }
}

/// Cascade: contextual (reckoner) -> global per-pair (scalar accumulator) -> default (crutch).
fn cascade_distance(
    reckoner: &Reckoner,
    composed: &Vector,
    accum: Option<&ScalarAccumulator>,
    default_val: f64,
) -> f64 {
    if reckoner.experience() > 0.0 {
        // Contextual — for THIS thought
        reckoner.query(composed)
    } else if let Some(acc) = accum {
        if acc.count > 0 {
            // Global per-pair — any thought
            acc.extract(50, (0.002, 0.10))
        } else {
            default_val
        }
    } else {
        default_val
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_exit_observer_construct() {
        let obs = ExitObserver::new(
            ExitLens::Volatility,
            4096,
            500,
            0.02,
            0.03,
            0.05,
            0.025,
        );
        assert_eq!(obs.lens, ExitLens::Volatility);
        assert_eq!(obs.default_distances.trail, 0.02);
        assert_eq!(obs.default_distances.stop, 0.03);
        assert_eq!(obs.default_distances.tp, 0.05);
        assert_eq!(obs.default_distances.runner_trail, 0.025);
    }

    #[test]
    fn test_cascade_returns_defaults_when_empty() {
        let obs = ExitObserver::new(
            ExitLens::Volatility,
            4096,
            500,
            0.02,
            0.03,
            0.05,
            0.025,
        );
        let composed = Vector::zeros(4096);
        let accums: Vec<ScalarAccumulator> = Vec::new();
        let (dists, exp) = obs.recommended_distances(&composed, &accums);

        // No experience — should return defaults
        assert_eq!(dists.trail, 0.02);
        assert_eq!(dists.stop, 0.03);
        assert_eq!(dists.tp, 0.05);
        assert_eq!(dists.runner_trail, 0.025);
        assert_eq!(exp, 0.0);
    }
}
