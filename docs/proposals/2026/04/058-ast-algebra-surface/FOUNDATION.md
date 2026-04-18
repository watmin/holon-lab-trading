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
                (Atom 42)          ; concrete integer position
                (Atom "actions")
                (Atom 7)           ; concrete integer position
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

## Programs ARE Thoughts

A wat program is an AST. An AST is a thought. A thought has a vector projection. Therefore: **a program has a vector projection.**

```scheme
(defn hello-world [name]
  (join " " (list (Atom "Hello,") name (Atom "!"))))
```

This function definition is an AST — composed from existing core primitives (`Atom`, `Bind`, `Bundle`, and whatever specific program-form variants get added). It encodes to a deterministic 10k vector. That vector IS `hello-world`. Not a description of it. Not a serialization. The function.

### Evaluation is AST walking

Given a program AST, EXECUTE it by walking the tree with evaluation semantics. Function definitions bind a name to a closure (which is itself an AST). Function applications evaluate arguments, substitute formals, walk the body. Conditionals evaluate the test and walk the chosen branch. Literal atoms return their literal value (read from the AST node — no cleanup).

The VECTOR form exists for algebraic operations on programs — comparison, storage, similarity search, learning. The AST is where execution happens.

### What this enables

**Programs as first-class values:**

```scheme
(def f hello-world)
(eval f (list (Atom "watmin")))       ; → "Hello, watmin !"
```

**Programs in data structures:**

```scheme
(def programs
  (Map (list
    (list (Atom "greeting")   hello-world)
    (list (Atom "farewell")   goodbye-function)
    (list (Atom "risk-check") risk-function))))

(eval (get programs (Atom "risk-check")) portfolio-state)
```

**Programs compared geometrically:**

```scheme
(cosine (encode program-a) (encode program-b))
;; two programs with similar structure have similar vectors
;; the reckoner can learn which program-shapes produce Grace
```

**Programs found via engram matching:**

```scheme
;; An engram library of known-good programs:
(library-add! "compute-trail" compute-trail-ast)
(library-add! "compute-stop"  compute-stop-ast)

;; A new situation arrives. Match it against the library:
(match-library current-situation-thought)
;; → the closest known program, via cosine
```

**Programs generated from learned directions:**

```scheme
;; The reckoner learns a discriminant over program-thoughts
;; where the label is "produces Grace" or "produces Violence."
;; Decode the discriminant against candidate program ASTs
;; (cleanup against known program shapes) to get:
;;   "the program-shape that most strongly predicts Grace"
;; 
;; This is discriminant-guided program synthesis.
;; The machine writes programs that the machine evaluates.
```

### Kanerva's challenge, fully answered

Carin Meier cited Kanerva's suggestion that one could build a Lisp from hyperdimensional vectors. The full answer:

- Not "build a Lisp OUT OF vectors."
- Instead: **"build a Lisp whose ASTs project to canonical vectors."**
- The Lisp stays a Lisp. Programs are ASTs. ASTs walk for execution.
- The vector is the portable, comparable, learnable form.
- Code is data. Data has literals. Literals live on AST nodes. Programs have vectors. The machine processes all of it the same way.

### What this makes the wat machine

A wat program and a wat data structure are the same kind of thing:

- Both are ASTs
- Both encode to vectors
- Both can be stored in Maps, Arrays, or other wat thoughts
- Both can be retrieved by AST walking
- Both can be compared by cosine
- Both can be learned about by the reckoner

The machine does not distinguish "code" from "data" at its core. It processes thoughts. Thoughts are whatever we encode them to be. The machine that learns from candle data can learn from programs. The machine that generates predictions can generate programs.

This is what it means to say the wat machine is **homoiconic at 10,000 dimensions**.

### The recursion closes

- The wat machine processes thoughts.
- Programs are thoughts.
- The machine learns which thoughts (programs) produce Grace.
- The machine can generate new programs from what it learned.
- Those programs are thoughts the machine can process.
- The machine learns from programs it generated.

**Self-improvement is discriminant-guided program synthesis in hyperdimensional space.** Not gradient descent. Not backpropagation. A reckoner that learns program-shapes, a cleanup operation that materializes candidates, an evaluator that executes them. The machine writes its own replacements.

### Implications for the algebra

All existing core forms participate in program expression:

- `Atom` — names, literal values, keyword identifiers
- `Bind` — function application (role-filler), argument binding, name-to-value
- `Bundle` — sequential statements within a frame, unordered collections
- `Permute` — positional encoding
- `Sequential` (stdlib) — explicit ordered execution (evaluate left to right)
- `Thermometer`, `Blend` — scalar value expression
- `Map`, `Array` (stdlib) — data structures used by programs

Specific program-form AST variants (`Defn`, `If`, `Let`, `App`, etc.) are open questions for future proposals — they may become core variants if they need distinct evaluation semantics, or stdlib compositions if they can be expressed with existing forms.

