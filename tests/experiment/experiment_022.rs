//! Opt-in slow test — experiment 022 ("Fuzzy on Both Stores").
//!
//! Proof 018. Architecture redirection (2026-04-27): drop the
//! exact-bucket bias entirely. Both stores (next-cache +
//! terminal-cache) use a single fuzzy backing — Vec of (form, value)
//! pairs scanned with `coincident?`. Cache caps at sqrt(d) entries
//! (~100 at d=10000). Byte-identical lookups hit fuzzy trivially
//! (cos=1.0); near-equivalent lookups hit too. Exact is a degenerate
//! case of fuzzy, not a separate concern.
//!
//! Six tests:
//! - T1 one walker fills both stores (next-cache + terminal-cache)
//! - T2 byte-identical hits fuzzy cleanly (degenerate coincidence)
//! - T3 near-equivalent post-β coordinate hits BOTH stores
//! - T4 distant value misses both (locality is bounded)
//! - T5 cache fills to sqrt(d) cap without neighborhood interference
//! - T6 4-tier priority (L1 terminal → L2 terminal → L1 next → L2
//!      next) routes correctly under fuzzy-only model
//!
//! Skipped by default; run with:
//!
//! ```bash
//! cargo test --release --features experiment-022 --test experiment_022 -- --nocapture
//! ```

#![cfg(feature = "experiment-022")]

#[path = "../../src/shims.rs"]
mod shims;

wat::test! { path: "wat-tests-integ/experiment/022-fuzzy-on-both-stores", deps: [shims] }
