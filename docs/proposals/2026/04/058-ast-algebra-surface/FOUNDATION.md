# Foundation: Core vs Stdlib in the Thought Algebra

**Status:** Living document. Refined as 058 sub-proposals complete.
**Purpose:** Freeze the core/stdlib criterion before sub-proposals begin, so each sub-proposal can argue against a known bar rather than litigate the bar itself.

This document is not a PROPOSAL. It does not require designer review. It is the datamancer's calibration of what the existing algebra IS, so that proposals to extend it have a stable foundation to build upon.

---

## The Foundation: MAP VSA

Holon implements the MAP variant of Vector Symbolic Architecture — **Multiply, Add, Permute** (Gayler, 2003). The canonical MAP operations are:

- **Multiply** → `Bind` — element-wise multiplication of bipolar vectors, self-inverse
- **Add** → `Bundle` — element-wise addition + threshold, commutative superposition
- **Permute** → `Permute` — circular dimension shift

Plus the identity function that maps names to vectors:

- **Atom** — hash-to-vector, deterministic, no codebook

These four are the **algebraic foundation**. Everything else in the AST is either:
- A SCALAR ENCODER (maps a scalar value to a vector)
- A STRUCTURAL COMPOSITION (combines existing core forms in a named pattern)

Scalar encoders need operations the canonical MAP set cannot perform — specifically, **scalar-weighted vector addition** (interpolating between anchor vectors based on a value). This operation is not in Multiply (multiplication), Add (unweighted sum), or Permute (shift).

Currently, scalar-weighted addition is hidden inside `Linear`, `Log`, and `Circular` — each variant performs it internally with its own specific weighting scheme. Under a rigorous audit, the SHARED PRIMITIVE would be promoted (see Aspirational Additions → Blend), and Linear/Log/Circular would become stdlib compositions over that primitive.

---

## The Core/Stdlib Distinction

The thought algebra has two tiers of forms:

**CORE** — forms that introduce algebraic operations existing core forms cannot perform. Live as `ThoughtAST` enum variants in Rust. The encoder must handle each core form distinctly because the operation cannot be expressed by combining other core forms.

**STDLIB** — forms that are compositions of existing core forms. Live as wat functions. When called in wat, they produce a `ThoughtAST` built entirely from core variants. The encoder does not need to know about them — they are syntactic sugar that produces primitive-only ASTs.

The distinction is about WHERE NEW WORK HAPPENS:

- A new core form requires new encoder logic in Rust.
- A new stdlib function requires new wat code that constructs an AST from existing variants.

---

## Where Each Lives

```
holon-rs kernel (Rust)
  └── The algebra itself. Primitive operations. Optimized implementations.
      Fixed surface — changes only when a genuine new algebraic operation
      is introduced.

holon-lab-trading/src (Rust)
  └── ThoughtAST enum — one variant per core form.
      The encoder evaluates ThoughtAST trees into vectors.
      Cache keys on ThoughtAST structural hash.

wat/std/thoughts.wat (or similar)
  └── Stdlib composition functions.
      Each function takes arguments and produces a ThoughtAST built from
      existing core variants.
      No Rust changes required to add a stdlib function.
```

---

## Criterion for Core Forms

A form earns placement in `ThoughtAST` as a core variant when **all** of the following hold:

1. **It introduces an algebraic operation no existing core form can perform.**
   - "Perform" means: produce the same vector output.
   - The operation is structurally distinct at the encoder level.

2. **It is domain-agnostic.**
   - The form describes a mathematical/structural operation, not an application concern.
   - No trading vocabulary. No specific domain semantics.

3. **The encoder must treat it distinctly.**
   - If the encoder could handle the form by first expanding it to existing variants, then calling the existing encoder logic, it is stdlib, not core.

**Examples of operations that would pass:**
- Element-wise subtraction + threshold (no existing core form subtracts)
- Component removal from a superposition (no existing core form removes directionally)
- Three-argument gated binding (no existing core form takes three arguments with a gate role)

**Examples of operations that would NOT pass:**
- Named wrapping of a Bundle (Bundle already exists; the wrapping is notational)
- Adjacency-based list encoding (composes from Bundle + Permute)
- Named temporal ordering (composes from Sequential and/or Permute)