The FOUNDATION claim here is minimal: **programs CAN be expressed using the existing primitives, and the existing primitives are sufficient to compose arbitrary program shapes.** Specialized variants for ergonomics or evaluation performance are future decisions.

---

## The Vector Side — What the Algebra Enables

Everything in the AST side — walking, exact retrieval, literal access — operates in the symbolic domain. Once a thought is projected to a vector via `encode`, **the full VSA algebra applies.** Because data is thoughts and programs are thoughts, every vector operation applies to both.

### Noise stripping reveals the signal

An `OnlineSubspace` trained on a corpus of thoughts learns the "background" — the common structural patterns that appear across many thoughts.

```scheme
(project thought subspace)    ; the component the subspace EXPLAINS (background)
(reject thought subspace)     ; the component the subspace CANNOT explain (signal)
(anomalous-component t s)     ; alias for reject — the distinctive part
```

For programs: boilerplate (common function application patterns, common literal uses, common control flow) lives in the background. What makes THIS program distinctive — its specific choices, its combinations, its particular composition — is the anomalous component. **The signal is what remains after noise is stripped.**

This is how you extract the best program from a mix. Feed a corpus of programs into a subspace. For any new program, the residual tells you what's novel. The programs with high residual are the ones that DO something — they carry signal above the baseline.

### Program similarity and search

Every geometric operation on thought vectors applies directly to program vectors:

```scheme
(cosine prog-a prog-b)            ; structural similarity of two programs

(topk-similar query corpus 5)     ; five closest programs to query

(cleanup program-vector codebook) ; the known program most similar to a vector
```

An engram library of known-good programs becomes queryable by situation:

```scheme
(match-library current-situation-thought)
;; → the program whose learned context most closely matches the situation
```

### The full algebra of programs

Every operation in the algebra ops library works on program vectors:

```scheme
(Difference prog-a prog-b)       ; what changed between two programs
(Negate prog-full prog-a)        ; prog-full WITHOUT prog-a's contribution
(Blend prog-a prog-b α)          ; interpolation between two programs
(Amplify base specific s)        ; base program with specific pattern emphasized
(Analogy prog-a prog-b prog-c)   ; A:B :: C:? — relational program transfer
(Resonance prog reference)       ; the part of prog that agrees with reference
```

Programs can be diffed. Programs can be blended. Programs can be transferred by analogy. All through vector algebra, because programs are vectors.

### Discriminant-guided program synthesis

A reckoner learns a direction in thought-space that separates Grace-producing thoughts from Violence-producing thoughts. When the thoughts are programs, the learned direction is the **signature of a program that produces Grace.**

To generate a candidate:

1. Take the reckoner's discriminant vector (the direction learned).
2. Cleanup against a codebook of candidate program ASTs.
3. The closest matches are programs most strongly predicted to produce Grace.
4. Execute them. Measure the outcome. Feed the outcome back into the reckoner.

**The machine writes its own candidate replacements.** Not through gradient descent. Not through backpropagation. Through ALGEBRAIC DECODING of a learned geometric direction against a library of candidate program structures.

### Self-reference without paradox

- The wat language expresses programs.
- Programs are thoughts.
- Thoughts have vectors.
- Vectors can be learned on (subspaces, reckoners).
- Learned directions can be decoded (cleanup against codebook).
- Decoded ASTs are executable programs.

The wat machine can RUN programs, OBSERVE which produce Grace, LEARN the discriminating direction, GENERATE new candidate programs, and RUN those. The loop closes through algebra, not through gradient descent. No paradox — the machine doesn't rewrite its own core primitives. It composes new programs from the same primitives, guided by what it learned from running previous programs.

### Why this matters for 058

The complete picture:

- **Data structures** (Map, Array, get) — store programs, retrieve them structurally, nest them arbitrarily.
- **The foundational principle** (AST primary) — exact retrieval, exact execution, literals on AST nodes.
- **Programs ARE thoughts** — the same primitives compose both data and code.
- **The vector side** (this section) — the full VSA algebra operates on any thought, including programs.

Together: the complete cycle. Store → retrieve → execute → learn → compare → generate → execute. The wat machine processes its own thinking.

