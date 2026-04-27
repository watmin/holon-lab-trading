//! Opt-in slow test — experiment 012 ("AI Provenance").
//!
//! AI agent accountability with consumer-side framing on top of
//! proof 005's Receipt / Journal / Registry. The user / auditor
//! holds the cryptographic upper hand: produce the Receipt or
//! your claim is unverified.
//!
//! Seven deftests:
//! - T1 happy path
//! - T2 output spoofing — fake AI quote
//! - T3 prompt tampering — adversarial transcript
//! - T4 model substitution — claim Opus, deliver Haiku
//! - T5 system-prompt injection — indirect injection detected
//! - T6 single agent step audit
//! - T7 multi-step chain integrity — agent trace tamper detection
//!
//! Skipped by default; run with:
//!
//! ```bash
//! cargo test --release --features experiment-012 --test experiment_012 -- --nocapture
//! ```

#![cfg(feature = "experiment-012")]

#[path = "../../src/shims.rs"]
mod shims;

wat::test! { path: "wat-tests-integ/experiment/012-ai-provenance", deps: [shims] }
