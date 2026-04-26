//! Opt-in slow test — proof 003 ("Thinker Significance").
//!
//! Pair file for `docs/proofs/2026/04/003-thinker-significance/PROOF.md`.
//! ONE deftest running BOTH v1 thinkers (always-up, sma-cross) across
//! 10 strided 10k-candle windows of real BTC. Each window's outcomes
//! are batch-logged to ONE SQLite db at `runs/proof-003-<epoch>.db`
//! via `:lab::rundb::Service` (arc 029 — CSP service with batch+ack).
//!
//! Skipped by default; run with:
//!
//! ```bash
//! cargo test --release --features proof-003 --test proof_003 -- --nocapture
//! ```
//!
//! Wat program at
//! `wat-tests-integ/proof/003-thinker-significance/003-thinker-significance.wat`.

#![cfg(feature = "proof-003")]

#[path = "../../src/shims.rs"]
mod shims;

wat::test! { path: "wat-tests-integ/proof/003-thinker-significance", deps: [shims] }