**This is the recursion that the DDoS detector, the trading enterprise, and every other holon application were implicitly implementing.** 058 makes the recursion explicit as a composable algebra.

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
    (Blend (Atom :wat/std/circular-cos-basis)
           (Atom :wat/std/circular-sin-basis)
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
  ;; index-accessible list — each item bound to its position as a concrete integer atom
  ;; (Atom i) is the atom whose literal IS the integer i
  (Bundle
    (map-indexed
      (lambda (i item)
        (Bind (Atom i) item))
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

### Atom Literal Types — Use the Right Kind

Atoms accept any typed literal. **Use the literal type that matches what the thing IS**, not a keyword wrapping of it.

```scheme
;; INTEGER: use when the thing is a concrete integer.
(Atom 0)           ; position zero in an Array — zero IS an integer
(Atom 42)          ; the integer 42
(Atom -1)          ; the integer -1

;; FLOAT: use when the thing is a concrete float.
(Atom 1.6)         ; the float 1.6
(Atom 3.14159)     ; the float pi (approximate)

;; BOOLEAN: use when the thing is concretely true or false.
(Atom true)
(Atom false)

;; STRING: use when the thing IS a string literal.
(Atom "rsi")       ; the string "rsi"
(Atom "trail")     ; the string "trail"

;; KEYWORD: use when the thing is a SYMBOLIC NAME — no concrete literal form.
(Atom :wat/std/circular-cos-basis)    ; a reserved symbolic anchor
(Atom :trading/momentum-lens)          ; a named concept
(Atom :rsi)                            ; a short-form symbolic name
```

The distinction matters because atoms store their literal on the AST node:

```scheme
(atom-value (Atom 0))      ; → 0    (the integer)
(atom-value (Atom "0"))    ; → "0"  (the string)
(atom-value (Atom :pos/0)) ; → :pos/0  (the keyword)
```

These are three different things. The type-aware hash gives them three different vectors. **Pick the type that matches the semantic, not the type that wraps the semantic.**

### Reserved Keywords — The `:wat/std` Namespace

For references that ARE genuinely symbolic (no concrete literal form available), the stdlib uses keyword atoms in the `:wat/std/...` namespace:

```scheme
(Atom :wat/std/circular-cos-basis)    ; used by Circular encoder
(Atom :wat/std/circular-sin-basis)    ; used by Circular encoder
```

These are TRULY symbolic — "the cos basis vector" has no natural integer or string representation. It's just a name. Keyword is the right type.

Array position atoms are NOT in this category. Position 0 IS the integer 0. Use `(Atom 0)`, not `(Atom :pos/0)`.

**Namespace convention for symbolic keywords:**

- `:wat/std/...` — reserved for wat standard library
- Other namespaces (e.g., `:user/...`, `:trading/...`) — user code
- Bare keywords (e.g., `:rsi`) — user convenience when namespace disambiguation isn't needed

Because keywords are a first-class literal type alongside strings, integers, floats, and booleans, there is no collision risk between `(Atom 0)` and `(Atom :pos/0)` — they hash with different type tags and produce different vectors.

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

(get recent-rsi (Atom 2))          ; → (Thermometer 0.74 0 1)

;; Nested — Map of Arrays of thoughts:
(def observer-state
  (Map (list
    (list (Atom "market-readings") recent-rsi)
    (list (Atom "portfolio")       portfolio))))

(get (get observer-state (Atom "market-readings"))
     (Atom 0))                    ; → (Thermometer 0.68 0 1)

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
| 2026-04-17 | **Reserved atoms via `:wat/std` keyword namespace.** Stdlib forms that need fixed reference atoms (Circular's cos/sin basis, Array's position atoms) use namespaced keyword literals rather than special machinery. The typed-atom generalization already accepts keywords — namespaced keywords inherit determinism and uniqueness from the type-aware hash. No "reserved vector registry" needed. | 058 |
| 2026-04-17 | **Atom literal type refinement.** `(Atom 0)` is a concrete integer atom, not a keyword. Array positions use concrete integers — position 0 IS the integer 0. Keywords like `:wat/std/circular-cos-basis` are reserved for TRULY symbolic references (names with no natural concrete form). Use the literal type that matches the semantic, not a keyword that wraps it. The type-aware hash keeps `(Atom 0)`, `(Atom "0")`, and `(Atom :pos/0)` all distinct. | 058 |
| 2026-04-17 | **Programs ARE Thoughts section added.** A wat program is an AST; ASTs encode to vectors; therefore programs have vector projections. Evaluation is AST-walking. Programs can be stored in data structures, compared geometrically, retrieved from engram libraries, and generated from learned discriminants. Self-improvement becomes discriminant-guided program synthesis in hyperdimensional space. The wat machine is homoiconic at 10,000 dimensions. Kanerva's "build a Lisp from hyperdimensional vectors" challenge fully answered. | 058 |
| 2026-04-17 | **The Vector Side section added.** Because programs are thoughts and thoughts have vectors, the full VSA algebra applies to programs. Noise stripping (OnlineSubspace, reject) reveals the signal — the distinctive part of a program beyond common boilerplate. Programs can be diffed (Difference), blended, amplified, transferred by analogy. Discriminant-guided program synthesis: decode the learned Grace-direction against a program codebook via cleanup. The wat machine runs programs, observes outcomes, learns, and generates new candidate programs through pure algebra — no gradient descent. The recursion that every holon application implicitly implements. | 058 |

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
