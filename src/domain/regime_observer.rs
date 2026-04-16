/// regime_observer.rs — Thought middleware. Composes market thoughts with
/// position-specific facts through a lens. Does not learn. Does not predict.
/// Quality is measured through the BROKER's curve.

use crate::types::enums::RegimeLens;

/// Enriches market thoughts with position-specific facts through a lens.
pub struct RegimeObserver {
    /// Which judgment vocabulary.
    pub lens: RegimeLens,
}

impl RegimeObserver {
    pub fn new(lens: RegimeLens) -> Self {
        Self { lens }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_regime_observer_new() {
        let obs = RegimeObserver::new(RegimeLens::Core);
        assert_eq!(obs.lens, RegimeLens::Core);
    }

    #[test]
    fn test_regime_observer_lens() {
        let obs = RegimeObserver::new(RegimeLens::Full);
        assert_eq!(obs.lens, RegimeLens::Full);
    }
}
