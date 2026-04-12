//! Messaging services — the foundational primitives of the wat-vm.
//!
//! The queue is the only atom. One in, one out. Contention-free.
//! Topic and mailbox are composed of queues:
//!   - Topic: one input queue, N output queues. Fan-out thread.
//!   - Mailbox: N input queues, one output queue. Fan-in thread via select.
//!
//! These are independent of the enterprise. Pure infrastructure.

pub mod queue;
pub mod topic;
pub mod mailbox;
