use std::sync::Arc;
/// scale_tracker.rs — learned scales for Linear atoms.
///
/// Every Linear atom has a scale that determines its manifold coverage.
/// Instead of hardcoding scales, the ScaleTracker learns from the data.
/// EMA of absolute values, updated every candle. The scale is 2× the EMA
/// (named constant SCALE_COVERAGE ≈ 89% coverage for Gaussian distributions).
///
/// Proposal 033. The machine starts ignorant and learns. Always.

use std::collections::HashMap;
use crate::encoding::thought_encoder::{round_to, ThoughtAST, ThoughtASTKind};

/// Named constant — the coverage multiplier. 2.0 ≈ 89% coverage
/// for a roughly Gaussian distribution. Documented as approximate.
pub const SCALE_COVERAGE: f64 = 2.0;

/// Tracks the observed range of a Linear atom's value.
/// EMA of absolute values, updated every candle.
#[derive(Clone, Debug)]
pub struct ScaleTracker {
    ema_abs: f64,
    count: usize,
}

impl ScaleTracker {
    pub fn new() -> Self {
        Self { ema_abs: 0.0, count: 0 }
    }

    pub fn update(&mut self, value: f64) {
        self.count += 1;
        let alpha = 1.0 / (self.count.max(100) as f64);
        self.ema_abs = (1.0 - alpha) * self.ema_abs + alpha * value.abs();
    }

    pub fn scale(&self) -> f64 {
        round_to((SCALE_COVERAGE * self.ema_abs).max(0.001), 2)
    }

    pub fn count(&self) -> usize {
        self.count
    }
}

/// Convenience: encode a Linear fact with a learned scale.
/// Updates the tracker, reads the scale, returns the ThoughtAST.
pub fn scaled_linear(
    name: &str,
    value: f64,
    scales: &mut HashMap<String, ScaleTracker>,
) -> ThoughtAST {
    let tracker = scales.entry(name.to_string())
        .or_insert_with(ScaleTracker::new);
    tracker.update(value);
    let s = tracker.scale();
    ThoughtAST::new(ThoughtASTKind::Bind(
        Arc::new(ThoughtAST::new(ThoughtASTKind::Atom(name.into()))),
        Arc::new(ThoughtAST::new(ThoughtASTKind::Linear { value: round_to(value, 2), scale: s })),
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_scale_tracker_starts_at_zero() {
        let tracker = ScaleTracker::new();
        assert_eq!(tracker.count(), 0);
        // (2.0 * 0.0).max(0.001) = 0.001, round_to(0.001, 2) = 0.0
        // The floor 0.001 rounds away at 2 decimal places. Scale starts at 0.0.
        // First real update pushes it above.
        assert_eq!(tracker.scale(), 0.0);
    }

    #[test]
    fn test_scale_converges() {
        let mut tracker = ScaleTracker::new();
        // Feed 1000 observations of 0.5 — slow EMA (alpha=1/max(count,100))
        for _ in 0..1000 {
            tracker.update(0.5);
        }
        // EMA of abs(0.5) converges to 0.5
        // Scale = round_to(2.0 * 0.5, 2) = 1.0
        let s = tracker.scale();
        assert!(s >= 0.9 && s <= 1.1, "scale should converge near 1.0, got {}", s);
    }

    #[test]
    fn test_round_to_keeps_cache_keys_stable() {
        // Same value rounded → same ThoughtAST → same cache key
        let v1 = round_to(0.123456, 2);
        let v2 = round_to(0.123999, 2);
        assert_eq!(v1, v2); // Both round to 0.12
    }

    #[test]
    fn test_scaled_linear_returns_linear_with_learned_scale() {
        let mut scales = HashMap::new();
        // First call: tracker starts at zero
        let ast = scaled_linear("test-atom", 0.5, &mut scales);
        // scaled_linear now returns Bind(Atom("test-atom"), Linear { value, scale })
        match &ast.kind {
            ThoughtASTKind::Bind(ref left, ref right) => {
                match (&left.kind, &right.kind) {
                    (ThoughtASTKind::Atom(name), ThoughtASTKind::Linear { value, scale }) => {
                        assert_eq!(name, "test-atom");
                        assert_eq!(*value, 0.5);
                        assert_eq!(*scale, 0.01);
                    }
                    _ => panic!("expected Bind(Atom, Linear)"),
                }
            }
            _ => panic!("expected Bind"),
        }
        // Verify tracker was stored
        assert!(scales.contains_key("test-atom"));
        assert_eq!(scales["test-atom"].count(), 1);
    }

    #[test]
    fn test_scaled_linear_accumulates() {
        let mut scales = HashMap::new();
        for _ in 0..1000 {
            scaled_linear("accum", 1.0, &mut scales);
        }
        let tracker = &scales["accum"];
        assert_eq!(tracker.count(), 1000);
        // EMA converges toward 1.0, scale → 2.0 (may not fully converge with slow EMA)
        let s = tracker.scale();
        assert!(s >= 1.8 && s <= 2.0, "scale should converge near 2.0, got {}", s);
    }

    #[test]
    fn test_separate_atoms_separate_trackers() {
        let mut scales = HashMap::new();
        scaled_linear("alpha", 0.5, &mut scales);
        scaled_linear("beta", 10.0, &mut scales);
        assert_eq!(scales.len(), 2);
    }
}
