# 058 — Index & Reading Guide for Designers

**Purpose:** orient a first-time reviewer to the 058 batch. 29 sub-proposals, FOUNDATION, a core-primitive audit, plus implementation and example docs. This index gives suggested reading order, dependency graph, and pivotal-proposal highlights.

**Scope grew across rounds.** The batch title says "AST algebra surface" but the work now covers substantially more: the 6-form algebra core, the measurements tier (cosine, dot), the 18-form stdlib, the 8-form language core (including parametric macros), the type system (four heads, rank-1 parametric polymorphism), the kernel primitives (queues, spawn, join, select, HandlePool, Signal), the config-setter tier (`:wat::config`), the two stdlib programs (Console, Cache), the conformance contract for programs-are-userland, the startup pipeline, the entry-file shape, the interpret path, and the compile path seed. Substrate, not just algebra. A first-time reader should expect kernel-primitives and type-system content in FOUNDATION alongside the algebra forms.

**If you read nothing else:** start with FOUNDATION.md. It locks the criteria that every sub-proposal argues against.

---

## Document inventory

**Foundational documents** (not proposals — read first):
- `FOUNDATION.md` — load-bearing contracts only. The criterion for core/stdlib/language-core, the two-tier wat architecture, cryptographic provenance, Model A static loading, output space, capacity framing, naming discipline. **Required reading.**
- `FOUNDATION-CHANGELOG.md` — audit trail of revisions to FOUNDATION. Decision, reasoning, where each change landed. Read alongside FOUNDATION when auditing a specific change.
- `CORE-AUDIT.md` — affirmation records for Bind, Permute, Thermometer. Load-bearing core primitives already in holon-rs; audit-level entries, not proposals.
- `VISION.md` — companion reading. Speculative framings: holographic/NP-hard lens, clouds-waking-up distributed cognition, lineage, metaprogramming-is-native. **Optional** — nothing in VISION is required to accept FOUNDATION.
- `RUST-INTERPRETATION.md` — practical guide for implementing the wat-vm in Rust under Model A (the INTERPRET path).
- `WAT-TO-RUST.md` — seed sketch of the COMPILE path: a Rust program consumes wat source and emits Rust source, which rustc compiles to a native binary. Two execution paths, one language. Iterate.
- `HYPOTHETICAL-CANDLE-DESCRIBERS.wat` — worked example demonstrating programs-as-holons

**Sub-proposals** (29 total, each argues one form):
- Algebra core: 7 new or reframed forms (primitive operations on holon vectors)
- Algebra stdlib: 17 forms (named compositions over algebra core)
- Language core: 5 forms (definition primitives + macros that make stdlib writable)

**Audited affirmations** (3 primitives — see CORE-AUDIT.md):
- `Bind`, `Permute`, `Thermometer` — existing holon-rs primitives; core status not in debate.

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

5. **058-002-blend** — **ACCEPTED.** `(:wat::algebra::Blend a b w1 w2)` enters algebra core with two independent real-valued scalar weights (Option B), negative weights allowed, binary arity. Unblocks Circular/Amplify/Subtract as stdlib macros. (Flip 058-020 REJECTED.) See 058-002/PROPOSAL.md's ACCEPTED banner for the per-question reasoning.

6. **058-001-atom-typed-literals** — **ACCEPTED (parametric).** `(:wat::algebra::Atom x)` accepts any serializable T — primitive, composite `:holon::HolonAST`, or user-defined type. Substrate-level: enables programs-as-atoms, engram libraries of learned programs, cryptographically-identified program storage.

7. **058-030-types** — the type system for language core. Required before `define` (058-028) and `lambda` (058-029) can have typed signatures.

### Phase 3 — Language core (25 min)

With types decided, language core slots in:

8. **058-028-define** — typed named function registration at startup.
9. **058-029-lambda** — typed anonymous functions (runtime values, not symbol-table entries).
9a. **058-031-defmacro** — compile-time syntactic expansion with Racket-style sets-of-scopes hygiene. Resolves Beckman's finding #4 (alias hash collision) by rewriting stdlib aliases to their canonical form at parse time before hashing.
9b. **058-032-typed-macros** — follow-up to 058-031 that adds `:AST<T>` and macro-authoring-time type checking. Opt-in; sharpens error locality.
9c. **058-033-try** — **INSCRIPTION (2026-04-19).** Error-propagation form. `(:wat::core::try <result-expr>)` unwraps `Ok v` to `v` or short-circuits the enclosing Result-returning function/lambda with `(Err e)`. Not try/catch — no handler block; each function declares its own Result return type and either `try`s (propagate) or `match`es (handle). The forcing function that makes Result-typed Bundle (058-003 inscription) and future Result-returning forms ergonomic. First member of the new **INSCRIPTION** status class.

