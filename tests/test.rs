//! Phase 0 scaffold (2026-04-22) — the lab's test entry. Arc 018
//! defaults: `path: "wat-tests"`, `loader: "wat-tests"` (ScopedLoader
//! rooted at `<crate>/wat-tests`). Every `.wat` file under
//! `wat-tests/` with top-level `(:wat::config::set-*!)` forms is a
//! test entry; library files loaded via `(:wat::load-file!)` are
//! silently skipped.
//!
//! `deps: []` for now — grows as sibling wat crates ship. The real
//! integration tests from `archived/pre-wat-native/tests/` port in
//! Phase 9.

// shims lives at `src/shims.rs`; the lab is a binary crate (no [lib]),
// so we surface the module to the test harness with `#[path]`. Same
// `wat_sources()` + `register()` contract the binary's `mod shims;`
// uses — pattern from wat-rs's USER-GUIDE.
#[path = "../src/shims.rs"]
mod shims;

wat::test! { deps: [shims, wat_lru, wat_hologram_lru] }
