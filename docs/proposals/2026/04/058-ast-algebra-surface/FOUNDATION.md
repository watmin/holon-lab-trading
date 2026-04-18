# Foundation: Core vs Stdlib in the Thought Algebra

**Status:** Living document. Refined as 058 sub-proposals complete.
**Purpose:** Freeze the core/stdlib criterion before sub-proposals begin, so each sub-proposal can argue against a known bar rather than litigate the bar itself.

This document is not a PROPOSAL. It does not require designer review. It is the datamancer's calibration of what the existing algebra IS, so that proposals to extend it have a stable foundation to build upon.

---

## The Foundational Principle

**The AST is the primary representation. The vector is its cached algebraic projection. The literal lives on the AST node.**

A thought expressed in wat exists in two equivalent forms:

- **AST form** — the structural tree (`Atom`, `Bind`, `Bundle`, `Permute`, etc.). Every node carries the information it represents. Literals (strings, numbers, booleans, keywords) are stored directly on `Atom` nodes.

- **Vector form** — the high-dimensional bipolar projection produced by `encode`. Deterministic — same AST always yields the same vector. Cached for reuse.

These are not two different things. They are the same thought seen from two perspectives:

- Use the AST for **structural operations** — walking, querying, `get`, reading literals, pattern matching.
- Use the vector for **algebraic operations** — cosine similarity, `Bind`, `Bundle`, reckoner inputs, noise subspace residuals.

`encode(ast)` projects AST → vector. The projection is one-way in the information-recovery sense (dense vector bundles produce noise on `unbind`), but the AST itself is never lost when you have it.

### Implications

**1. Literals are read from AST nodes, not recovered from vectors.**

```scheme
(atom-value (Atom 42))   → 42     ; reads the AST node's field
(atom-value (Atom "x"))  → "x"
(atom-value (Atom true)) → true
```

No cleanup. No codebook search. No cosine interpretation. The `Atom` AST node stores the literal. Reading it is field access.

**2. `get` walks the AST, not the vector.**

Given a Map AST and a key AST, find the matching pair and return its value AST. Vector-level unbind is a different operation, applicable when you have ONLY the vector (no AST context). For normal wat program operation, you always have the AST.

**3. The VectorManager's cache is memoization, not a codebook.**

It avoids recomputing `encode` for ASTs that have been seen. Same AST → same vector → reuse the cached result. The cache is an optimization inside the `encode` function, not a separate data structure that stores associations.

**4. Cleanup is rarely needed.**

The case where you have a bare vector without its AST is specialized — anomalous component analysis, discriminant decode against candidate atoms, interpreting a learned direction. For normal wat program operation, cleanup is never invoked because the AST is always available.

**5. This inverts the classical VSA framing.**

Most VSA systems treat the vector as primary and derive structure via `unbind` + `cleanup`. The wat algebra treats the AST as primary and derives the vector via `encode`. Same mathematics. Different ergonomics. Much cleaner programs.

### Kanerva's Challenge, Resolved

Carin Meier cited Kanerva's suggestion that one could build a Lisp from hyperdimensional vectors. The resolution:

- Not "build a Lisp OUT OF vectors."
- Instead: "build a Lisp whose ASTs have canonical vector projections."
- The Lisp stays a Lisp. The vector is what you get when you ask for it.
- Code is data. Data has literals. Literals live on AST nodes.

This document and the forms it defines are that Lisp. The vector algebra is how the Lisp's thoughts project into geometric space for measurement and learning. The AST is the primary representation throughout.

Every principle in the rest of this document rides on this foundation.

---

## Recursive Composition — Bounded Per Frame, Unbounded In Depth