### Phase 4 — Algebra core primitives (affirmations — 15 min)

Existing holon-rs primitives; core status is settled. Consult `CORE-AUDIT.md` for the short reference entries (operation, canonical form, MAP/VSA role, downstream conventions). No designer questions remain on any of these:

10. **`CORE-AUDIT.md` / Bind** — elementwise reversible combination (MAP's "M").
11. **058-003-bundle-list-signature** — affirms Bundle as core with list signature. (Substantively locks the list convention; not a pure affirmation.)
12. **`CORE-AUDIT.md` / Permute** — dimension-shuffle primitive with cyclic-shift canonical form (MAP's "P").
13. **`CORE-AUDIT.md` / Thermometer** — scalar-to-vector gradient primitive with canonical layout for distributed consensus.
14. **058-025-cleanup** — **REJECTED.** AST-primary framing dissolves Cleanup; retrieval is presence measurement (cosine + noise floor), not argmax-over-codebook. Kept as audit record of the rejection.

### Phase 5 — Algebra core new forms (20 min)

Genuinely new algebraic operations:

15. **058-005-orthogonalize** — **ACCEPTED with reframe and rename.** Ships as `Reject` + `Project` stdlib macros over Blend + `:wat::algebra::dot`. Renamed from `Orthogonalize` to `Reject` to match the primer and holon-rs (cited production use: DDoS sidecar's core detection mechanism, Challenge 010 F1=1.000). Algebra core shrinks 7 → 6 as a consequence.
16. **058-006-resonance** — **REJECTED.** Speculative, no production use. See proposal REJECTED banner.
17. **058-007-conditional-bind** — **REJECTED.** Speculative, no production use. See proposal REJECTED banner.

### Phase 6 — Algebra stdlib (reframings, 15 min)

Forms that used to be HolonAST variants; reframed as stdlib over Blend:

18. **058-008-linear** — **REJECTED** (2026-04-18). Under the new 3-arity Thermometer signature `(Thermometer value min max)`, Linear is identical to Thermometer itself. Use `Thermometer` directly. Log (058-017) and Circular (058-018) keep their stdlib slots — they demonstrate distinct transformations (log, cyclic).
19. **058-017-log** — **ACCEPTED.** Stdlib macro over Thermometer with log-transformed inputs. 15+ concrete uses across the trading-lab vocab (ROC, ATR ratios, BB width, exit excursion/age, and more).
20. **058-018-circular** — **ACCEPTED.** Stdlib macro over Blend Option B. Encodes all cyclic time components in `vocab/shared/time.rs` (minute/hour/DoW/DoM/MoY + pairwise compositions).
21. **058-009-sequential-reframing** — **ACCEPTED with reframe** (2026-04-18). Sequential becomes stdlib macro — **bind-chain with positional Permute**, not bundle-sum. Matches the primer's "positional list encoder" and the trading lab's `rhythm.rs` trigram pattern. The original bundle-sum expansion diverged from both.

### Phase 7 — Algebra stdlib (new compositions, 30 min)

New named compositions:

22. **058-004-difference** — `Blend(a, b, 1, -1)`, delta framing.
23. **058-015-amplify** — `Blend(x, y, 1, s)`, scaled emphasis.
24. **058-019-subtract** — `Blend(x, y, 1, -1)`, removal framing (sibling to Difference with different reader intent).
25. **058-020-flip** — **REJECTED.** Primer's `flip` is single-arg elementwise negation; proposal's 2-arg Flip-with-weight-`-2` is a different operation with no cited production use.
26. **058-010-concurrent** — **REJECTED** (2026-04-18). Redundant with Bundle; no runtime specialization. Enclosing context carries the temporal meaning. Kept as audit record. Userland may define it as a macro if needed.
27. **058-011-then** — **REJECTED** (2026-04-18). Arity-specialization of Sequential; no new pattern. Userland macro if desired.
28. **058-012-chain** — **REJECTED.** Redundant with Bigram (new named form under 058-013 Ngram). `Chain xs` = `Ngram 2 xs` = Bigram.
29. **058-013-ngram** — **ACCEPTED with reframe + two named shortcuts**. Ships `Ngram`, `Bigram` (= Ngram 2), `Trigram` (= Ngram 3). Uses bind-chain Sequential from the 058-009 reframe. Users write their own higher-n named macros (`:my::app::Pentagram = Ngram 5`) in their namespace.
30. **058-014-analogy** — **DEFERRED.** Proven working (classical Kanerva A:B::C:?) but not currently adopted in any application in this workspace. Proposal preserved as resumable audit record; graduates to ACCEPTED when an application demands it with citation.
31. **058-024-unbind** — **REJECTED** (2026-04-18). Identity alias for Bind; demonstrates no new pattern. Bind-on-Bind IS Unbind — a fact about the algebra, not a name worth projecting.

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
 058-001   058-002     CORE-AUDIT.md         058-030
 Atom      Blend       Bind/Permute/Therm    types
 typed     PIVOTAL     (audited)             PIVOTAL
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
   058-003 (Bundle sig)     058-005 (Reject/Project stdlib)
   CORE-AUDIT.md
   (Bind/Permute/Therm)     [058-006 Resonance — REJECTED]
                            [058-007 ConditionalBind — REJECTED]
                            [058-025 Cleanup — REJECTED]


 Stdlib cascades downstream of Blend:

   058-002 (Blend) ─┬─> 058-004 (Difference)
                   ├─> 058-015 (Amplify)
                   ├─> 058-019 (Subtract)
                   ├─> 058-008 (Linear) ──┐
                   ├─> 058-017 (Log)      ├─> all need Thermometer (audited, CORE-AUDIT.md)
                   └─> 058-018 (Circular) ┘

   [058-010 Concurrent REJECTED — redundant with Bundle]
                         ──> 058-027 (HashSet)

   Permute (audited, CORE-AUDIT.md) ──> 058-009 (Sequential reframing)
                      ──> [058-011 Then REJECTED] 058-012 (Chain inlines binary Sequential) ──> 058-013 (Ngram)
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

   [058-024 Unbind REJECTED — identity alias for Bind; userland]
                  ──> 058-016 (HashMap)


 Language core chain:

   058-030 (types) ──> 058-028 (define)
                   ──> 058-029 (lambda)
                   ──> 058-031 (defmacro) ──> 058-032 (typed-macros)
                   ──> also: struct, enum, newtype, typealias (compile-time)
                   ──> also: load, load-types (FOUNDATION-integrated)
```

**Resolve Blend early.** It unblocks 7+ stdlib proposals and refines the algebra's shape. If Blend is rejected, several reframings revert (Linear/Log/Circular go back to CORE variants), and Difference/Amplify/Subtract re-propose as core. (Flip 058-020 REJECTED.)

**Resolve types early.** They unblock `define` and `lambda`, which together unblock the entire stdlib.

---

## What each proposal argues (at a glance)

| # | Form | Class | Status | Key argument |
|---|---|---|---|---|
| 001 | Atom typed literals | CORE | generalization | Atom accepts int/float/bool/keyword/null/string with type-aware hash |
| 002 | Blend | CORE | ACCEPTED | `threshold(w1·a + w2·b)` — two independent weights, negative allowed, binary |
| 003 | Bundle list signature | CORE | clarification | Lock Bundle's arg as a single list (not variadic) |
| 004 | Difference | STDLIB | reclassification | `Blend(a, b, 1, -1)`, delta framing |
| 005 | Orthogonalize→Reject/Project | STDLIB | ACCEPTED (reframed, renamed) | Gram-Schmidt duo over Blend+dot; DDoS detection primitive |
| 006 | Resonance | REJECTED | — | Speculative, no production use beyond unit tests |
| 007 | ConditionalBind | REJECTED | — | Speculative, no production use; half-abstraction (no gate-producer) |
| 008 | Linear | REJECTED | — | Identical to Thermometer under new 3-arity signature; userland alias if desired |
| 009 | Sequential | STDLIB | reframing | End grandfathered variant; Bundle of Permutes |
| 010 | Concurrent | REJECTED | — | Bundle alias with no runtime specialization; enclosing context carries temporal meaning. Userland macro if desired. |
| 011 | Then | REJECTED | — | Arity-specialization of Sequential; userland macro |
| 012 | Chain | STDLIB | new | Bundle of pairwise Thens |
| 013 | Ngram | STDLIB | new | n-wise adjacency |
| 014 | Analogy | STDLIB | new | `c + (b - a)` |
| 015 | Amplify | STDLIB | new | `Blend(x, y, 1, s)` |
| 016 | HashMap | STDLIB | new | Bundle of Bind(k, v); Rust HashMap backing |
| 017 | Log | STDLIB | reframing | Thermometer with log-transformed inputs; distinct encoding pattern |
| 018 | Circular | STDLIB | reframing | Same skeleton, sin/cos weights — tests Blend Option B |
| 019 | Subtract | STDLIB | new | `Blend(x, y, 1, -1)`, removal framing |
| 020 | Flip | REJECTED | — | Primer's `flip` is single-arg elementwise negation; proposal's 2-arg form has no cited use; `-2` weight is magic |
| 021 | Bind | CORE | audited | See `CORE-AUDIT.md`. Existing primitive, MAP's "M" |
| 022 | Permute | CORE | audited | See `CORE-AUDIT.md`. Existing primitive, MAP's "P" |
| 023 | Thermometer | CORE | audited | See `CORE-AUDIT.md`. Scalar-gradient primitive with canonical layout |
| 024 | Unbind | REJECTED | — | Identity alias for Bind; no new pattern; userland macro |
| 025 | Cleanup | REJECTED | — | Dissolved by AST-primary framing; retrieval is presence measurement, not argmax-over-codebook |
| 026 | Vec | STDLIB | new | Integer-keyed HashMap; Rust Vec backing |
| 027 | HashSet | STDLIB | new | Bundle of elements; Rust HashSet backing |
| 028 | define | LANG CORE | new | Typed named function registration |
| 029 | lambda | LANG CORE | new | Typed anonymous functions with closures |
| 030 | types | LANG CORE | new | Type system, keyword-path user types |
| 031 | defmacro | LANG CORE | new | Compile-time syntactic expansion + Racket-style hygiene |
| 032 | typed-macros | LANG CORE | new | `:AST<T>` + macro-authoring-time type checking (extends 031) |

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

- **Naming aliases — resolved 2026-04-18.** Kept: Bundle (primitive), HashSet (data-structure, Rust-surface name, runtime backing via `:HashSet<T>` type). Rejected: Concurrent (no runtime specialization beyond Bundle; userland can define it). HashMap and Vec are Bundle-of-Bind compositions with Rust-surface names and runtime backings.
- **Cache canonicalization.** Do stdlib calls share cache entries with their expanded form, or keep distinct names in the AST? Resolved 2026-04-18 via defmacro: expansion runs at parse time BEFORE hashing, so `hash(AST) IS identity` — two source files differing only in macro aliases (e.g., `Subtract` vs `Blend(_,_,1,-1)`, or userland `Then` vs `Sequential (list a b)`) produce the same canonical AST and same hash.
- **`:Any` type escape hatch.** Was considered, rejected. Heterogeneous data uses named `:Union<T,U,V>` types; generic containers use parametric `T`/`K`/`V`; atom literals use `:AtomLiteral`. Resolved in the 2026-04-18 type-grammar sweep.
- **Cryptographic primitive choice.** FOUNDATION mentions SHA-256 / BLAKE3 as options. Deployment choice, but worth naming at review.
- **Name-collision policy under Model A.** Startup halt on collision — strict — is the recommendation. Confirm no exception cases.

---

## After the review

Once designer decisions are made, implementation priorities shape up:

1. **Land types, define, lambda.** The language core must exist before stdlib can land.
2. **Land Blend.** Pivotal for stdlib cascade.
3. **Add `:wat::algebra::dot` measurement primitive to holon-rs.** Small Rust change. (Orthogonalize reframed as stdlib Reject/Project; Resonance and ConditionalBind REJECTED.)
4. **Land the stdlib as real wat files.** Most proposals become small `.wat` additions once the language supports them.
5. **Reframe the existing variants.** Linear/Log/Circular/Sequential move from HolonAST variants to stdlib functions.
6. **Verify with HYPOTHETICAL-CANDLE-DESCRIBERS.wat.** When this file runs end-to-end, the 058 batch is functionally delivered.

---

**Signature:** *these are very good thoughts.* **PERSEVERARE.**
