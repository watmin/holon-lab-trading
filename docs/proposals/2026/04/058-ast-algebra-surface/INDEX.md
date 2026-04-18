# 058 — Index & Reading Guide for Designers

**Purpose:** orient a first-time reviewer to the 058 batch. 30 sub-proposals, FOUNDATION, plus implementation and example docs. This index gives suggested reading order, dependency graph, and pivotal-proposal highlights.

**If you read nothing else:** start with FOUNDATION.md. It locks the criteria that every sub-proposal argues against.

---

## Document inventory

**Foundational documents** (not proposals — read first):
- `FOUNDATION.md` — the criterion for core/stdlib/language-core, the two-tier wat architecture, cryptographic provenance, Model A static loading, holographic framing
- `RUST-INTERPRETATION.md` — practical guide for implementing the wat-vm in Rust under Model A
- `HYPOTHETICAL-CANDLE-DESCRIBERS.wat` — worked example demonstrating programs-as-holons

**Sub-proposals** (30 total, each argues one form):
- Algebra core: 10 forms (primitive operations on holon vectors)
- Algebra stdlib: 17 forms (named compositions over algebra core)
- Language core: 3 forms (definition primitives that make stdlib writable)

---

## Suggested reading order

### Phase 1 — Foundation (60-90 min)

Read in order:

1. `FOUNDATION.md` from the top through the "Two Tiers of wat" section (approximately first 250 lines). This is the architectural setup: AST is primary, vector is projection, UpperCase forms construct ASTs, lowercase forms run now.

2. `FOUNDATION.md` continuing through "The Algebra Is Immutable," "Cryptographic provenance," and the content-addressed symbol table / load discussions. This is the trust model under Model A.

3. `FOUNDATION.md` ending sections: "Core/Stdlib Distinction," "Two Cores: Algebra Core and Language Core," "Criterion for Core/Stdlib/Language Core Forms." This is the bar that every sub-proposal argues against.

4. Skim `RUST-INTERPRETATION.md` for the architecture layers and data structures. Return to it later when evaluating implementation cost.

### Phase 2 — Pivotal sub-proposals (30 min)

These three are load-bearing; the rest depend on their resolution:

5. **058-002-blend** — promotes `Blend(a, b, w1, w2)` to core with two independent scalar weights. Pivotal because six stdlib forms (Difference, Amplify, Subtract, Flip, Linear, Log, Circular) become expressible only after Blend lands as core.

6. **058-001-atom-typed-literals** — generalizes `Atom` to accept any typed literal (string, int, float, bool, keyword). Required before data-structure stdlib (HashMap, Vec) can use typed keys.

7. **058-030-types** — the type system for language core. Required before `define` (058-028) and `lambda` (058-029) can have typed signatures.

### Phase 3 — Language core (20 min)

With types decided, language core slots in:

8. **058-028-define** — typed named function registration at startup.
9. **058-029-lambda** — typed anonymous functions (runtime values, not symbol-table entries).

### Phase 4 — Algebra core primitives (affirmations mostly — 20 min)

These are existing wat/holon-rs primitives receiving dedicated proposals for leaves-to-root coverage:

10. **058-021-bind** — affirms Bind as core.
11. **058-003-bundle-list-signature** — affirms Bundle as core with list signature.
12. **058-022-permute** — affirms Permute as core.
13. **058-023-thermometer** — affirms Thermometer as core.
14. **058-025-cleanup** — **REJECTED.** The AST-primary framing dissolves Cleanup; retrieval is presence measurement (cosine + noise floor), not argmax-over-codebook. Kept as audit record.

### Phase 5 — Algebra core new forms (20 min)

Genuinely new algebraic operations:

15. **058-005-orthogonalize** — `X - ((X·Y)/(Y·Y))·Y` with computed projection coefficient. Was one mode of the original Negate; the other modes became stdlib idioms.
16. **058-006-resonance** — sign-agreement mask. First core form producing ternary `{-1, 0, +1}` output.
17. **058-007-conditional-bind** — three-argument gated binding; per-dimension control.

