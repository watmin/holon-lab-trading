//! Opt-in slow test — experiment 010 ("Receipts").
//!
//! Generic utility built on top of proof 004's proof-of-computation
//! primitive. A Receipt is a portable record asserting "I encoded
//! this form under this seed and got these bytes." Three views of
//! the same underlying object:
//!
//! - **explore-receipt.wat** — the unit primitive (`issue`, `verify`)
//! - **explore-journal.wat** — ordered append-only collection
//!   (`append`, `verify-at`)
//! - **explore-registry.wat** — content-addressed lookup
//!   (`register`, `lookup`)
//! - **explore-applications.wat** — applied demonstrations
//!
//! Naming verdict (gaze ward, 2026-04-26): `Receipt` over
//! Commitment/Witness/Proof; `Journal` over Ledger/Chain;
//! `Registry` over Vault/Repository; `issue`/`verify` for the unit
//! verbs; `append`/`verify-at` for the journal; `register`/`lookup`
//! for the registry.
//!
//! Skipped by default; run with:
//!
//! ```bash
//! cargo test --release --features experiment-010 --test experiment_010 -- --nocapture
//! ```

#![cfg(feature = "experiment-010")]

#[path = "../../src/shims.rs"]
mod shims;

wat::test! { path: "wat-tests-integ/experiment/010-receipts", deps: [shims] }