A consequence of the foundational principle (and of MAP VSA's compositional structure) is that the algebra supports **arbitrary structural depth** within a **fixed vector dimensionality**.

### Per-frame capacity

At dimension d = 10,000, Kanerva's capacity bound gives approximately `d / (2 · ln(K))` items reliably bundled into a single vector, where K is the size of the codebook being distinguished. Practically: **~100 items per vector** can be bundled and retrieved via unbind without noise becoming catastrophic.

This is the **per-frame bound** — ~100 bindings before cosine-recovery noise degrades retrieval quality.

### Depth is free

A bundled composition's vector can itself become a VALUE in another bundle:

```scheme
(def frame-1
  (Map (list
    (list (Atom "a") v1)
    (list (Atom "b") v2)
    ;; ... up to ~100 items ...
    )))

(def frame-2
  (Map (list
    (list (Atom "inner") frame-1)   ; frame-1's structure preserved
    (list (Atom "other") v99)
    ;; ... up to ~100 more items ...
    )))
```

`encode(frame-2)` produces a 10k-dim vector. That vector HOLDS frame-1's entire structure through orthogonal composition — the inner `Bind` is quasi-orthogonal to the other 99 bindings at frame-2's level. Inner structure is preserved, not flattened.

### Capacity grows multiplicatively with depth

```
Depth 1:   100^1   =    100 items
Depth 2:   100^2   =    10,000 items
Depth 3:   100^3   =    1,000,000 items
Depth 5:   100^5   =    10,000,000,000 items
Depth 10:  100^10  =    10^20 items
```

A fixed 10k-dim substrate supports **unbounded structural capacity**. The bound is on items per frame. Depth is free.

### With AST primary, arbitrary-depth retrieval is exact

Vector-level unbind degrades at each level (noise accumulates from sibling bindings). But under the foundational principle, retrieval is AST walking — a tree traversal with no geometric degradation:

```scheme
(define (deep-get structure-ast path)
  ;; path is a list of locators, one per level
  (if (empty? path)
      structure-ast
      (deep-get (get structure-ast (first path))
                (rest path))))

;; Walk arbitrarily deep:
(deep-get deeply-nested-thing
          (list (Atom "user")
                (Atom "sessions")
                (Atom "pos/42")
                (Atom "actions")
                (Atom "pos/7")
                (Atom "metadata")))
;; → the AST node at that path. Literal intact.
```

No noise accumulation. No cleanup needed. The AST preserves depth perfectly.

### The VM framing

A wat program can be understood as a **stack of frames** — each a bundle of ≤ 100 statements, each composed into the next via Bind:

```
frame_n      — current execution frame (10k vec, ≤100 items)
  ▼
frame_n-1    — caller's frame, nested inside frame_n via Bind
  ▼
frame_n-2    — caller's caller
  ▼
...
  ▼
frame_0      — entry point
```

Each frame is a 10k-dim thought. The call stack is depth in the composition. Execution is tree-walking. Return is moving up one level via the AST.

The thought machine is **Turing-complete in this sense**: unbounded programs via unbounded composition depth, without requiring unbounded vector dimensionality. The memory IS the composition.

### Why the foundational principle matters here

Under classical VSA framing (vector primary, structure derived via `unbind` + `cleanup`), each level's unbind introduces noise. Deep structures become practically unreachable because cleanup error compounds exponentially with depth.

Under the foundational principle (AST primary, vector projection), depth is free in the structural view. You walk the tree; each level returns an AST node with its literal intact. Vector-level operations stay useful for algebraic queries (cosine, noise stripping, reckoner inputs), but they are NOT the retrieval path.

**This is why the wat algebra can encode arbitrarily nested data structures without losing them.** The AST preserves depth perfectly. The vector compresses each level into 10k dimensions for geometric operations. Together, they give you infinite structural capacity in a bounded substrate.

---

## The Foundation: MAP VSA

Holon implements the MAP variant of Vector Symbolic Architecture — **Multiply, Add, Permute** (Gayler, 2003). The canonical MAP operations are:

- **Multiply** → `Bind` — element-wise multiplication of bipolar vectors, self-inverse
- **Add** → `Bundle` — element-wise addition + threshold, commutative
- **Permute** → `Permute` — circular dimension shift

Plus the identity function that maps names to vectors:

- **Atom** — hash-to-vector, deterministic, no codebook

These four are the **algebraic foundation**. Everything else in the algebra is either:
- A SCALAR PRIMITIVE — does something MAP cannot (Thermometer, Blend)
- A NEW OPERATION — a distinct algebraic action (Difference, Negate, Resonance, ConditionalBind)
- A STDLIB COMPOSITION — a named pattern built from existing core forms

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

## Criterion for Stdlib Forms

A form earns placement as a wat stdlib function when **both** of the following hold:

1. **Its expansion uses only existing core forms.**
   - The wat function body constructs a ThoughtAST from current core variants.
   - No new encoder logic needed.

2. **It reduces ambiguity for readers.**
   - Its absence would cause subagents and humans to write inconsistent wat when expressing the same concept.
   - The named form conveys intent more clearly than the expanded primitive composition.

---

## The Algebra — Complete Forms

This section freezes the full algebra in its target shape (post-058). Core forms first, stdlib forms second. Each form shown in wat with its signature and semantics.

### Core (10 forms)

```scheme
;; --- MAP canonical ---

(Atom literal)
;; AST node storing a literal (string, int, float, bool, keyword, null).
;; Literal is READ DIRECTLY from the AST node via (atom-value ...).
;; Vector projection: deterministic bipolar vector from type-aware hash.
;;   (Atom "foo")  — string literal
;;   (Atom 42)     — integer literal
;;   (Atom 1.6)    — float literal
;;   (Atom true)   — boolean literal
;; Type-aware hash ensures (Atom 1) ≠ (Atom "1") ≠ (Atom 1.0)

(Bind a b)
;; element-wise multiplication, self-inverse
;; (Bind a (Bind a b)) = b

(Bundle list-of-thoughts)
;; list → element-wise sum + threshold
;; commutative, takes an explicit list (not variadic)

(Permute child k)
;; circular shift of dimensions by integer k

;; --- Scalar primitives ---

(Thermometer value min max)
;; gradient encoding: proportion of dimensions set to +1
;; based on (value - min) / (max - min)
;; exact cosine geometry — extremes anti-correlated

(Blend a b w1 w2)
;; scalar-weighted binary combination
;; threshold(w1·a + w2·b)
;; weights can be any real numbers (including negative)

;; --- New operations (058 candidates) ---

(Difference a b)
;; element-wise subtraction + threshold

(Negate x y mode)
;; component removal from superposition
;; mode ∈ { orthogonalize, flip }
;; "subtract" mode is a Blend idiom (not a Negate mode)

(Resonance v ref)
;; sign-agreement mask
;; keeps dimensions where v and ref agree in sign, zeros elsewhere

(ConditionalBind a b gate)
;; three-argument gated binding
;; bind a to b only at dimensions where gate permits
```

### Stdlib (11 forms)

```scheme
;; --- Scalar encoders ---

(define (Linear v scale)
  ;; value on a known bounded scale
  (Thermometer v 0 scale))

(define (Log v min max)
  ;; value spanning orders of magnitude
  (Thermometer (ln v) (ln min) (ln max)))

(define (Circular v period)
  ;; value on a cycle
  (let ((theta (* 2 pi (/ v period))))
    (Blend CIRCULAR-COS-BASIS
           CIRCULAR-SIN-BASIS
           (cos theta)
           (sin theta))))

;; --- Structural compositions ---

(define (Sequential list-of-thoughts)
  ;; positional encoding
  ;; each thought permuted by its index (Permute by 0 is identity)
  (Bundle
    (map-indexed
      (lambda (i thought) (Permute thought i))
      list-of-thoughts)))

(define (Concurrent list-of-thoughts)
  ;; named commutative relation over Bundle
  (Bind (Atom "concurrent")
        (Bundle list-of-thoughts)))

(define (Then a b)
  ;; binary directed temporal relation
  (Bind (Atom "then")
        (Sequential (list a b))))

(define (Chain list-of-thoughts)
  ;; adjacency — Bundle of pairwise Thens
  (Bundle
    (map (lambda (pair) (Then (first pair) (second pair)))
         (pairwise list-of-thoughts))))

(define (Ngram n list-of-thoughts)
  ;; n-wise adjacency — generalizes Chain
  (Bundle
    (map (lambda (window)
           (Bind (Atom "ngram")
                 (Sequential window)))
         (n-wise n list-of-thoughts))))

;; --- Weighted-combination idioms over Blend ---

(define (Amplify x y s)
  ;; boost component y in x by factor s
  (Blend x y 1 s))

(define (Subtract x y)
  ;; remove y from x at full strength
  ;; was Negate(x, y, "subtract") — now an explicit Blend idiom
  (Blend x y 1 -1))

;; --- Relational transfer ---

(define (Analogy a b c)
  ;; A is to B as C is to ?
  ;; computes C + (B - A)
  (Bundle (list c (Difference b a))))

;; --- Data structures ---

(define (Map pairs)
  ;; key-value store — pairs is a list of [key value] tuples
  ;; each pair becomes a Bind; all pairs bundled together
  (Bundle
    (map (lambda (pair)
           (Bind (first pair) (second pair)))
         pairs)))

(define (Array items)
  ;; index-accessible list — each item bound to its position atom
  ;; position atoms are deterministic (derived from index)
  (Bundle
    (map-indexed
      (lambda (i item) (Bind (Atom (str "pos/" i)) item))
      items)))

(define (Set items)
  ;; unordered collection — membership via cosine
  ;; semantically Bundle, named for reader clarity
  (Bundle items))

(define (get structure-ast locator-ast)
  ;; AST-walking access — the primary case
  ;; structure-ast is a Map / Array / nested combination (wat AST)
  ;; locator-ast is whatever thought identifies the target
  ;;
  ;; Walks the AST, finds the matching entry, returns the value AST.
  ;; No vector operation is performed. The literal stays on its AST node.
  (cond
    ((map? structure-ast)
     (find-value-by-key (pairs structure-ast) locator-ast))
    ((array? structure-ast)
     (nth (items structure-ast) (pos-atom-index locator-ast)))
    ;; ... other structural forms
    ))

(define (nth sequential-ast i)
  ;; AST indexing for Sequential or Array forms
  ;; Returns the i-th child AST directly.
  (list-ref (children sequential-ast) i))

(define (atom-value atom-ast)
  ;; Read the literal stored on an Atom AST node.
  ;; No cleanup. No codebook. No cosine. Just field access.
  (literal-field atom-ast))

;; --- Vector-level unbind (different operation, specialized cases) ---

(define (unbind-vector map-vector key-vector)
  ;; For when you have ONLY vectors (no AST context):
  ;;   - noise subspace residual
  ;;   - reckoner's learned discriminant
  ;;   - cross-system vector exchange
  ;;
  ;; Produces a noisy vector that approximates the value vector.
  ;; Pair with cleanup against a candidate set for interpretation.
  (Bind map-vector key-vector))

(define (cleanup noisy-vector candidate-asts)
  ;; Find the AST whose encoding most closely matches the noisy vector.
  ;; Used in specialized cases:
  ;;   - anomaly attribution / surprise fingerprint
  ;;   - discriminant decode
  ;;   - interpreting a learned direction against candidate atoms
  ;;
  ;; NOT used for normal structural get — that's AST walking.
  (argmax
    (map (lambda (candidate)
           (cosine noisy-vector (encode candidate)))
         candidate-asts)))
```

### Global Reference Atoms

```scheme
;; Used by stdlib scalar encoders.

(define CIRCULAR-COS-BASIS (Atom "_circular_cos_basis"))
(define CIRCULAR-SIN-BASIS (Atom "_circular_sin_basis"))
```

### Usage Examples

```scheme
;; Role-filler separation everywhere — Bind joins name-atom to value:

(Bind (Atom "rsi")   (Thermometer 0.73 0 1))
(Bind (Atom "bytes") (Log 1500 1 1000000))
(Bind (Atom "hour")  (Circular 14 24))

;; Concurrent observations:
(Concurrent
  (list
    (Bind (Atom "rsi")   (Thermometer 0.73 0 1))
    (Bind (Atom "macd")  (Thermometer -0.02 -1 1))))

;; Temporal sequence:
(Chain
  (list
    (Bind (Atom "rsi") (Thermometer 0.68 0 1))
    (Bind (Atom "rsi") (Thermometer 0.71 0 1))
    (Bind (Atom "rsi") (Thermometer 0.74 0 1))))

;; Relational verb with concurrent observations:
(Bind (Atom "diverging")
      (Concurrent
        (list
          (Bind (Atom "rsi")   (Thermometer 0.73 0 1))
          (Bind (Atom "price") (Thermometer 0.25 0 1)))))

;; --- Data structures — the unified holon data algebra ---

;; Map as key-value store:
(def portfolio
  (Map (list
    (list (Atom "USDC") (Thermometer 5000 0 10000))
    (list (Atom "WBTC") (Thermometer 0.5  0 1.0)))))

(get portfolio (Atom "USDC"))      ; → (Thermometer 5000 0 10000)

;; Array as indexed collection:
(def recent-rsi
  (Array (list
    (Thermometer 0.68 0 1)
    (Thermometer 0.71 0 1)
    (Thermometer 0.74 0 1))))

(get recent-rsi (Atom "pos/2"))    ; → (Thermometer 0.74 0 1)

;; Nested — Map of Arrays of thoughts:
(def observer-state
  (Map (list
    (list (Atom "market-readings") recent-rsi)
    (list (Atom "portfolio")       portfolio))))

(get (get observer-state (Atom "market-readings"))
     (Atom "pos/0"))              ; → (Thermometer 0.68 0 1)

;; --- The locator can be ANY thought ---

;; The key doesn't have to be a bare Atom. It can be a composite thought:

(def keyed-by-composite
  (Map (list
    (list (Concurrent (list (Atom "rsi") (Atom "overbought")))
          some-value)
    (list (Bind (Atom "macd") (Atom "crossing-up"))
          other-value))))

;; Retrieve with the same composite as locator:
(get keyed-by-composite
     (Concurrent (list (Atom "rsi") (Atom "overbought"))))
;; → some-value

;; Keys can be Maps. Values can be Maps. Arbitrary nesting:
(def wild
  (Map (list
    (list (Map (list (list (Atom "a") (Atom "b"))))    ; key IS a map
          (Array (list                                  ; value IS an array
            (Map (list (list (Atom "x") (Atom "y"))))   ; of maps
            (Atom "atom-in-the-middle")                 ; of atoms
            (Array (list (Atom "nested") (Atom "deeper")))))))) ; of arrays
```

---

## Current ThoughtAST — Reclassification Required

The `ThoughtAST` enum today contains nine variants. Reclassified against the criterion above:

| Variant | Target class | Status |
|---|---|---|
| `Atom` | CORE | stays |
| `Bind` | CORE | stays |
| `Bundle` | CORE | stays (signature clarified — takes a list) |
| `Permute` | CORE | stays |
| `Thermometer` | CORE | stays |
| `Linear` | STDLIB | expands to `(Thermometer v 0 scale)` |
| `Log` | STDLIB | expands to `(Thermometer (ln v) ln-min ln-max)` |
| `Circular` | STDLIB | expands to `Blend` with trig weights |
| `Sequential` | STDLIB | expands to `Bundle of Permute-shifted children` |

Four variants (Linear, Log, Circular, Sequential) should semantically be stdlib. The Rust enum variants currently exist for operational reasons. Migrating them is an implementation decision separate from the semantic classification — the wat algebra treats them as stdlib regardless of how the Rust enum is shaped.

**Implementation options for enum-retained stdlib:**

1. Remove the variants; all callers use wat stdlib functions that produce the expanded core forms.
2. Keep the variants as fast-path optimizations; the canonical definition lives in wat; the Rust variant is a cache-friendly representation.
3. Deprecate the variants; keep them for backwards compat but discourage new use.

The implementation choice is outside FOUNDATION's scope. FOUNDATION declares the semantic classification; the implementation proposal argues the optimal enum shape.

---

## Aspirational Additions — What 058 Is Arguing

058 proposes new forms in both classes. Each sub-proposal argues its candidate against the criterion above.

### New Core Forms (5)

```scheme
(Blend a b w1 w2)             ; scalar-weighted binary combination — PIVOTAL
(Difference a b)               ; element-wise subtraction + threshold
(Negate x y mode)              ; component removal (orthogonalize, flip)
(Resonance v ref)              ; sign-agreement mask
(ConditionalBind a b gate)     ; three-argument gated binding
```

**Blend is pivotal** — its promotion formalizes the scalar-weighted addition that Linear and Circular already perform internally, enabling their reclassification as stdlib. Blend's resolution should come early because its outcome refines the algebra.

### New Stdlib Forms (16, including reframings)

```scheme
;; Structural compositions (new):
Concurrent, Then, Chain, Ngram

;; Blend idioms (new):
Amplify, Subtract

;; Relational transfer (new):
Analogy

;; Data structures (new — the holon data algebra):
Map, Array, Set, get, nth

;; Scalar encoder reframings (from enum-retained stdlib):
Linear, Log, Circular

;; Structural reframing (from enum-retained stdlib):
Sequential
```

### Dependency Ordering

- `Blend`'s resolution affects Linear, Log, Circular, Amplify, Subtract classifications — resolve early.
- `Difference`'s resolution affects Analogy's viability — resolve before Analogy.
- `Negate`'s "subtract" mode is subsumed by Blend — Negate sub-proposal should scope to orthogonalize + flip only.

---

## How 058 Sub-Proposals Use This Foundation

Each sub-proposal declares its CLASS at the top:

```markdown
# 058-NNN: <Form Name>

**Scope:** algebra
**Class:** CORE | STDLIB
**Criterion reference:** FOUNDATION.md
```

- **CORE sub-proposals** argue the "introduces a new algebraic operation" bar.
- **STDLIB sub-proposals** argue the "composition reduces reader ambiguity" bar.

The parent synthesis (written after all sub-proposals resolve) tallies the verdicts and produces the final roadmap.

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

| Date | Change | Proposal |
|---|---|---|
| 2026-04-17 | Initial version. Core/stdlib distinction defined. ThoughtAST audit. Aspirational additions enumerated. | 058 |
| 2026-04-17 | Added MAP VSA foundation section. Reclassified `Log` as stdlib. Flagged `Linear` and `Circular` as provisional-core pending `Blend` resolution. | 058 |
| 2026-04-17 | Full algebra freeze. Sequential, Linear, Log, Circular committed as stdlib with real wat definitions. Bundle takes a list (not variadic). Amplify and Subtract added as Blend idioms in stdlib. Negate scoped to orthogonalize+flip only (subtract becomes Blend idiom). Complete wat forms section added. | 058 |
| 2026-04-17 | Data structure stdlib added — Map, Array, Set, get, nth. Unified access: `(get structure locator)` via Bind's self-inverse works for maps, arrays, and arbitrary nesting. Locators can be any thought (atoms, maps, arrays, nested compositions). This is the holon data algebra made explicit as wat stdlib. | 058 |
| 2026-04-17 | **The Foundational Principle** added as top-level framing: AST is primary, vector is cached algebraic projection, literals live on AST nodes. Reframes `get` as AST-walking (not vector-unbinding), `atom-value` as direct AST field access, cleanup as a specialized operation for when AST context is lost. Atom generalized to accept typed literals (string, int, float, bool, keyword). Inverts classical VSA framing: the Lisp is primary, the vector is what you get when you ask for it. Resolves Kanerva's "build a Lisp from hyperdimensional vectors" challenge. | 058 |
| 2026-04-17 | **Recursive Composition section added.** Capacity bounded per frame (~100 items at 10k dims), unbounded in depth. Compositions nest: `encode(frame-with-nested-frame)` preserves inner structure through orthogonal bind. `deep-get` walks arbitrary depth with no noise accumulation. The thought machine is Turing-complete via unbounded composition depth within a fixed vector dimensionality — memory IS the composition. | 058 |

---

## Open Questions

1. **Stdlib location.** Wat functions for stdlib live where? `wat/std/thoughts.wat`? A new file per form? A single file for all thought-algebra stdlib?

2. **Stdlib optimization path.** If a stdlib form is frequently used and its wat-level construction becomes a bottleneck, is there a pattern for promoting it to a Rust-side helper function (still producing AST from existing variants) without making it a core variant?

3. **Enum-retained stdlib policy.** Linear, Log, Circular, Sequential are semantically stdlib but currently live in the ThoughtAST enum. Decision needed: remove the variants, keep them as fast paths, or deprecate them. This is an implementation concern outside FOUNDATION's scope, but the policy should be set.

4. **Cache behavior for stdlib.** A wat stdlib function produces a ThoughtAST that is cached on its expanded shape. If two semantically-equivalent stdlib calls produce identical expansions, they share a cache entry. If the wat STORES the stdlib call as an unexpanded form, canonicalization is needed.

5. **Ngram's `n` parameter handling.** `Ngram` takes a numeric argument alongside the list. Its expansion depends on `n`. Decide whether `n` participates in the cache key or whether different `n` values always produce different AST structures.

6. **The MAP canonical set completeness.** Beyond `Atom`, `Bind`, `Bundle`, `Permute`, `Thermometer`, and `Blend`, are there any other scalar encoding operations that cannot be expressed via these? If `Blend` handles all scalar-weighted combinations and `Thermometer` handles gradient construction, is that the complete set of scalar primitives?

---

## Summary

- **Foundation** = MAP VSA (Multiply-Add-Permute) + Atom identity + scalar primitives (Thermometer, Blend) + new operations (Difference, Negate, Resonance, ConditionalBind)
- **Core** = new algebraic operation, lives in ThoughtAST enum, requires new Rust encoder logic
- **Stdlib** = composition of existing core forms, lives in wat, no Rust changes
- **Target state** = 10 core + 16 stdlib
- **Currently in enum that should become stdlib** = Linear, Log, Circular, Sequential (implementation path separate)
- **Bar for core** = introduces an operation existing core forms cannot perform
- **Bar for stdlib** = composes existing core forms AND reduces reader ambiguity

Sub-proposals argue specific candidates. This document is the reference. FOUNDATION is refined as sub-proposals resolve — `Blend`'s resolution is the highest-impact refinement expected.
