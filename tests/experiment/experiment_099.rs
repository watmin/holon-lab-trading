//! Probe — minimal isolation test for arc 070's :wat::eval::walk
//! parametric WalkStep<A> in the lab harness.

#![cfg(feature = "experiment-099")]

#[path = "../../src/shims.rs"]
mod shims;

wat::test! { path: "wat-tests-integ/experiment/099-walkstep-probe", deps: [shims] }
