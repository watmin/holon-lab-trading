//! Programs — everything that runs on the wat-vm.
//!
//! Stdlib: generic, reusable, domain-independent.
//!   Cache, database, console — any application would want these.
//!
//! App: domain-specific. This enterprise. This domain.
//!   Observer, broker, exit observer — trading programs.

pub mod stdlib;
pub mod app;
