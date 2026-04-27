//! Opt-in slow test — experiment 018 ("Depth Honesty").
//!
//! Proof 014. Builder request: prove arbitrary-depth tree
//! traversal is honest as long as items-at-each-depth respect
//! Kanerva capacity. Walks 8-level paths through trees with up
//! to 99 siblings per level; verifies leaves retrievable via
//! cosine argmax.
//!
//! Six tests:
//! - T1 depth=4, width=10 (baseline)
//! - T2 depth=8, width=10 (the (x y z a b c d e) depth)
//! - T3 depth=8, width=50 (half capacity per level)
//! - T4 depth=8, width=99 (at capacity per level)
//! - T5 different trees → different leaves (independence)
//! - T6 wrong path → does NOT retrieve planted leaf (negative)
//!
//! Skipped by default; run with:
//!
//! ```bash
//! cargo test --release --features experiment-018 --test experiment_018 -- --nocapture
//! ```

#![cfg(feature = "experiment-018")]

#[path = "../../src/shims.rs"]
mod shims;

wat::test! { path: "wat-tests-integ/experiment/018-depth-honesty", deps: [shims] }
