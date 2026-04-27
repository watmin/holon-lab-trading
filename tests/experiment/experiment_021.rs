//! Opt-in slow test — experiment 021 ("Fuzzy Locality").
//!
//! Proof 017. Sibling to proof 016 v4 (which keyed the dual-LRU
//! cache by exact HolonAST identity). This proof keys by
//! `:wat::holon::coincident?` — the substrate's algebra-grid
//! "same point within sigma" predicate. Forms whose scalar args
//! are wrapped in Thermometer (locality-preserving) hit the same
//! cache slot when their values are nearby; forms whose scalar
//! args are bare F64 leaves (quasi-orthogonal) do not.
//!
//! Six tests:
//! - T1 walker reaches expected terminal for (:my::indicator 1.95)
//! - T2 THE FUZZY HIT: 2.05's walk inherits 1.95's work via coincident?
//! - T3 distant value (8.5) misses fuzzy; computes its own chain
//! - T4 post-β coordinates ARE coincident (the substrate-level claim)
//! - T5 pre-β coordinates are NOT coincident (holographic-depth claim:
//!      F64 leaves are quasi-orthogonal; fuzziness emerges deeper)
//! - T6 N walkers populate neighborhoods; near hits, far misses
//!
//! Skipped by default; run with:
//!
//! ```bash
//! cargo test --release --features experiment-021 --test experiment_021 -- --nocapture
//! ```

#![cfg(feature = "experiment-021")]

#[path = "../../src/shims.rs"]
mod shims;

wat::test! { path: "wat-tests-integ/experiment/021-fuzzy-locality", deps: [shims] }