---

## Criterion for Stdlib Forms

A form earns placement as a wat stdlib function when **both** of the following hold:

1. **Its expansion uses only existing core forms.**
   - The wat function body constructs a ThoughtAST from current core variants.
   - No new encoder logic needed.

2. **It reduces ambiguity for readers.**
   - Its absence would cause subagents and humans to write inconsistent wat when expressing the same concept.
   - The named form conveys intent more clearly than the expanded primitive composition.

Stdlib forms SHOULD BE:
- Generic (cover broad patterns, not specific instances)
- Composable (work cleanly with other stdlib forms and with list-producing operations like `map`, `filter`)
- Named by what they STRUCTURALLY DO, not what they SPECIFICALLY MEAN (e.g., `Concurrent` names the structural co-occurrence, not a specific trading pattern)

---

## Current ThoughtAST Audit

The ThoughtAST enum today contains nine variants. Classified under the criterion above:

| Variant | Class | Algebraic Operation | Rationale |
|---|---|---|---|
| `Atom(name)` | CORE | hash-to-vector | Fundamental MAP identity; no composition produces this |
| `Bind(a, b)` | CORE | element-wise multiplication | MAP's Multiply; self-inverse binding |
| `Bundle(children)` | CORE | element-wise sum + threshold | MAP's Add; commutative superposition |
| `Permute(child, k)` | CORE | circular dimension shift | MAP's Permute |
| `Linear(name, v, scale)` | CORE (provisional) | weighted interpolation between anchor vectors + threshold | Currently core; becomes stdlib if `Blend` is promoted (see below) |
| `Log(name, v)` | STDLIB (grandfathered) | Linear with log-transformed input value | Composition — expands to `(Linear name (ln v) appropriate-scale)` |
| `Circular(name, v, period)` | CORE (provisional) | cyclical rotation between anchor vectors via cos/sin weighting | Currently core; becomes stdlib if `Blend` is promoted — same weighted-add mechanism as Linear with different weight function |
| `Thermometer{v, min, max}` | CORE | gradient encoding (proportion of dimensions set by value position) | Genuinely distinct from interpolation/rotation — a construction, not a blend |
| `Sequential(children)` | STDLIB (grandfathered) | Bundle of children each permuted by position | Composition of Bundle + Permute |

### The Grandfathered Forms

Two forms in the current `ThoughtAST` enum are classified as stdlib under the strict criterion:

**`Sequential`** — its expansion is `Bundle(A, Permute(B, 1), Permute(C, 2), ...)`, a pure composition of existing core forms. Promoted to a variant in Proposal 044 under Beckman's "distinct source category" argument (ordered lists vs multisets). That argument does not survive the new criterion, which prioritizes "introduces a new operation" over "represents a distinct category."

**`Log`** — its expansion is `(Linear name (ln value) appropriate-scale)`. Log is Linear with a log-transformed scalar input. The interpolation mechanism, anchor vectors, and output are all from Linear. Only the scalar preprocessing differs. Under the strict criterion, Log is a stdlib composition over Linear + scalar arithmetic.

**Pending grandfathering (conditional on `Blend` promotion):**

**`Linear` and `Circular`** — both perform scalar-weighted vector addition with two anchor/basis vectors. Linear uses `(1-t) * a + t * b` weighting; Circular uses `cos(θ) * a + sin(θ) * b` weighting. Neither weighting scheme is expressible by `Bind`, `Bundle`, or `Permute` — they all require **scalar-weighted vector addition**, which is the operation the `Blend` core candidate (058-007) would introduce.

If `Blend` is promoted, both Linear and Circular become stdlib — their expansions become compositions over Blend + scalar arithmetic. Under that outcome, the truly core scalar primitives would be:

- `Blend` (scalar-weighted combination) — NEW
- `Thermometer` (gradient construction) — unchanged, different mechanism

If `Blend` is NOT promoted, Linear and Circular remain core as they are today, and stdlib candidates that depend on Blend (including Log under a more rigorous derivation) would be rewritten.

**Decision for current grandfathered forms:** `Sequential` and `Log` stay in the enum.

