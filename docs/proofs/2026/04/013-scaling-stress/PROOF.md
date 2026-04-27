# Proof 013 — Scaling Stress (claimed properties at the Kanerva boundary)

**Date:** opened 2026-04-26, shipped 2026-04-26.
**Status:** **SHIPPED.** Pair file at
[`wat-tests-integ/experiment/017-scaling-stress/explore-scaling.wat`](../../../../wat-tests-integ/experiment/017-scaling-stress/explore-scaling.wat).
Six tests covering width (capacity boundary), cardinality (500
distinct receipts), and depth (5-level nested forms). Total
runtime: 154ms.
**Predecessors:** proofs 005-011. The substrate's claimed
properties (Chapter 39's per-level √d capacity, Chapter 41's
word-size relation) are exercised at the boundary tonight for
the first time.
**No new substrate arcs.** Pure consumer.

---

## What this proof claims

The substrate's CLAIMED scaling properties (per BOOK chapters
39, 41, and arc 067):

- **Per-level Kanerva capacity:** `√d` items per Bundle.
- **At d=10000 (post-arc-067 default):** capacity = 100 items.
- **Beyond capacity:** capacity-mode dispatches per arc 019
  (default `:error` returns `Err(CapacityExceeded)`).
- **Discrimination at any cardinality:** distinct forms produce
  quasi-orthogonal vectors regardless of how many distinct
  receipts are in flight.
- **Depth composes:** nested HolonAST structures encode and
  verify consistently across recursion levels.

Tonight's prior proofs (005-011) used 3-100 entries per test.
None exercised the boundary. This proof verifies the substrate's
claimed scaling behavior AT the boundary.

---

## A — The three scaling dimensions

### Width (per-Bundle capacity)

The substrate enforces `√d` items per Bundle frame. Below
capacity: Bundle returns `Ok(HolonAST)`. At capacity (exactly
√d): Bundle returns `Ok` (boundary is inclusive). One above
capacity: under default `:error` mode, Bundle returns
`Err(CapacityExceeded { cost, budget })`.

Tested at d=10000 (the post-arc-067 default tier):
- T1: 10 atoms (10x under capacity) → Ok ✓
- T2: 100 atoms (exactly at capacity) → Ok ✓
- T3: 101 atoms (one over capacity) → Err ✓

The substrate honors its own claimed limit. The boundary is
crisp; no soft degradation in the legal region; immediate
error response one position past the boundary.

### Cardinality (distinct receipts in flight)

The substrate's discrimination claim says distinct forms produce
quasi-orthogonal vectors. Tonight's prior proofs verified this
across 100 forms (proof 011). This proof scales to 500.

- T4: 500 distinct receipts, each round-trips against its own
  form → 500/500 verifications succeed.
- T5: 500 distinct (F_n, F_{n+1}) pairs, cross-verify against
  the wrong form → 500/500 correctly reject.

5x the prior proof's coverage. No discrimination collapse
detected at this cardinality.

### Depth (Merkle DAG recursion)

The substrate is a content-addressed Merkle DAG (Chapter 40).
Receipts can include other receipts' bytes as sub-forms; chains
of arbitrary depth are buildable.

- T6: 5-level chain (Receipt 1 contains Receipt 2's form
  contains Receipt 3's form contains ...). Each receipt at each
  level verifies against its own form independently.

Depth composes cleanly. The substrate's recursive structure
holds at this nesting.

---

## B — Numbers

- **6 tests passing**, 0 failing
- **Total runtime**: 154ms
  - T1 width below: 4ms (1 bundle of 10)
  - T2 width at: 4ms (1 bundle of 100)
  - T3 width over: 3ms (1 bundle of 101 — Err short-circuits fast)
  - T4 cardinality round-trip: 66ms (500 issue + verify)
  - T5 cardinality rejection: 65ms (500 issue + cross-verify)
  - T6 depth: 5ms (5 nested issuances + 5 verifications)
- **All 6 tests passed first iteration.**

Per-operation cost at d=10000 ≈ 130 microseconds for issue +
verify. At 500 receipts in 66ms, the substrate sustains ~7600
verifications per second per core.

---

## C — What this verifies vs the prior proofs

| Property | Proof 011 (100 iter) | Proof 013 (this) |
|----------|----------------------|------------------|
| Round-trip | 100 forms | 500 forms |
| Distinct rejection | 100 pairs | 500 pairs |
| Self-coincidence | 100 forms | (not retested) |
| Tamper detection | 100 forms | (not retested) |
| Cross-orthogonality | 100 pairs | 500 pairs (T5) |
| Capacity boundary | (not tested) | T1 below, T2 at, T3 over |
| Depth composition | (not tested) | T6 5-level |

**New verifications in this proof:**
- Capacity boundary behavior at the substrate's claimed limit.
- 5x cardinality scaling for round-trip and rejection.
- Depth composition across 5 nested levels.

**Carried forward from proof 011:**
- Self-coincidence (no reason to re-test at higher cardinality;
  it's an algebraic identity).
- Tamper detection (orthogonal to scale; checked at proof 011's
  100 iterations).

---

## D — What this gains, what it doesn't

**What it gains:**
- Confidence in the substrate's claimed `√d` capacity bound. Not
  a chapter-narrated property; verified at the boundary on disk.
- Confidence at 5x the cardinality of the prior round-trip
  property test. No degradation observed at 500 forms in flight.
- Confidence in depth composition. The Merkle DAG isn't just an
  architectural metaphor; it actually encodes and verifies at
  multi-level depth.

**What it doesn't:**
- 500 forms is still tiny relative to the 3^10000 substrate
  state space. We sample more than before; we don't sample most
  of it.
- Depth-5 is a proof of concept. Production audit chains might
  reach hundreds of levels; this doesn't yet exercise that.
- Capacity boundary tested only at d=10000. Other tiers
  (d=256, d=4096, d=100000) not tested in this proof.
- Performance numbers are single-threaded, in-process; concurrent
  scaling is proof 018's territory.

---

## E — The thread

- Proof 005-010 — the proofs whose claims this verifies.
- Proof 011 — property tests at 100 iterations (closes "we tested 6 cases").
- Proof 012 — real-data integration (deferred — needs network access).
- **Proof 013 (this) — scaling stress at the Kanerva boundary.**
- Proof 014 — error-path exhaustion (next).
- Proof 015 — cross-proof composition (after 014).
- Proof 016 — calibration sweep (after 015).
- Proof 017 — adversarial fuzz (after 016).
- Proof 018 — concurrency stress (after 017).

Three proofs in the robustness arc shipped tonight (011, 013).
Five remain. Each closes a specific shallowness gap from the
prior proofs.

---

## F — Honest scope

This proof confirms:
- The substrate's claimed `√d = 100` per-Bundle capacity at
  d=10000.
- The substrate's claimed discrimination-at-cardinality holds
  through 500 distinct forms.
- The substrate's claimed depth composition holds through 5
  nested levels.

This proof does NOT confirm:
- Behavior at other dimension tiers (d=256, d=4096, d=100000).
- Scaling beyond 500 cardinality (10k, 100k, 1M).
- Scaling beyond depth-5 (hundreds of nested levels).
- Performance under concurrent load (proof 018).
- Behavior with adversarially-crafted forms (proof 017).
- Behavior on real-world data shapes (proof 012, deferred).

What it DOES confirm: the substrate's claimed boundaries match
its actual boundaries at d=10000, for the cardinality and depth
ranges tested. Necessary but not sufficient for production-grade
scale claims.

PERSEVERARE.
