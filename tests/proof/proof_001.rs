//! Opt-in slow test — proof 001 ("The Machine Runs").
//!
//! Pair file for `docs/proofs/2026/04/001-the-machine-runs/PROOF.md`.
//! Two deftests, one per v1 thinker (always-up, sma-cross), each
//! running the simulator on 10k real BTC candles. Asserts conservation
//! invariant + plausible ranges.
//!
//! Skipped by default; run with:
//!
//! ```bash
//! cargo test --release --features proof-001 --test proof_001
//! ```
//!
//! Wat program at
//! `wat-tests-integ/proof/001-the-machine-runs/001-the-machine-runs.wat`.

#![cfg(feature = "proof-001")]

#[path = "../../src/shims.rs"]
mod shims;

wat::test! { path: "wat-tests-integ/proof/001-the-machine-runs", deps: [shims] }
