//! Opt-in slow test — experiment 015 ("Causal Time").
//!
//! Drop-in time-claim verifier — proof 010. Pure verification
//! function. Caller provides receipt + expected-form + cited
//! anchors + reference-data + own clock + freshness policy;
//! substrate computes consistency verdict. No external services,
//! no trusted authority, no new infrastructure.
//!
//! Six deftests:
//! - T1 honest path
//! - T2 backdating caught (claim predates cited anchor)
//! - T3 forward-dating caught (claim exceeds verifier's clock)
//! - T4 stale anchor under freshness policy
//! - T5 unanchored receipt (distinct verdict for caller routing)
//! - T6 multi-anchor: tightest window via MAX(anchor times)
//!
//! Skipped by default; run with:
//!
//! ```bash
//! cargo test --release --features experiment-015 --test experiment_015 -- --nocapture
//! ```

#![cfg(feature = "experiment-015")]

#[path = "../../src/shims.rs"]
mod shims;

wat::test! { path: "wat-tests-integ/experiment/015-causal-time", deps: [shims] }
