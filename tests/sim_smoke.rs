//! Opt-in slow test — `wat-tests-sim-smoke/`.
//!
//! Real-data parquet smoke for the simulator's lifecycle. Skipped
//! by default; run with:
//!
//! ```bash
//! cargo test --release --features sim-smoke --test sim_smoke
//! ```

#![cfg(feature = "sim-smoke")]

#[path = "../src/shims.rs"]
mod shims;

wat::test! { path: "wat-tests-sim-smoke", deps: [shims] }
