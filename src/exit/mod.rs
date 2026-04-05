//! Exit module — the accountability layer.
//!
//! The tuple journal owns the composition of contributor thoughts.
//! It records the outcome. It propagates the signal.
//! The contributors learn from the propagation.
//!
//! Generic. The journal doesn't care what the thoughts are about.

pub mod learned_stop;
pub mod optimal;
pub mod scalar;
pub mod tuple;
