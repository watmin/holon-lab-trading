//! Phase 0 scaffold (2026-04-22) — the lab's entire Rust surface
//! is this one macro invocation. The wat tree under `wat/` carries
//! the domain; `wat/main.wat` is the entry; everything else loaded
//! recursively via arc 018's opinionated defaults
//! (source = `include_str!(<crate>/wat/main.wat)`, loader =
//! `ScopedLoader` at `<crate>/wat`).
//!
//! The empty `deps: []` grows as sibling wat crates ship — `wat-holon`
//! when Phase 3 (encoding) needs VSA primitives, `wat-rusqlite` when
//! Phase 5's ledger lands, etc. See `docs/rewrite-backlog.md`.

wat::main! { deps: [] }
