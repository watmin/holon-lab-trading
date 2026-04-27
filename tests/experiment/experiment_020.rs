//! Opt-in slow test — experiment 020 ("Fuzzy Cache").
//!
//! Proof 016. Builder pushback on proof 015: the synthetic atoms
//! `(double 5)` / `(square 3)` weren't real evaluable forms, and
//! the cache was hash-keyed (exact equality only). The substrate's
//! load-bearing claim is fuzzy matching via Thermometer locality:
//! nearby scalars hit the SAME cache slot without exact equality.
//!
//! Six tests:
//! - T1 empty cache: lookup returns :None
//! - T2 exact hit: same form returns stored terminal
//! - T3 LOCALITY HIT: nearby Thermometer x hits the same slot
//! - T4 distant miss: locality is bounded, not arbitrary
//! - T5 multi-entry routing: each query finds its own neighborhood
//! - T6 trading-lab RSI demo: nearby RSI thoughts share cache
//!
//! Skipped by default; run with:
//!
//! ```bash
//! cargo test --release --features experiment-020 --test experiment_020 -- --nocapture
//! ```

#![cfg(feature = "experiment-020")]

#[path = "../../src/shims.rs"]
mod shims;

wat::test! { path: "wat-tests-integ/experiment/020-fuzzy-cache", deps: [shims] }
