# Proof 004 — Directed Evaluation (Proof of Computation)

**Date:** opened 2026-04-26, shipped 2026-04-26.
**Status:** **SHIPPED.** Pair file at
[`wat-tests-integ/experiment/009-cryptographic-substrate/explore-directed.wat`](../../../../wat-tests-integ/experiment/009-cryptographic-substrate/explore-directed.wat).
Eleven deftests (T1–T11) demonstrate the substrate's
proof-of-computation property end-to-end. Total run: 96ms across
all 11 tests.
**Predecessor:** experiment 008 (Treasury Service) ran in the same
session; the cryptographic-substrate work emerged from articulating
how the treasury's assertions and verifications would actually work.
**Unblocking arcs:**
- arc 052 (Vector type, polymorphic cosine, encode) — already shipped
- [arc 061 — vector portability](../../../arc/2026/04/061-vector-portability/INSCRIPTION.md) (vector-bytes / bytes-vector + polymorphic coincident?)
- [arc 062 — Bytes typealias](../../../arc/2026/04/062-core-bytes-alias/INSCRIPTION.md)
- [arc 063 — Bytes hex encoding](../../../arc/2026/04/063-bytes-hex/INSCRIPTION.md)
- [arc 064 — assert-eq diagnostics](../../../arc/2026/04/064-assert-eq-renders-values/INSCRIPTION.md)
- [arc 065 — honest holon constructors](../../../arc/2026/04/065-honest-holon-constructors/INSCRIPTION.md)
- [arc 066 — eval-ast! wraps HolonAST](../../../arc/2026/04/066-eval-ast-wraps-holon/INSCRIPTION.md)

Six substrate arcs shipped IN SUPPORT of this proof. The substrate
grew along with the consumer's needs — small additions, each
honest, each closing one specific gap.

---

## The claim

**The substrate exhibits proof-of-computation as a cryptographic
property.** Specifically:

1. **Forward direction (encode) is cheap.** Given a form F and a
   universe seed K, encoding F under K produces a deterministic
   vector V. Single pass over F's structural shape; constant time
   per term.
2. **Reverse direction (find F given V) is unbounded.** Many forms
   produce the same value or the same encoded vector pattern;
   recovering F from V requires search over the form space.
