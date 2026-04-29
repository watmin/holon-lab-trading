//! Opt-in slow test — proof 002 ("Thinker Baseline").
//!
//! Pair file for `docs/proofs/2026/04/002-thinker-baseline/PROOF.md`.
//! Two deftests, one per v1 thinker (always-up, sma-cross), each
//! running the simulator on 10k real BTC candles AND logging one
//! row per Outcome to `runs/proof-002-<thinker>.db` for SQL-friendly
//! analysis. Same shape as proof 001 with the RunDb shim wired in.
//!
//! Skipped by default; run with:
//!
//! ```bash
//! rm -f runs/proof-002-*.db   # cleanup; PK violation otherwise
//! cargo test --release --features proof-002 --test proof_002
//! ```
//!
//! Wat program at
//! `wat-tests-integ/proof/002-thinker-baseline/002-thinker-baseline.wat`.

#![cfg(feature = "proof-002")]

#[path = "../../src/shims.rs"]
mod shims;

wat::test! { path: "wat-tests-integ/proof/002-thinker-baseline", deps: [shims, wat_sqlite] }
