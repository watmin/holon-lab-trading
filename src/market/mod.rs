//! Market domain — shared primitives for market-level modules.
//!
//! Lens enum, observer panel, and re-exports for market::manager, etc.

pub mod desk;
pub mod exit;
pub mod manager;
pub mod observer;

/// The vocabulary lens an observer thinks through.
/// Each lens selects which eval methods fire during thought encoding.
/// The compiler guards renames — no silent string mismatches.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Lens {
    Momentum,
    Structure,
    Volume,
    Narrative,
    Regime,
    Generalist,
    /// Limited generalist: only the original 8 eval methods (pre-refactor vocabulary).
    /// Diagnostic lens — measures whether the expanded vocabulary dilutes signal.
    GeneralistClassic,
}

impl Lens {
    /// The string name used for atom lookup and journal naming.
    pub fn as_str(&self) -> &'static str {
        match self {
            Lens::Momentum          => "momentum",
            Lens::Structure         => "structure",
            Lens::Volume            => "volume",
            Lens::Narrative         => "narrative",
            Lens::Regime            => "regime",
            Lens::Generalist        => "generalist",
            Lens::GeneralistClassic => "gen-classic",
        }
    }

    /// Does this lens include the given specialist vocabulary?
    pub fn includes(&self, specialists: &[Lens]) -> bool {
        matches!(self, Lens::Generalist | Lens::GeneralistClassic)
            || specialists.contains(self)
    }
}

/// The enterprise's observer panel: 5 specialists + 2 generalists.
/// Single source of truth — used by enterprise.rs (atom lookup) and state.rs (observer creation).
pub const OBSERVER_LENSES: [Lens; 7] = [
    Lens::Momentum,
    Lens::Structure,
    Lens::Volume,
    Lens::Narrative,
    Lens::Regime,
    Lens::Generalist,
    Lens::GeneralistClassic,
];
