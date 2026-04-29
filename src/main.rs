//! Phase 0 scaffold (2026-04-22) — the lab's entire Rust surface
//! is this one macro invocation. The wat tree under `wat/` carries
//! the domain; `wat/main.wat` is the entry; everything else loaded
//! recursively via arc 018's opinionated defaults
//! (source = `include_str!(<crate>/wat/main.wat)`, loader =
//! `ScopedLoader` at `<crate>/wat`).
//!
//! Deps: in-crate `shims` (CandleStream) plus the substrate's
//! `wat-telemetry-sqlite` crate (arc 091 slice 6) — schema +
//! INSERT derivation comes from the substrate's
//! `:wat::telemetry::Event` enum (Metric + Log variants), shipped
//! through `:wat::telemetry::Sqlite/auto-spawn`. The lab keeps no
//! domain-typed sqlite Rust shim of its own.

mod shims;

wat::main! { deps: [shims, wat_sqlite, wat_telemetry, wat_telemetry_sqlite] }
