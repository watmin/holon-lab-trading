# Lab arc 021 — exit/regime vocab

**Status:** opened 2026-04-24. Eighteenth Phase-2 vocab arc.
Second exit sub-tree module (after phase, arcs 019 + 020).

**Motivation.** Port `vocab/exit/regime.rs` (84L) — the regime
lens for exit observers. The archive duplicates the encoding
function in the exit namespace alongside `market/regime.rs`'s
identical implementation. The reason isn't divergent logic;
it's namespace separation so exit observers and market
observers can each dispatch through their own root.

The honest wat translation is **thin delegation**, not a copy.
One define, forwarding to the already-shipped market/regime
encoder. Same 8 atoms, same encoding, same Scales threading;
the namespace is the only thing that's new.

---

## Shape

```scheme
(:trading::vocab::exit::regime::encode-regime-holons
  (r :trading::types::Candle::Regime)
  (scales :trading::encoding::Scales)
  -> :trading::encoding::VocabEmission)
```

Single sub-struct (`Candle::Regime`, K=1) — same signature
shape as `:trading::vocab::market::regime::encode-regime-holons`
(arc 010).

Body is one call:

```scheme
(:trading::vocab::market::regime::encode-regime-holons r scales)
```

That's the entire module body. The 8 atoms (kama-er,
choppiness, dfa-alpha, variance-ratio with ReciprocalLog 10.0,
entropy-rate, aroon-up, aroon-down, fractal-dim) and their
encoding live in arc 010's file; arc 021 doesn't duplicate
them.

---

## Why delegation, not duplication

The archive's `vocab/exit/regime.rs` (84L) is a near-verbatim
copy of `vocab/market/regime.rs` (83L) — same field reads,
same normalization, same emission order, same one-sided floor.
The 1-line difference is the function name (`encode_exit_regime_facts`
vs `encode_market_regime_facts`).

Two reasons make a copy honest in Rust that don't apply here:

1. **Trait dispatch in Rust.** Different function names give
   the dispatcher (e.g., the lens system) two distinct symbols
   to route to. Wat preserves this directly — the namespaced
   path `:trading::vocab::exit::regime::encode-regime-holons`
   IS the distinct symbol; no copy needed.
2. **Future divergence in Rust.** A copy is cheap insurance
   against the day one branch needs to change without affecting
   the other. Wat's call graph is read-once: when divergence
   actually arrives, the delegating define replaces its body
   with the new logic at that point. Until then, the copy
   would be inert duplication.

Wat's namespace-as-name design makes thin delegation the
honest form. Duplicating the 8-atom encoding would create two
sources of truth for the same logic, with no compensating
benefit.

---

## Sub-fogs

- **(none).** The delegation is a one-line define; no
  composition, no helpers, no observation. Test scope is the
  contract surface (8 holons, 7 scales, coincident with
  market/regime for identical input).

---

## Non-goals

- **Move the implementation to a shared helper module.**
  Arc 010's `wat/vocab/market/regime.wat` IS the implementation;
  exit/regime delegates to it directly. No `vocab/shared/regime.wat`
  intermediary — that would be a third name for the same
  function with no caller-visible benefit.
- **Re-derive Log bounds.** ReciprocalLog 10.0 was settled in
  arc 010 via `explore-log.wat`. Exit observers see the same
  variance-ratio domain.
- **Special exit-side tests for the 8-atom values.** Those
  tests live in arc 010's `wat-tests/vocab/market/regime.wat`.
  Arc 021's tests verify the contract of the delegation
  (count, coincidence, scales-count); the inner encoding is
  arc 010's responsibility.
- **Preemptive divergence affordance.** If exit/regime ever
  needs to diverge (e.g., different floor, different bounds),
  the delegating define gets its body replaced at that point.
  Today there's nothing to diverge for.

---

## What this arc proves

That the lab can ship a vocab module whose entire content is
"forward to another module" without ceremony. The arc
discipline (DESIGN, BACKLOG, INSCRIPTION, tests) holds even
when the slice is small — every Phase-2 vocab gets its row in
the rewrite-backlog and its INSCRIPTION; small modules don't
get less rigor, just less code.

The delegation idiom likely recurs once or twice more as
exit/broker observers find market-side vocab they can reuse.
Each future delegating module ships the same shape and cites
this arc.