3. **Verification is cheap.** Given (V, K, F), re-encoding F under
   K produces V'; `coincident?(V, V')` confirms or rejects in one
   geometric comparison.
4. **Universe binding is geometric.** A vector encoded under one
   seed is operationally inert under a different seed — bytes survive
   transmission, but cosines against a fresh encoding in the wrong
   universe do not coincide.

This is the cryptographic property underlying Bitcoin's proof-of-work,
generalized: V can be ANY terminal of any deterministic computation,
not just hash output meeting a target. PoW is one application; the
substrate provides the underlying primitive.

---

## A — The substrate primitives

By the time this proof shipped, the substrate exposed:

| Op | Direction | Use |
|----|-----------|-----|
| `:wat::holon::leaf<T>` | primitive → HolonAST leaf | encode primitive values |
| `:wat::holon::from-watast` | quoted form → HolonAST tree | encode forms |
| `:wat::holon::Atom` | HolonAST → opaque-identity wrap | (back-compat polymorphic) |
| `:wat::holon::to-watast` | HolonAST → WatAST | unquote |
| `:wat::eval-ast!` | WatAST → Result<HolonAST, EvalError> | evaluate |
| `:wat::holon::encode` | HolonAST → Vector | produce the proof artifact |
| `:wat::holon::cosine` | (HolonAST \| Vector) × (HolonAST \| Vector) → f64 | geometric similarity |
| `:wat::holon::coincident?` | (HolonAST \| Vector) × (HolonAST \| Vector) → bool | yes/no equivalence |
| `:wat::holon::vector-bytes` | Vector → Bytes | serialize |
| `:wat::holon::bytes-vector` | Bytes → Option<Vector> | deserialize |
| `:wat::core::Bytes::to-hex` / `from-hex` | byte/text bridge | text-channel transport |
| `:wat::config::set-global-seed!` | (config-time) | universe selection |

The full chain: **F (HolonAST) → encode → V (Vector) → vector-bytes → Bytes → to-hex → String → transmit → from-hex → Bytes → bytes-vector → V → coincident? against fresh encode of F**.

---

## B — The eleven tests

| # | Test | Claim | Mechanism |
|---|------|-------|-----------|
| T1 | many-forms-one-value | Two distinct forms structurally differ but evaluate to the same i64 | `coincident?` on atoms returns false; round-trip via to-watast → eval-ast! → atom-value yields equal i64s |
| T2 | three-forms-one-value | Three pairwise-distinct forms all reach the same i64; structural-equality positive control (same-form-built-twice DOES coincide) | Six pairwise `coincident?` checks; three round-trip evaluations |
| T3 | universe-isolation | Same form, different seeds → different cosines | Two hermetic children with different `set-global-seed!` values; printed cosines differ |
| T4 | replay-determinism | Same form, same seed → same cosine, character-for-character | Two hermetic children with seed 42; printed cosines match exactly |
| T5 | two-factor-verification | Wrong seed AND wrong form both differ from reference | Three hermetic children: reference, wrong-seed, wrong-form; both alternatives differ |
| T6 | full-protocol | Right credentials verify; either factor wrong rejects | Four hermetic children: reference, right-creds, wrong-seed, wrong-form; explicit verified + rejected assertions |
| T7 | vector-round-trip-verify | Vector serialization is lossless; mixed-cosine API verifies | encode → bytes → bytes-vector → coincident?; mixed coincident?(form, V_imported) |
| T8 | universe-binding-via-bytes | Bytes from one universe are operationally inert in another | Two hermetic children (seed 42, seed 99) emit hex; parent decodes both and verifies seed-42 bytes match local encoding while seed-99 bytes do not |
| T9 | mixed-cosine-verification | Right form/V matches; wrong form OR wrong V rejects | Three coincident? calls with mixed HolonAST × Vector inputs |
| T10 | verify-three-factor | Single primitive composes the protocol: `verify(V_bytes, F) → bool` | Helper define + 4 cases (right; wrong form; wrong V; corrupted bytes) |
| T11 | proof-of-computation-pow-kinship | Any computation produces a verifiable artifact; near-miss forms are rejected; the form's terminal value is also computable | encode + coincident? for verify and forgery-reject; round-trip for terminal-value computation |

---

## C — Findings

### Substrate bugs surfaced (and fixed)

The proof's investigation phase exposed two real substrate bugs that
the existing tests had been hiding. Both fixed in arcs that shipped
during the proof session:

1. **Polymorphic `:wat::holon::Atom` was a "simple violation"** —
   one name covered three different operations (primitive lift,
   opaque wrap, structural lower). A test helper that called
   `atom-value` on the result of `(Atom (quote (...)))` errored
   because the result was `HolonAST::Bundle` (structural lower),
   not `HolonAST::Atom(Bundle)`. The error round-tripped through
   `eval-ast!`'s Result wrapping and the helper returned its `-1`
   sentinel. Both T1 and T2 were passing accidentally because both
   sides of `value-a == value-b` were `-1`. **Fixed by arc 065** —
   honest constructors `:wat::holon::leaf` (primitives) and
   `:wat::holon::from-watast` (quoted forms).

2. **`:wat::eval-ast!`'s scheme lied about its runtime behavior** —
   declared `Result<HolonAST, EvalError>`, returned bare `Value`
   (e.g., `Value::i64(4)` for `(+ 2 2)`). The Ok arm bound h to a
   bare i64 even though the type system thought it was HolonAST;
   `atom-value h` then runtime-rejected. **Fixed by arc 066** —
   `eval_form_ast` wraps the inner eval result as HolonAST before
   `wrap_as_eval_result`, honoring the existing scheme.

### Diagnostic gap (and fix)

Pre-arc-064, the test runner printed *"assert-eq failed"* with no
location, no actual, no expected. The proof session was unable to
diagnose T11's failure without bisection. **Arc 064 closed the
diagnostic loop** — `:wat::core::show` polymorphic renderer +
`assert-eq` reimpl that calls `show` + test-runner display of the
existing `AssertionPayload.location` (captured by arc 016 but
unused by the display layer). Post-arc-064:

```
test exp::t11-... ... FAILED
  failure: assert-eq failed
    at:       wat-tests-integ/.../explore-directed.wat:803:5
    actual:   -1
    expected: 278
