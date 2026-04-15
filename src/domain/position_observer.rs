/// position_observer.rs — Thought middleware. Composes market thoughts with
/// position-specific facts through a lens. Does not learn. Does not predict.
/// Quality is measured through the BROKER's curve.

use crate::types::enums::PositionLens;

/// Enriches market thoughts with position-specific facts through a lens.
pub struct PositionObserver {
    /// Which judgment vocabulary.
    pub lens: PositionLens,
}

impl PositionObserver {
    pub fn new(lens: PositionLens) -> Self {
        Self { lens }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_position_observer_new() {
        let obs = PositionObserver::new(PositionLens::Core);
        assert_eq!(obs.lens, PositionLens::Core);
    }

    #[test]
    fn test_position_observer_lens() {
        let obs = PositionObserver::new(PositionLens::Full);
        assert_eq!(obs.lens, PositionLens::Full);
    }
}