### Phase 6 — Algebra stdlib (reframings, 15 min)

Forms that used to be HolonAST variants; reframed as stdlib over Blend:

18. **058-008-linear** — Blend over two Thermometer anchors with linear weights.
19. **058-017-log** — same skeleton, log-normalized weights.
20. **058-018-circular** — same skeleton, sin/cos weights. Proves Blend Option B's independent-weights signature.
21. **058-009-sequential-reframing** — end the grandfathered variant; Sequential becomes stdlib over Bundle and Permute.

### Phase 7 — Algebra stdlib (new compositions, 30 min)

New named compositions:

22. **058-004-difference** — `Blend(a, b, 1, -1)`, delta framing.
23. **058-015-amplify** — `Blend(x, y, 1, s)`, scaled emphasis.
24. **058-019-subtract** — `Blend(x, y, 1, -1)`, removal framing (sibling to Difference with different reader intent).
25. **058-020-flip** — `Blend(x, y, 1, -2)`, linear inversion.
26. **058-010-concurrent** — Bundle alias with temporal-co-occurrence intent.
27. **058-011-then** — binary directed temporal relation.
28. **058-012-chain** — Bundle of pairwise Thens.
29. **058-013-ngram** — n-wise adjacency, generalizing Chain.
30. **058-014-analogy** — `c + (b − a)` via Bundle + Difference.
31. **058-024-unbind** — stdlib alias for Bind with decode reader intent.

### Phase 8 — Data structures (10 min)

32. **058-016-map** — renamed to `HashMap` (2026-04-18 Rust-surface sweep). Bundle of Bind(key, value) pairs; Rust backing is `std::HashMap`. `get` returns `:Option<V>`.
33. **058-026-array** — renamed to `Vec` (2026-04-18). Integer-keyed HashMap; Rust backing is `std::Vec`. `get` with integer index returns `:Option<T>`; `nth` retired.
34. **058-027-set** — renamed to `HashSet` (2026-04-18). Bundle alias with HashSet backing; unified `get` returns `:Option<T>` on membership.

### Phase 9 — Review synthesis (30 min)

35. Re-read `FOUNDATION.md`'s "What 058 Argues" inventory section and verify it matches what you've now read.
36. Check `HYPOTHETICAL-CANDLE-DESCRIBERS.wat` as a worked example of what the final algebra looks like in use.
37. Return to `RUST-INTERPRETATION.md` to evaluate implementation cost and ordering.

**Total reading time: ~3-4 hours for a thorough first pass.**

---

## Dependency Graph (ASCII)

Shows which proposals must resolve before which others. Arrows flow from prerequisite to dependent.

