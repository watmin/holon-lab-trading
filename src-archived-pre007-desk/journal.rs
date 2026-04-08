//! Journal bridge — re-exports holon::Journal and defines enterprise labels.
//!
//! Each journal registers its own labels at construction.
//! The old Outcome { Buy, Sell, Noise } is gone.
//! Direction is for position management, not journal labels.

pub use holon::memory::{Journal, Label, Prediction};

// ─── Direction (position management, not a journal label) ───────────────────

/// Which way is the position facing? This is trade accounting, not prediction.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Direction {
    Long,
    Short,
}

impl std::fmt::Display for Direction {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Direction::Long  => write!(f, "Buy"),
            Direction::Short => write!(f, "Sell"),
        }
    }
}

// ─── Enterprise labels ──────────────────────────────────────────────────────
//
// Each journal registers the labels that match its question.
// Labels are symbols — created once, used as cheap integer handles.
//
// Market direction (observers + manager):
//   let buy  = journal.register("Buy");
//   let sell = journal.register("Sell");
//
// Exit decision (exit expert):
//   let hold = journal.register("Hold");
//   let exit = journal.register("Exit");
//
// Risk health (future):
//   let healthy   = journal.register("Healthy");
//   let unhealthy = journal.register("Unhealthy");
//
// Treasury allocation (future):
//   let allocate = journal.register("Allocate");
//   let withhold = journal.register("Withhold");

// register_direction and register_exit removed — callers register labels inline.
