//! Phase 0 scaffold (2026-04-22) — the lab's test entry. Arc 018
//! defaults: `path: "wat-tests"`, `loader: "wat-tests"` (ScopedLoader
//! rooted at `<crate>/wat-tests`). Every `.wat` file under
//! `wat-tests/` with top-level `(:wat::config::set-*!)` forms is a
//! test entry; library files loaded via `(:wat::core::load-file!)` are
//! silently skipped.
//!
//! `deps: []` for now — grows as sibling wat crates ship. The real
//! integration tests from `archived/pre-wat-native/tests/` port in
//! Phase 9.

wat::test! {}
