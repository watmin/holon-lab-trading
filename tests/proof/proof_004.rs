//! Opt-in slow test — proof 004 ("Cache Telemetry").
//!
//! Pair file for
//! `docs/proposals/2026/04/059-the-trader-on-substrate/059-001-l1-l2-caches/DESIGN.md`
//! T7 (telemetry rows land in rundb at the gate cadence).
//!
//! ONE deftest. Spawns a real RunDbService on a new sqlite file,
//! builds a cache reporter via :trading::cache::reporter/make
//! (closure over rundb handles), spawns
//! :wat::holon::lru::HologramCacheService with that reporter +
//! a counter-based MetricsCadence (fires every 10 events), drives
//! ~30 Put/Get requests so the cadence fires three times.
//! Sentinel-passes if the lifecycle completes cleanly; the real
//! verification is the SQL query at the top of the wat source.
//!
//! Skipped by default; run with:
//!
//! ```bash
//! cargo test --release --features proof-004 --test proof_004
//! ```
//!
//! Wat program at
//! `wat-tests-integ/proof/004-cache-telemetry/004-cache-telemetry.wat`.

#![cfg(feature = "proof-004")]

#[path = "../../src/shims.rs"]
mod shims;

wat::test! {
    path: "wat-tests-integ/proof/004-cache-telemetry",
    deps: [shims, wat_lru, wat_holon_lru, wat_sqlite, wat_telemetry, wat_telemetry_sqlite]
}