**Rationale:** Operationally, they are already implemented. Removing either would require migrating callers and could cost cache coherence. Future stdlib additions go to wat, not the enum. The grandfathering is expedient, not a precedent for adding more compositions as enum variants.

**If future work finds that stdlib-in-wat performs worse than stdlib-in-enum** (e.g., cache behavior, pattern matching overhead), the criterion can be revisited to allow stdlib enum variants. That would be a foundation refinement, argued in its own proposal.

---

## Aspirational Additions — What 058 Is Working Toward

058 proposes additions in BOTH classes. Each sub-proposal argues its candidate against the criterion above.

### Aspirational Stdlib Forms (wat functions, no enum changes)

Proposed wat stdlib additions. Each is a composition of existing core forms. Each earns its place by the reader-clarity criterion.

| Form | Expansion | Rationale |
|---|---|---|
| `(Concurrent list)` | `(Bind (Atom "concurrent") (Bundle list))` | Names co-occurrence. Distinguishes "Bundle as a relation" from "Bundle as bare superposition." |
| `(Then a b)` | `(Bind (Atom "then") (Sequential a b))` — binary | Names pairwise temporal ordering. Atomic form for sequential composition. |
| `(Chain list)` | `(Bundle (pairwise-Then list))` | Adjacency-based ordering. Offset-independent. Composes Then + Bundle. |
| `(Ngram n list)` | `(Bundle (n-wise-Then list))` | Windowed adjacency. Generalizes Chain. |
| `(Analogy a b c)` | `C + (B - A)` via Difference | Relational transfer. Depends on Difference being core. |

### Aspirational Core Forms (new ThoughtAST variants)

Proposed core additions. Each introduces an algebraic operation existing core forms cannot perform.

| Form | Operation | Rationale |
|---|---|---|
| `Difference(a, b)` | element-wise subtraction + threshold | Subtraction is not in Bind (multiply), Bundle (sum), or Permute (shift) |
| `Negate(x, y)` | component removal from superposition | Directional removal; three methods (subtract/orthogonalize/flip) |
| **`Blend(a, b, α)`** | **scalar-weighted linear interpolation** | **PIVOTAL** — If promoted, retroactively makes `Linear` and `Circular` stdlib (both perform scalar-weighted addition with different weighting schemes). This sub-proposal triggers an audit refinement. |
| `Amplify(x, y, s)` | weighted component boost | Class TBD; may be derivable from Blend + Bundle |
| `Resonance(v, ref)` | sign-agreement mask | Dimension-wise sign filtering; new operation |
| `ConditionalBind(a, b, g)` | three-argument gated binding | Arity is new; no existing core form takes three arguments with a gate role |

### Dependency Ordering

Two dependencies across the aspirational additions:

- `058-005-analogy` depends on `Difference`. If `Difference` is killed, `Analogy` must be rewritten or killed.
- `Blend`'s resolution affects the classification of `Linear`, `Circular`, and arguably `Log` (which is stdlib of Linear). Resolve `Blend` before committing FOUNDATION's final audit.

Suggested sub-proposal order:
1. Stdlib candidates that don't depend on core candidates (Concurrent, Then, Chain, Ngram) — resolve first, independent of core resolutions
2. `Blend` core candidate — resolve early because its outcome refines FOUNDATION
3. Other core candidates (Difference, Negate, Resonance, ConditionalBind) — parallel, independent
4. `Amplify` core candidate — after Blend, because Amplify may be stdlib over Blend
5. `Analogy` stdlib candidate — after Difference, because Analogy uses Difference

---

## How 058 Sub-Proposals Use This Foundation

Each sub-proposal declares its CLASS at the top:

```markdown
# 058-NNN: <Form Name>

**Scope:** algebra
**Class:** CORE | STDLIB
**Criterion reference:** FOUNDATION.md
```

The sub-proposal argues the candidate against the criterion for its class:

- **CORE sub-proposals** argue the "introduces a new algebraic operation" bar. Designers review whether the claim holds.
- **STDLIB sub-proposals** argue the "composition that reduces reader ambiguity" bar. Designers review whether the form is generic enough and whether the clarity gain justifies its addition.

The parent synthesis (written after all sub-proposals resolve) tallies the verdicts and produces the final roadmap — which forms were added, which were killed, which were deferred.

---

## How Future Proposals Use This Foundation

