//! Opt-in slow test — experiment 008 ("Treasury Program").
//!
//! Pair file for `docs/experiments/2026/04/008-treasury-program/EXPERIMENT.md`.
//! ONE deftest spawns a synthetic single-broker treasury via
//! `:trading::treasury::Service`, fires hand-crafted SubmitPaper +
//! SubmitExit + Tick events, observes responses, lets per-Tick +
//! per-Request telemetry land in `runs/exp-008-<epoch>.db` for
//! SQL inspection.
//!
//! Skipped by default; run with:
//!
//! ```bash
//! cargo test --release --features experiment-008 --test experiment_008 -- --nocapture
//! ```
//!
//! Wat program at
//! `wat-tests-integ/experiment/008-treasury-program/explore-treasury.wat`.

#![cfg(feature = "experiment-008")]

#[path = "../../src/shims.rs"]
mod shims;

wat::test! { path: "wat-tests-integ/experiment/008-treasury-program", deps: [shims] }
