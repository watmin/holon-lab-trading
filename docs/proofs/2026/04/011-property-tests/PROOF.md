# Proof 011 — Property Tests (closing the "we tested 6 cases" gap)

**Date:** opened 2026-04-26, shipped 2026-04-26.
**Status:** **SHIPPED.** Pair file at
[`wat-tests-integ/experiment/016-property-tests/explore-properties.wat`](../../../../wat-tests-integ/experiment/016-property-tests/explore-properties.wat).
Six property tests × 100 iterations each = 600 substrate-level
consistency checks. Total runtime: 89ms.
**Predecessors:** proofs 005-010 (the proofs whose properties are
being verified).
**No new substrate arcs.** Pure consumer.

---

## What this proof claims

The first six proofs (005-010) used hand-picked tests. Each
passed; each demonstrated the SHAPE works for the scenarios
tested. The unsampled input space was unverified.

This proof closes that gap. **Six substrate invariants verified
across 100 iterations each.** If any single iteration of any
property fails, the property is refuted — which would surface a
counterexample for the substrate's claimed behavior.

All 600 checks pass. The substrate's claimed properties hold
across the sampled input space.

---

## A — The properties

| # | Property | What it verifies |
|---|----------|------------------|
| P1 | Receipt round-trip | For all forms F, `verify(issue(F), F) = true`. The cryptographic identity of the substrate. |
| P2 | Distinct-form rejection | For all distinct (F1, F2), `verify(issue(F1), F2) = false`. The substrate doesn't false-accept. |
| P3 | Encoding determinism | For all F, two independent calls to `issue(F)` produce byte-equal receipts. The substrate is a function. |
| P4 | Self-coincidence | For all F, `coincident?(F, F) = true`. The substrate's identity predicate is reflexive. |
| P5 | Tamper detection | For all F, replacing the receipt's bytes with empty bytes makes verification fail. Tamper-evident by construction. |
| P6 | Cross-form orthogonality | For all distinct (F1, F2), `coincident?(F1, F2) = false`. Different forms occupy different shells on the algebra grid. |

Each of these was implicitly assumed by proofs 005-010. None was
explicitly verified across more than ~3 cases per proof.

---

## B — How the properties map to prior proofs

P1 (round-trip) is the load-bearing assumption of:
- Proof 005 T1 (issue + verify)
- Proof 006 T1 (happy path)
- Proof 007 T1 (happy path)
- Proof 008 T1 (sound claim)
- Proof 010 T1 (honest path)

If P1 ever fails, **every "happy path" test in tonight's prior
proofs is suspect.** Tonight's verification: 100 distinct forms,
all round-trip cleanly.

P2 (distinct-form rejection) is the load-bearing assumption of:
- Proof 005 T2 (rejects wrong form)
- Proof 006 T2 (registry tampering catches)
- Proof 007 T2 (output spoofing detected)
- Proof 008 T2-T3 (unsound claims rejected)
- Proof 010 T2-T3 (backdating / forward-dating caught)

If P2 ever false-accepts (verify returns true for the wrong form),
**every "lie detection" claim in tonight's prior proofs collapses.**
Tonight's verification: 100 pairs of distinct forms, all 100
verifications correctly returned false.

P3 (determinism) is the load-bearing assumption of:
- Proof 006 T6 (reproducible builds)
- Proof 007 T1 (binding consistency)
- Proof 010 T1 (binding sound across calls)

If P3 ever fails, the substrate's deterministic-encoding claim
is false. Tonight's verification: 100 pairs of independent
issuances, all byte-equal.

P4 (self-coincidence) is the load-bearing predicate behind:
- The chapter 28 native granularity claim
- The chapter 60 `assert-coincident` primitive
- Every proof's binding check

P5 (tamper detection) is the load-bearing assumption of:
- Proof 005 T3 (tamper-detect)
- Proof 006 T2 (registry tampering)
- Proof 007 T3 (prompt tampering)
- Proof 010 T4 (binding tamper)

If P5 ever fails (corrupted bytes verify successfully), tampering
becomes invisible. Tonight's verification: 100 receipts with
corrupted bytes, all 100 verifications correctly returned false.

P6 (cross-form orthogonality) is the substrate-level claim
underlying:
- Proof 008's argmax classification
- Proof 010's distinct receipts producing distinct V's

If P6 ever fails (distinct forms accidentally coincide), the
substrate's discrimination collapses. Tonight's verification:
100 pairs of distinct forms, all 100 correctly NOT coincident.

