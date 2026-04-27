//! Opt-in slow test — experiment 016 ("Property Tests").
//!
//! Proof 011. The first six proofs (005-010) used hand-picked
//! tests; this proof closes the "we tested 6 cases" gap by
//! iterating each property across 100 generated inputs.
//!
//! Six property tests, 100 iterations each = 600 substrate-level
//! consistency checks:
//! - T1 receipt round-trip property
//! - T2 distinct-form rejection property
//! - T3 encoding determinism property
//! - T4 self-coincidence property
//! - T5 tamper-detection property
//! - T6 cross-form orthogonality property
//!
//! Skipped by default; run with:
//!
//! ```bash
//! cargo test --release --features experiment-016 --test experiment_016 -- --nocapture
//! ```

#![cfg(feature = "experiment-016")]

#[path = "../../src/shims.rs"]
mod shims;

wat::test! { path: "wat-tests-integ/experiment/016-property-tests", deps: [shims] }
