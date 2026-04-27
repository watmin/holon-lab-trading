//! Opt-in slow test — experiment 014 ("Time Witness").
//!
//! External time-witness verification — proof 009. Builder framing:
//! *"the whole point of wat — is to stop lies in statements."* A
//! time-witness is a statement; the substrate measures soundness
//! against an external beacon's published axiom set.
//!
//! Six deftests:
//! - T1 honest single-beacon path
//! - T2 witness lie caught at time check
//! - T3 future round (not in beacon's axioms)
//! - T4 binding tamper before time check
//! - T5 multi-beacon triangulation
//! - T6 no time claim → review band
//!
//! Skipped by default; run with:
//!
//! ```bash
//! cargo test --release --features experiment-014 --test experiment_014 -- --nocapture
//! ```

#![cfg(feature = "experiment-014")]

#[path = "../../src/shims.rs"]
mod shims;

wat::test! { path: "wat-tests-integ/experiment/014-time-witness", deps: [shims] }