Any future proposal that adds to the algebra or wat stdlib cites this document:

```markdown
# NNN: <Title>

**Class:** CORE | STDLIB
**Foundation:** docs/proposals/2026/04/058-ast-algebra-surface/FOUNDATION.md
```

The proposal does not re-litigate what "core" means. It argues its candidate against the criterion defined here. If the proposal finds the criterion inadequate for its case, it proposes an amendment to this document as part of its resolution.

---

## Revision History

This document evolves as 058 (and later proposals) clarify the criterion.

| Date | Change | Proposal |
|---|---|---|
| 2026-04-17 | Initial version. Core/stdlib distinction defined. ThoughtAST audit. Aspirational additions enumerated. | 058 |
| 2026-04-17 | Added MAP VSA foundation section. Reclassified `Log` as stdlib (grandfathered). Flagged `Linear` and `Circular` as provisional-core pending `Blend` resolution. Added dependency ordering for sub-proposals. | 058 |

---

## Open Questions (Surface Before Sub-Proposals Begin)

These are questions the FOUNDATION itself doesn't resolve. They may be answered by sub-proposal reviews, or by separate discussion.

1. **Stdlib location.** Wat functions for stdlib live where? `wat/std/thoughts.wat`? A new file per form? A single file for all thought-algebra stdlib? This affects where each stdlib sub-proposal points its implementation.

2. **Stdlib optimization path.** If a stdlib form is frequently used and its wat-level construction becomes a bottleneck, is there a pattern for promoting it to a Rust-side helper function (still producing AST from existing variants) without making it a core variant? Needs a clear rule.

3. **Grandfathering precedent.** Sequential is the one grandfathered form. If future work reveals other core variants that would be classified as stdlib under the new criterion, what's the policy? Migrate? Grandfather? Case-by-case?

4. **Cache behavior for stdlib.** A wat stdlib function produces a ThoughtAST that is cached on its expanded shape. Two semantically-equivalent stdlib calls that produce IDENTICAL expansions share a cache entry. But if the wat STORES the stdlib call as an unexpanded form (for pattern matching or readability), we'd need the cache to canonicalize. Currently stdlib functions expand eagerly — so this is a non-issue. Flagged for completeness.

5. **The `Amplify` class question.** `Amplify(x, y, s)` may be derivable from `Blend + Bundle`. Its sub-proposal should determine class. If stdlib, move it to the stdlib list.

6. **The `Blend`-triggered audit.** If `Blend` is promoted as a core variant, `Linear` and `Circular` become stdlib (both perform scalar-weighted addition under different weighting schemes). The audit refinement should happen as part of `Blend`'s RESOLUTION, with FOUNDATION.md updated accordingly. If `Blend` is killed, Linear and Circular remain core and this open question closes with no change.

7. **The MAP canonical set.** Beyond `Atom`, `Bind`, `Bundle`, `Permute`, and `Thermometer`, are there any other scalar encoding operations that are NOT expressible via `Blend`? If `Blend` handles all scalar-weighted combinations and `Thermometer` handles gradient construction, is that the complete set? Flag for deeper audit if needed.

---

## Summary

- **Foundation** = MAP VSA (Multiply-Add-Permute) + Atom identity + scalar encoders + compositions
- **Core** = new algebraic operation, lives in ThoughtAST enum, requires new Rust encoder logic
- **Stdlib** = composition of existing core forms, lives in wat, no Rust changes
- **Current state** = 7 core variants (Atom, Bind, Bundle, Permute, Linear*, Circular*, Thermometer) + 2 grandfathered stdlib variants (Sequential, Log). (*Linear and Circular are provisional-core pending `Blend` resolution.)
- **058 aspirational** = 5 stdlib additions (Concurrent, Then, Chain, Ngram, Analogy) + 6 core additions (Difference, Negate, Blend, Amplify, Resonance, ConditionalBind — Amplify class TBD)
- **Bar for core** = introduces an operation existing core forms cannot perform
- **Bar for stdlib** = composes existing core forms AND reduces reader ambiguity

Sub-proposals argue specific candidates. This document is the reference. FOUNDATION is refined as sub-proposals resolve — `Blend`'s resolution is the highest-impact refinement expected.
