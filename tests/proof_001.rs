//! Opt-in slow test — `wat-tests-proof-001/`.
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

#![cfg(feature = "proof-001")]

#[path = "../src/shims.rs"]
mod shims;

wat::test! { path: "wat-tests-proof-001", deps: [shims] }
