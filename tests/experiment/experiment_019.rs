//! Opt-in slow test — experiment 019 ("Expansion Chain").
//!
//! Proof 015. Builder request: prove the substrate's two
//! lookup primitives — "next?" and "terminal?" — evolve
//! independently as evaluation progresses. The intermediate
//! state where next is known but terminal is not is the
//! load-bearing observation; this proof makes it observable.
//!
//! Six tests:
//! - T1 empty cache: both lookups None
//! - T2 INTERMEDIATE STATE: next known, terminal not
//! - T3 full chain in next-cache, no terminals yet
//! - T4 leaf terminal recognized, interior still unknown
//! - T5 terminals backpropagated, all O(1)
//! - T6 two independent chains, no interference
//!
//! Skipped by default; run with:
//!
//! ```bash
//! cargo test --release --features experiment-019 --test experiment_019 -- --nocapture
//! ```

#![cfg(feature = "experiment-019")]

#[path = "../../src/shims.rs"]
mod shims;

wat::test! { path: "wat-tests-integ/experiment/019-expansion-chain", deps: [shims] }