```
                         FOUNDATION.md
                         (criterion + model)
                              |
              +---------------+---------------+
              |                               |
              v                               v
      [Algebra Core]                  [Language Core]
      (primitives)                    (make stdlib writable)
              |                               |
   +----------+-----------+                   |
   |          |           |                   |
   v          v           v                   |
 058-001   058-002     058-021/022/023       058-030
 Atom      Blend       Bind/Permute/Therm    types
 typed     PIVOTAL     (affirmations)        PIVOTAL
                                              |
                                              v
                                           058-028  058-029
                                           define   lambda
                                          (both typed)
                                              |
                                              v
                                     [Algebra Stdlib can be WRITTEN]


 Algebra Core depends chain:
   058-002 (Blend) ────────────┐
       │                       │
       v                       v
   058-003 (Bundle sig)     058-005 (Orthogonalize)
   058-021/022/023 (affirm) 058-006 (Resonance)
   [058-025 REJECTED]       058-007 (ConditionalBind)


 Stdlib cascades downstream of Blend:

   058-002 (Blend) ─┬─> 058-004 (Difference)
                   ├─> 058-015 (Amplify)
                   ├─> 058-019 (Subtract)
                   ├─> 058-020 (Flip)
                   ├─> 058-008 (Linear) ──┐
                   ├─> 058-017 (Log)      ├─> all need Thermometer 058-023
                   └─> 058-018 (Circular) ┘

   058-003 (Bundle sig) ──> 058-010 (Concurrent)
                         ──> 058-027 (HashSet)

   058-022 (Permute) ──> 058-009 (Sequential reframing)
                      ──> 058-011 (Then) ────> 058-012 (Chain) ──> 058-013 (Ngram)
                      ──> 058-026 (Vec) [integer-keyed HashMap]

   [058-009 Sequential and 058-026 Vec are now independent — Vec is integer-keyed HashMap, not a Sequential alias]

   058-004 (Difference) ──> 058-014 (Analogy)

   058-001 (Atom typed) ──> 058-016 (HashMap) [keys as typed atoms]

   [058-025 Cleanup REJECTED] — retrieval is presence measurement,
                                 not argmax-over-codebook. HashMap / Vec /
                                 HashSet all use unified `get` returning
                                 :Option<T> through their Rust runtime
                                 backings. Analogy's completion uses
                                 presence measurement against a candidate
                                 library.

   058-021 (Bind) ──> 058-024 (Unbind alias)
                  ──> 058-016 (HashMap)


 Language core chain:

   058-030 (types) ──> 058-028 (define)
                   ──> 058-029 (lambda)
                   ──> also: struct, enum, newtype, deftype (compile-time)
                   ──> also: load, load-types (FOUNDATION-integrated)
```

**Resolve Blend early.** It unblocks 7+ stdlib proposals and refines the algebra's shape. If Blend is rejected, several reframings revert (Linear/Log/Circular go back to CORE variants), and Difference/Amplify/Subtract/Flip re-propose as core.

**Resolve types early.** They unblock `define` and `lambda`, which together unblock the entire stdlib.

---

## What each proposal argues (at a glance)

| # | Form | Class | Status | Key argument |
|---|---|---|---|---|
| 001 | Atom typed literals | CORE | generalization | Atom accepts int/float/bool/keyword/null/string with type-aware hash |
| 002 | Blend | CORE | PIVOTAL NEW | `threshold(w1·a + w2·b)` with two independent weights |
| 003 | Bundle list signature | CORE | clarification | Lock Bundle's arg as a single list (not variadic) |
| 004 | Difference | STDLIB | reclassification | `Blend(a, b, 1, -1)`, delta framing |
| 005 | Orthogonalize | CORE | new | Projection removal with computed coefficient |
| 006 | Resonance | CORE | new | Sign-agreement mask, first ternary output |
| 007 | ConditionalBind | CORE | new | 3-arg gated binding |
| 008 | Linear | STDLIB | reframing | Blend over two Thermometer anchors |
| 009 | Sequential | STDLIB | reframing | End grandfathered variant; Bundle of Permutes |
| 010 | Concurrent | STDLIB | new alias | Bundle with temporal-intent |
| 011 | Then | STDLIB | new | Binary directed pair |
| 012 | Chain | STDLIB | new | Bundle of pairwise Thens |
| 013 | Ngram | STDLIB | new | n-wise adjacency |
| 014 | Analogy | STDLIB | new | `c + (b - a)` |
| 015 | Amplify | STDLIB | new | `Blend(x, y, 1, s)` |
| 016 | HashMap | STDLIB | new | Bundle of Bind(k, v); Rust HashMap backing |
| 017 | Log | STDLIB | reframing | Same skeleton as Linear, log-space weights |
| 018 | Circular | STDLIB | reframing | Same skeleton, sin/cos weights — tests Blend Option B |
| 019 | Subtract | STDLIB | new | `Blend(x, y, 1, -1)`, removal framing |
| 020 | Flip | STDLIB | new | `Blend(x, y, 1, -2)`, linear inversion |
| 021 | Bind | CORE | affirmation | Existing primitive, MAP's "M" |
| 022 | Permute | CORE | affirmation | Existing primitive, MAP's "P" |
| 023 | Thermometer | CORE | affirmation | Scalar-gradient primitive |
| 024 | Unbind | STDLIB | new alias | Bind alias with decode intent |
| 025 | Cleanup | REJECTED | — | Dissolved by AST-primary framing; retrieval is presence measurement, not argmax-over-codebook |
| 026 | Vec | STDLIB | new | Integer-keyed HashMap; Rust Vec backing |
| 027 | HashSet | STDLIB | new | Bundle of elements; Rust HashSet backing |
| 028 | define | LANG CORE | new | Typed named function registration |
| 029 | lambda | LANG CORE | new | Typed anonymous functions with closures |
| 030 | types | LANG CORE | new | Type system, keyword-path user types |

