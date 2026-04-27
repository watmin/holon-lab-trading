//! Opt-in slow test — experiment 011 ("Supply Chain").
//!
//! Competent demonstration of supply-chain attack detection on top
//! of proof 005's Receipt / Journal / Registry primitives. Seven
//! deftests, each mapped to a real, named attack class:
//!
//! - T1 happy path
//! - T2 registry tampering (CWE-345)
//! - T3 dependency confusion / typosquat (CWE-1357)
//! - T4 backdoor injection (Solar Winds class — CWE-506)
//! - T5 silent version drift
//! - T6 reproducible builds
//! - T7 release order audit
//!
//! Out of scope: key rotation, revocation, time-stamping, network-
//! level attacks. The substrate gives a primitive; the system
//! layer composes above.
//!
//! Skipped by default; run with:
//!
//! ```bash
//! cargo test --release --features experiment-011 --test experiment_011 -- --nocapture
//! ```

#![cfg(feature = "experiment-011")]

#[path = "../../src/shims.rs"]
mod shims;

wat::test! { path: "wat-tests-integ/experiment/011-supply-chain", deps: [shims] }
