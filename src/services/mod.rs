//! Messaging services — the foundational primitives of the wat-vm.
//!
//! These are independent of the enterprise. Pure infrastructure.
//! Each service is a thin wrapper today; threads come later for observability.

pub mod queue;
pub mod topic;
pub mod mailbox;