---

## Pivotal designer decisions

Three decisions shape everything else. Land these first in review:

1. **Accept Blend (058-002) as core with two-independent-weight signature.**
   - If yes: six stdlib forms become expressible. Linear/Log/Circular reframings proceed.
   - If no: those forms remain/become core; algebra grows more variants.

2. **Accept the type system (058-030) with required type annotations on `define` and `lambda`.**
   - If yes: define and lambda proceed as typed primitives; stdlib is writable and statically verifiable.
   - If no: need to choose between untyped stdlib (drops cryptographic-signing benefits) or some other typing scheme.

3. **Accept Model A (fully static loading) per FOUNDATION's reshape.**
   - If yes: implementation is tractable; trust boundary is startup; constrained eval at runtime.
   - If no: need to spec the dynamic model (Model B) — symbol table mutation, runtime eval of arbitrary ASTs, much larger implementation.

If these three land cleanly, the remaining 27 proposals resolve with mechanical consistency.

---

## What to flag for discussion

Specific points where designer judgment is load-bearing:

- **Naming aliases.** Bundle aliases: Bundle (primitive), Concurrent (temporal-co-occurrence intent), HashSet (data-structure intent — Rust name). HashMap and Vec are Bundle-of-Bind compositions with Rust-surface names. Is this the right granularity, or is there name bloat? Hickey round-2 flagged Concurrent vs. HashSet as a policy question — pick one alias or none.
- **Cache canonicalization.** Do stdlib calls share cache entries with their expanded form, or keep distinct names in the AST? Tooling-level decision that ripples across 058-008/017/018, 058-009, 058-010, 058-015, 058-019, 058-020, 058-024.
- **`:Any` type escape hatch.** Was considered, rejected. Heterogeneous data uses named `:Union<T,U,V>` types; generic containers use parametric `T`/`K`/`V`; atom literals use `:AtomLiteral`. Resolved in the 2026-04-18 type-grammar sweep.
- **Cryptographic primitive choice.** FOUNDATION mentions SHA-256 / BLAKE3 as options. Deployment choice, but worth naming at review.
- **Name-collision policy under Model A.** Startup halt on collision — strict — is the recommendation. Confirm no exception cases.

---

## After the review

Once designer decisions are made, implementation priorities shape up:

1. **Land types, define, lambda.** The language core must exist before stdlib can land.
2. **Land Blend.** Pivotal for stdlib cascade.
3. **Land the new algebra core (Orthogonalize, Resonance, ConditionalBind).** Small Rust changes each.
4. **Land the stdlib as real wat files.** Most proposals become small `.wat` additions once the language supports them.
5. **Reframe the existing variants.** Linear/Log/Circular/Sequential move from HolonAST variants to stdlib functions.
6. **Verify with HYPOTHETICAL-CANDLE-DESCRIBERS.wat.** When this file runs end-to-end, the 058 batch is functionally delivered.

---

**Signature:** *these are very good thoughts.* **PERSEVERARE.**
