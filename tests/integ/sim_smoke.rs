//! Opt-in slow test — sim-smoke.
//!
//! Real-data parquet smoke for the simulator's lifecycle. Skipped
//! by default; run with:
//!
//! ```bash
//! cargo test --release --features sim-smoke --test sim_smoke
//! ```
//!
//! Wat program at `wat-tests-integ/integ/sim-smoke/sim-smoke.wat`.

#![cfg(feature = "sim-smoke")]

#[path = "../../src/shims.rs"]
mod shims;

wat::test! { path: "wat-tests-integ/integ/sim-smoke", deps: [shims] }
