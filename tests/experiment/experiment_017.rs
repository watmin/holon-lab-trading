//! Opt-in slow test — experiment 017 ("Scaling Stress").
//!
//! Proof 013. Substrate's claimed scaling properties at the
//! Kanerva boundary (sqrt(d) = 100 items at d=10000), at high
//! cardinality (500 distinct receipts), and at depth (5-level
//! nested forms).
//!
//! Six tests:
//! - T1 width below capacity (10 atoms)
//! - T2 width at capacity (100 atoms)
//! - T3 width over capacity (101 atoms) → CapacityExceeded
//! - T4 cardinality round-trip (500 distinct forms)
//! - T5 cardinality rejection (500 distinct pairs)
//! - T6 depth stress (5-level nested receipts)
//!
//! Skipped by default; run with:
//!
//! ```bash
//! cargo test --release --features experiment-017 --test experiment_017 -- --nocapture
//! ```

#![cfg(feature = "experiment-017")]

#[path = "../../src/shims.rs"]
mod shims;

wat::test! { path: "wat-tests-integ/experiment/017-scaling-stress", deps: [shims] }
