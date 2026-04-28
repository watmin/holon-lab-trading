//! Opt-in slow test — experiment 023 ("Population Cache").
//!
//! Proof 019. The chapter-71 architecture: cache as a multi-valued
//! relation `form → Vec<form>`. Walker queries; cache returns a
//! population of prior walkers' terminals; consumer reads via
//! cosine-rank-and-pick. The substrate's predator contract.
//!
//! Six tests:
//! - T1 empty cache → no population
//! - T2 single corpse → consumer feeds
//! - T3 two corpses, query near A → picks A
//! - T4 two corpses, query near B → picks B
//! - T5 distant query → empty population (locality bounded)
//! - T6 population gradient: readout tracks query position
//!
//! Skipped by default; run with:
//!
//! ```bash
//! cargo test --release --features experiment-023 --test experiment_023 -- --nocapture
//! ```

#![cfg(feature = "experiment-023")]

#[path = "../../src/shims.rs"]
mod shims;

wat::test! { path: "wat-tests-integ/experiment/023-population-cache", deps: [shims] }
