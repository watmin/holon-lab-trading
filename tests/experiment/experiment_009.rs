//! Opt-in slow test — experiment 009 ("Cryptographic Substrate").
//!
//! Walks the directed-evaluation arc from scratch into a runnable
//! experiment. The forms-to-values relation is a directed graph;
//! values don't determine forms; the substrate enables both
//! symmetric (seed-as-key, AES-shaped) and asymmetric (form-as-
//! preimage-knowledge, signature-shaped) cryptographic constructions.
//!
//! Forms in this experiment are budgeted at ≤100 statements each
//! per Kanerva capacity (Ch 28's slack lemma + Ch 61's adjacent
//! infinities). Beyond ~100 reliable items per 10k-D vector under
//! the cosine threshold, encoding interference would corrupt the
//! cryptographic claims.
//!
//! Skipped by default; run with:
//!
//! ```bash
//! cargo test --release --features experiment-009 --test experiment_009 -- --nocapture
//! ```
//!
//! Wat program at
//! `wat-tests-integ/experiment/009-cryptographic-substrate/`.

#![cfg(feature = "experiment-009")]

#[path = "../../src/shims.rs"]
mod shims;

wat::test! { path: "wat-tests-integ/experiment/009-cryptographic-substrate", deps: [shims] }
