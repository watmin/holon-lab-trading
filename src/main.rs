//! Phase 0 scaffold (2026-04-22) — the lab's entire Rust surface
//! is this one macro invocation. The wat tree under `wat/` carries
//! the domain; `wat/main.wat` is the entry; everything else loaded
//! recursively via arc 018's opinionated defaults
//! (source = `include_str!(<crate>/wat/main.wat)`, loader =
//! `ScopedLoader` at `<crate>/wat`).
//!
//! Deps: in-crate `shims` (CandleStream) plus the substrate
//! `wat-sqlite` crate (arcs 083 / 084 / 085) for sqlite-backed
//! telemetry. The lab's enum decl in `wat/io/log/LogEntry.wat`
//! drives schema + INSERT derivation through
//! `:wat::std::telemetry::Sqlite/auto-spawn` — no domain-typed
//! sqlite Rust shim of our own.

mod shims;

wat::main! { deps: [shims, wat_sqlite] }