---

## C — Form generation strategy

The properties iterate over deterministically-generated forms,
not random ones. `gen-form(n)` produces:

```scheme
(:wat::holon::Bind
  (:wat::holon::Atom "test-form")
  (:wat::holon::leaf n))
```

Each `n` produces a structurally distinct HolonAST (because
the integer leaf differs). At the default tier (d=10000, post
arc-067), distinct leaves encode to quasi-orthogonal vectors.

**Why deterministic generation instead of random?**
- Reproducibility: same iteration count → same inputs → same
  results across runs.
- No RNG primitive needed in the substrate (which would itself
  need to be tested, regress-style).
- 100 iterations sample the input space densely enough that
  systematic substrate failures would surface.

**Limitations of this generation strategy:**
- Doesn't probe forms with similar structure but different
  values (where shell-collision would matter most).
- Doesn't probe deep recursive forms (every test form has
  arity 2).
- Doesn't probe forms near the Kanerva capacity boundary
  (sqrt(d)=100 atoms at d=10k).

These gaps are tracked for future proofs — proof 013 (scaling
stress, atoms near boundary) and proof 017 (adversarial fuzz,
worst-case form construction).

---

## D — Numbers

- **6 properties tested**
- **100 iterations per property = 600 substrate checks total**
- **Total runtime**: 89ms
- **Per-property breakdown**:
  - T1 round-trip: 19ms (100 issue + verify)
  - T2 distinct-rejection: 19ms (100 issue + cross-verify)
  - T3 determinism: 15ms (200 issuances, byte-comparison)
  - T4 self-coincident: 12ms (100 self-coincident calls)
  - T5 tamper-detect: 4ms (100 corrupted-receipt verifications)
  - T6 cross-orthogonal: 11ms (100 cross-coincident? calls)
- **All 600 checks passed** on first iteration.

---

## E — What this gains, what it doesn't

**What it gains over the prior proofs:**

- Every one of the six core substrate invariants is verified at
  100x the depth of a single hand-picked test.
- Counterexamples would be specific (the failing iteration
  index) and reproducible.
- Confidence in tonight's prior proofs (005-010) is substantively
  higher because their load-bearing assumptions are now tested
  across many inputs.

**What it doesn't yet gain:**

- True random input generation (we use deterministic
  index-derived forms).
- Counterexample shrinking (when a property fails, we know the
  failing N but don't try to minimize the input).
- Coverage across the full substrate state space (we sample 100
  points; the substrate's space is 3^10000, astronomically
  larger).
- Verification of forms NEAR the substrate's failure modes
  (capacity boundary, similar-structure collisions, etc.).

These are the gap proof 017 (adversarial fuzz) addresses —
maliciously crafted forms designed to maximize encoding noise,
trigger shell collisions, exercise edge cases. Proof 011 verifies
the easy case: ordinary forms behave as the substrate claims.
Proof 017 will verify the hard case: hostile forms still behave.

---

## F — The thread

- Proof 005-010 — the proofs whose claims this verifies.
- **Proof 011 (this) — property tests across 100 iterations per claim.**
- Proof 012 — real-data integration (closes "synthetic data" gap).
- Proof 013 — scaling stress (closes "toy data scale" gap).
- Proof 014 — error-path exhaustion (closes "no error coverage" gap).
- Proof 015 — cross-proof composition (closes "proofs sit beside each other" gap).
- Proof 016 — calibration sweep (closes "thresholds tuned to one demo" gap).
- Proof 017 — adversarial fuzz (closes "friendly inputs only" gap).
- Proof 018 — concurrency stress (closes "single-threaded" gap).

Eight proofs in a row, each closing a specific shallowness gap
in tonight's earlier work. Together they convert tonight's prior
six proofs from "good demonstrations" into "verified across the
robust input space." This proof (011) is the first.

---

## G — Honest scope

This proof confirms the substrate's claimed invariants hold
across 100 deterministic iterations of the simplest possible
forms. It does NOT confirm:

- Behavior under hostile input shapes (that's proof 017).
- Behavior at scale (that's proof 013).
- Behavior under concurrent access (that's proof 018).
- Behavior with malformed/corrupted inputs (that's proof 014).

What it DOES confirm: the substrate's deterministic, reflexive,
distinguishing behavior on ordinary forms, sampled across
~600 cases. Necessary but not sufficient for production-grade
robustness; sufficient as the first hardening pass.

PERSEVERARE.