```

The exact assertion site, the rendered actual (the -1 sentinel,
revealing the helper-failure-via-Err arm), and the expected.
Without arc 064, the proof would have been blocked on substrate
opacity.

### What the proof is honest about

This proof demonstrates **proof-of-computation as a cryptographic
property**. It does NOT demonstrate:

- **Encryption.** No decrypt operation; V doesn't recover F. The
  substrate cannot hide F's content from someone who has F.
- **Zero-knowledge.** Verification always requires the verifier to
  HAVE F. There's no protocol here that proves "I know F" without
  eventually showing F.
- **Classical PKI.** No algebraic key-pair generation. The seed K
  is symmetric in the sense that anyone with it can encode/verify;
  there's no derivation of a "public K" from a "private K" with
  algebraic asymmetry.

The cryptographic shapes that ARE supported:
- **Commitment-then-reveal** — Alice publishes V at time T1; reveals
  F at time T2; anyone verifies F → V; proves Alice knew F by T1.
- **Audit / provenance** — many V's recorded; auditors verify against
  later-revealed (F, K) tuples.
- **Symmetric authenticated artifacts** within trusted-K groups.

---

## D — Numbers

- **11 tests passing**, 0 failing
- **Total runtime**: 96ms across all 11 (T1-T11) on a release build
- **Hermetic-fork tests** (T3, T4, T5, T6, T8): 9-21ms each (subprocess fork dominates)
- **In-process tests** (T1, T2, T7, T9, T10, T11): 2-6ms each
- **Six substrate arcs shipped** in support: 061-066
- **wat-rs unit-test count net change** across the six arcs: 643 → 681 (+38 tests)
- **No regressions** in any wat-rs or holon-lab-trading test suite

---

## E — The thread

- Proof 001 — the machine runs (Q1 2026)
- Proof 002 — thinker baseline (single-window arithmetic)
- Proof 003 — thinker significance (multi-window sampling)
- **Proof 004 — directed evaluation (this file) — the substrate proves computation**

Each proof moves the substrate forward by demonstrating one of its
properties under load. Proof 004 is the first to demonstrate a
*cryptographic* property — the substrate's directed-graph
asymmetry from form to value/vector is the foundation any
proof-of-X system would require.

---

## F — What this enables next

After proof 004 ships:

- **Distributed lattices** — multiple wat-vm instances sharing a
  vector_manager seed inhabit the same universe; vectors transmit
  between them as bytes; verification works across machines.
- **Auditable computation logs** — record (V) entries over time; later
  reveal (F, K); auditors verify. Tamper-evident by construction.
- **Per-tenant universes** — multi-tenant systems use distinct seeds
  per tenant; geometry IS the access control.
- **Future `:wat::crypto::*`** — AEAD, signing, hashing arcs that
  layer on this substrate. Bytes-as-wire-format is established;
  text bridges (hex; future base64) shipped.

Per the user's framing in the directed-evaluation arc:

> "we can hand a program to a person.. and a vector.. but if they
> don't have the right seed... what doesn't work?... if you don't
> have all three you can't do work?..."

Three factors required for verification (V + K + F). All three
demonstrated empirically by T6, T8, T10.

> "proof of computation sounds awfully similar to proof of work"

Yes. Same cryptographic asymmetry. Different application — Bitcoin
proves search work over hash candidates; the substrate proves
deterministic computation of any form. T11 demonstrates the kinship
explicitly.

---

## G — The session

The proof shipped in a single working session 2026-04-26. The
session also produced:

- **Eight scratch beats** at `scratch/2026/04/002-directed-evaluation/`
  — the conceptual articulation that grew alongside the experiment
- **Six substrate arcs** at `wat-rs/docs/arc/2026/04/061-066/` —
  small substrate additions in support
- **Book chapter 64** — the synthesis narrative for the book
- **This proof** — the technical evidence

The substrate-and-consumer cycle worked: experiment surfaces a
need → arc DESIGN drafted → infra session ships → consumer continues.
Six arcs shipped in this single session, each ~30 minutes to ~1 hour
of focused work.

PERSEVERARE.
