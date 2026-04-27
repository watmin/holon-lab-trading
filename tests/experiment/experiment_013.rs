//! Opt-in slow test — experiment 013 ("Soundness Gate").
//!
//! The truth engine. The substrate measures soundness of LLM-emitted
//! wat claims against an axiom set; the verdict is a thresholded
//! decision (approve/review/reject); approved claims are rendered to
//! English. Rejected claims never reach the user as English.
//!
//! Seven deftests:
//! - T1 sound claim approves and renders
//! - T2 unsound claim (public ingress) rejects
//! - T3 wildcard IAM rejects
//! - T4 multi-axiom alignment approves
//! - T5 reasoning chain — weakest link decides verdict
//! - T6 full pipeline E2E
//! - T7 explicit contradiction caught
//!
//! Skipped by default; run with:
//!
//! ```bash
//! cargo test --release --features experiment-013 --test experiment_013 -- --nocapture
//! ```

#![cfg(feature = "experiment-013")]

#[path = "../../src/shims.rs"]
mod shims;

wat::test! { path: "wat-tests-integ/experiment/013-soundness-gate", deps: [shims] }
