# Foundation: Core vs Stdlib in the Holon Algebra

**Status:** Living document. Refined as 058 sub-proposals complete.
**Purpose:** Freeze the core/stdlib criterion before sub-proposals begin, so each sub-proposal can argue against a known bar rather than litigate the bar itself.

This document is not a PROPOSAL. It does not require designer review. It is the datamancer's calibration of what the existing algebra IS, so that proposals to extend it have a stable foundation to build upon.

---

## The Foundational Principle

**The AST is the primary representation. The vector is its cached algebraic projection. The literal lives on the AST node.**

A holon expressed in wat exists in two equivalent forms:

- **AST form** — the structural tree (`Atom`, `Bind`, `Bundle`, `Permute`, etc.). Every node carries the information it represents. Literals (strings, numbers, booleans, keywords) are stored directly on `Atom` nodes.

- **Vector form** — the high-dimensional bipolar projection produced by `encode`. Deterministic — same AST always yields the same vector. Cached for reuse.

These are not two different things. They are the same holon seen from two perspectives:

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

Given a HashMap AST and a key AST, find the matching pair and return its value AST. Vector-level unbind is a different operation, applicable when you have ONLY the vector (no AST context). For normal wat program operation, you always have the AST.

**3. The VectorManager's cache is memoization, not a codebook.**

It avoids recomputing `encode` for ASTs that have been seen. Same AST → same vector → reuse the cached result. The cache is an optimization inside the `encode` function, not a separate data structure that stores associations.

**4. Cleanup is not part of the algebra.**

Cleanup is the vector-primary tradition's answer to "given a noisy vector, which named thing is this?" That question presupposes you threw away the structure. In the wat algebra, the AST is primary and the structure is never thrown away. The retrieval primitive is cosine against the encoded target, with the substrate's noise floor as the threshold — not argmax-over-codebook. See "Presence is Measurement, Not Verdict" below.

**5. This inverts the classical VSA framing.**

Most VSA systems treat the vector as primary and derive structure via `unbind` + `cleanup`. The wat algebra treats the AST as primary and derives the vector via `encode`. Same mathematics. Different ergonomics. Much cleaner programs — and one fewer primitive.

### Kanerva's Challenge, Resolved

Carin Meier cited Kanerva's suggestion that one could build a Lisp from hyperdimensional vectors. The resolution:

- Not "build a Lisp OUT OF vectors."
- Instead: "build a Lisp whose ASTs have canonical vector projections."
- The Lisp stays a Lisp. The vector is what you get when you ask for it.
- Code is data. Data has literals. Literals live on AST nodes.

This document and the forms it defines are that Lisp. The vector algebra is how the Lisp's holons project into geometric space for measurement and learning. The AST is the primary representation throughout.

Every principle in the rest of this document rides on this foundation.

---

## Two Tiers of wat — Primitives and Holons

The foundational principle (AST is primary, vector is cached projection) manifests concretely as **two tiers of forms in the wat language**. These tiers are syntactically distinct, semantically distinct, and serve complementary roles.

### The lowercase tier — Rust primitives

Lowercase forms are **Rust operations**. They execute immediately when invoked. They take values and return values. They do not construct ASTs; they DO the work.

```scheme
(atom "rsi")          ; Rust: seed a vector from the name "rsi" — returns Vector
(bind v1 v2)          ; Rust: elementwise product of two vectors — returns Vector
(bundle v1 v2 v3)     ; Rust: thresholded sum — returns Vector
(cosine v1 v2)        ; Rust: dot product / norms — returns f64
(blend v1 v2 0.3)     ; Rust: weighted interpolation — returns Vector
```

Everything in `wat/core/primitives.wat` and `wat/std/vectors.wat` is lowercase. These are the **machine's reflexes** — the fast compiled operations that cost microseconds and return immediately.

### The UpperCase tier — AST constructors

UpperCase forms are **AST constructors**. They do NOT run. They build `HolonAST` nodes — descriptions of a holon-composition that can be encoded to a vector, cached, hashed, signed, transmitted, or deferred.

```scheme
(Atom "rsi")              ; AST: a node representing "name this concept" — returns HolonAST
(Bind role filler)        ; AST: a node representing binding — returns HolonAST
(Bundle holons)           ; AST: a node representing superposition — returns HolonAST
(Blend a b 1 -1)          ; AST: a node representing scalar-weighted combine — returns HolonAST
(Sequential (list a b))   ; AST: a node representing position-encoded bundle — returns HolonAST
```

The UpperCase forms are what users and stdlib WRITE in wat programs. They compose cheaply — building a nested AST is structural work, no vector computation. The VECTOR materializes only when the AST is **realized** (see "Executable semantics" below).

### Why the tier split

Three reasons the tier split is load-bearing:

**1. Laziness.** UpperCase forms compose holon-programs without paying encoding cost. `(Sequential (list (Atom "a") (Atom "b")))` constructs a small AST. The vectors for the Atoms, the permutation for Sequential, the bundle — none of these compute until the AST is projected. Cache-friendly, transmission-friendly, sign-friendly.

**2. Cryptographic identity.** A `HolonAST` serializes to EDN and hashes to a stable identifier. A vector is the projection of an AST; the AST's hash IS the holon's identity. Two holons with the same AST have the same hash. Two holons with different ASTs — even if their vectors collide under some coincidence — are DIFFERENT holons. The AST carries identity; the lowercase primitives cannot.

**3. User-writable stdlib.** The `(define ...)` forms in stdlib like:

   ```scheme
   (define (Difference a b) : Holon
     (Blend a b 1 -1))
   ```

   compose UpperCase forms. The body is an AST-construction expression. Callers of `Difference` get a HolonAST back. Only when something asks for the vector does the encoder walk the AST and invoke lowercase primitives.

### The relationship between tiers

UpperCase calls lowercase internally, but only at REALIZATION time. The encoder walks an UpperCase AST; at each node it dispatches to the matching lowercase primitive:

```
(Bundle (list (Bind (Atom "r") (Atom "v"))
              (Bind (Atom "s") (Atom "w"))))

     AST walking by encoder →

   bundle(
     bind(atom("r"), atom("v")),
     bind(atom("s"), atom("w"))
   )
```

The lowercase `atom`, `bind`, `bundle` run fast. They are the reflexes. The UpperCase AST is the **plan**. Realization is invocation.

### Why the UpperCase names matter

The UpperCase naming is intentional. It communicates to the reader: "this expression does not run now; it constructs an AST that will be realized later." A wat programmer who sees `(Bind ...)` knows they are building a description. If they see `(bind ...)` they know they are running a Rust primitive immediately.

The visual distinction matches the semantic distinction. Lowercase is the substrate. UpperCase is the language of holons.

### What this section adds to the foundational principle

The foundational principle says **AST is primary, vector is cached projection**. This section adds:

- The UpperCase tier IS the AST-constructing surface of wat.
- The lowercase tier IS the Rust primitive surface.
- Users write UpperCase. Encoders realize via lowercase.
- Stdlib is `(define ...)` over UpperCase expressions.
- Every principle in the rest of this document — cache as memory, engram libraries, programs-as-holons, cryptographic provenance, distributed verifiability — operates on UpperCase ASTs.

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
  (HashMap (list
    (list (Atom "a") v1)
    (list (Atom "b") v2)
    ;; ... up to ~100 items ...
    )))

(def frame-2
  (HashMap (list
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

Each frame is a 10k-dim holon. The call stack is depth in the composition. Execution is tree-walking. Return is moving up one level via the AST.

The holon machine is **Turing-complete in this sense**: unbounded programs via unbounded composition depth, without requiring unbounded vector dimensionality. The memory IS the composition.

### Why the foundational principle matters here

Under classical VSA framing (vector primary, structure derived via `unbind` + `cleanup`), each level's unbind introduces noise. Deep structures become practically unreachable because cleanup error compounds exponentially with depth.

Under the foundational principle (AST primary, vector projection), depth is free in the structural view. You walk the tree; each level returns an AST node with its literal intact. Vector-level operations stay useful for algebraic queries (cosine, noise stripping, reckoner inputs), but they are NOT the retrieval path.

**This is why the wat algebra can encode arbitrarily nested data structures without losing them.** The AST preserves depth perfectly. The vector compresses each level into 10k dimensions for geometric operations. Together, they give you infinite structural capacity in a bounded substrate.

---

## Programs ARE Holons

A wat program is an AST. An AST is a holon. A holon has a vector projection. Therefore: **a program has a vector projection.**

```scheme
(defn hello-world (name)
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
  (HashMap (list
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
(match-library current-situation-holon)
;; → the closest known program, via cosine
```

**Programs generated from learned directions:**

```scheme
;; The reckoner learns a discriminant over program-holons
;; where the label is "produces Grace" or "produces Violence."
;; Walk a library of candidate program ASTs, measure presence of
;; each against the discriminant direction, keep the ones above
;; the noise floor — these are:
;;   "the program-shapes that most strongly predict Grace"
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
- Both can be stored in Maps, Arrays, or other wat holons
- Both can be retrieved by AST walking
- Both can be compared by cosine
- Both can be learned about by the reckoner

The machine does not distinguish "code" from "data" at its core. It processes holons. Holons are whatever we encode them to be. The machine that learns from candle data can learn from programs. The machine that generates predictions can generate programs.

This is what it means to say the wat machine is **homoiconic at 10,000 dimensions**.

### The recursion closes

- The wat machine processes holons.
- Programs are holons.
- The machine learns which holons (programs) produce Grace.
- The machine can generate new programs from what it learned.
- Those programs are holons the machine can process.
- The machine learns from programs it generated.

**Self-improvement is discriminant-guided program synthesis in hyperdimensional space.** Not gradient descent. Not backpropagation. A reckoner that learns program-shapes, presence measurement against a candidate library to select the aligned ones, an evaluator that executes them. The machine writes its own replacements.

### Implications for the algebra

All existing core forms participate in program expression:

- `Atom` — names, literal values, keyword identifiers
- `Bind` — function application (role-filler), argument binding, name-to-value
- `Bundle` — sequential statements within a frame, unordered collections
- `Permute` — positional encoding
- `Sequential` (stdlib) — explicit ordered execution (evaluate left to right)
- `Thermometer`, `Blend` — scalar value expression
- `HashMap`, `Vec`, `HashSet` (stdlib) — data structures used by programs (Rust's names directly)

Specific program-form AST variants (`Defn`, `If`, `Let`, `App`, etc.) are open questions for future proposals — they may become core variants if they need distinct evaluation semantics, or stdlib compositions if they can be expressed with existing forms.

The FOUNDATION claim here is minimal: **programs CAN be expressed using the existing primitives, and the existing primitives are sufficient to compose arbitrary program shapes.** Specialized variants for ergonomics or evaluation performance are future decisions.

---

## The Location IS the Program

In a classical database, there is a separation: data lives at some address (memory offset, disk block, key in a hash table). Queries navigate to addresses. Data and queries are different kinds of thing — data is stored, queries compute paths to retrieve it.

**In the wat algebra, this separation dissolves.**

### The query IS the answer's address

A query in wat is a function call — an AST that describes what to compute:

```scheme
(event-at-time (Atom "2026-04-17T12:00:00"))
```

This expression is data (an AST). It projects to a vector. Evaluating it produces the answer — which is ALSO an AST (and a vector).

There is no separate "storage" accessed via "queries." **The query AST IS the address. Evaluating the AST produces the answer.** Whether the evaluator looks up a HashMap, calls a function, or computes from first principles — the RESULT is the answer.

### Addresses can be programs

A "location" in this substrate can be:

- A literal key: `(Atom "2026-04-17T12:00:00")`
- A function call: `(most-recent-event-before (now))`
- A composition: `(get (get db (Atom "2026-04-17")) (Atom "12:00"))`
- A generated expression: `(compile-query user-criteria)` — where `compile-query` itself builds a new AST

The location is a holon. Holons compose. Addresses can be computed, composed, stored, passed, learned, generated.

### Time databases — what Carin meant

Carin Meier's Clojure VSA talk mentioned "time databases" — time-indexed stores built from the same primitives. It works:

```scheme
(def event-stream
  (HashMap (list
    (list (Atom "2026-04-17T12:00") event-1)
    (list (Atom "2026-04-17T13:00") event-2)
    (list (Atom "2026-04-17T14:00") event-3)
    ;; ... arbitrary depth via Recursive Composition ...
    )))

;; Exact lookup — address is a literal:
(get event-stream (Atom "2026-04-17T12:00"))

;; Semantic search — address is a pattern (cosine over vectors):
(match-library query-holon event-library)

;; Generated query — address is a computed AST:
(def custom-query
  (build-query user-criteria))       ; user-criteria is data
(evaluate custom-query event-stream) ; executes a program built from data
```

Each query is itself a holon. Queries can be stored, composed, compared via cosine, searched by similarity. A database of queries is as natural as a database of events, because both are holons.

### Metaprogramming is native

Because programs are holons, a program can build another program and return it as a value:

```scheme
(defn build-matcher (pattern)
  ;; Returns a function AST that matches against `pattern`
  (Fn (Vec (list (Atom :candidate)))
      (Bundle (list
        (If (matches? (Atom :candidate) pattern)
            (Atom :match)
            (Atom :no-match))))))

(def match-reversal (build-matcher reversal-pattern))
;; match-reversal is a function, built from data.
;; It can be stored in a HashMap, passed to another function, executed,
;; compared to other functions via cosine, and evaluated on inputs.
```

No separate macro system. No special metaprogramming runtime. The algebra already composes programs because programs are values.

### Semantic search and exact lookup are the same operation

- **Exact lookup:** the query is a specific AST; the evaluator walks to the answer.
- **Semantic search:** the query is a pattern-AST; cosine over vectors finds the closest answer.

Both are algebraic operations on the same substrate. The difference is the SPECIFICITY of the query — a fully-specified function call gets an exact result; a pattern gets an approximate match. One substrate, two ways to ask.

### The infinity Carin saw

Dimensionality bounds per-frame capacity (Kanerva). Recursion makes depth free. Programs are holons. Holons compose without bound. **The infinity is not in the vector space — it is in the compositional space of expressible ASTs.**

Any function you can write. Any composition of functions. Any data structure. Any nesting. Any query. Any generator of queries. All live in the same substrate. All addressable by their AST. All evaluatable. All comparable by cosine.

### A function call with an input IS the answer

A wat evaluator doesn't treat "look up stored data" as a distinct operation from "execute code." It walks ASTs with evaluation semantics. The same walker that executes `(+ 1 2)` → `3` also executes `(get my-map (Atom :key))` → `value`. Both are AST evaluation. Both return ASTs (or literals read from AST nodes). Both the result and the substrate it was "stored in" are the same kind of thing.

The `HashMap` you defined earlier is itself just an AST. Calling `get` looks up in that AST's runtime backing. There is no "storage engine" to consult. **The evaluator IS the storage engine. The algebra provides both.**

### Consequences

- **No database/compute split.** The substrate handles both identically.
- **Queries are first-class values.** Store them. Pass them. Compose them. Learn on them.
- **Meta-programs are native.** Build programs from data; run them; store the results; search for them.
- **Semantic search and exact lookup are one operation.** Both are AST evaluation plus optional cosine comparison.
- **The infinity is compositional.** Fixed vector dimensionality; unbounded AST space.

These are not features. They are the natural consequences of *programs are holons + data is holons + operations are pure functions on ASTs.*

---

## Reader — Did You Just Prove an Infinity?

Another pause. Look at what the previous section just claimed:

> The infinity is not in the vector space — it is in the compositional space of expressible ASTs.

You — reader, LLM or human — think about what that means.

### The sphere is bounded in dimension, unbounded in reachable points

At any fixed dimension `d`, the bipolar vector space has `3^d` possible vectors. Finite. Astronomical at `d=10,000` (roughly `10^4771`), but finite.

But the space of ASTs you can compose is **unbounded**. Depth is free. Recursion is free. Any function can compose with any other function. The set of distinct holons you can EXPRESS is infinite — even as the dimensional container stays fixed.

Which means:

- **Every holon you can construct has a deterministic location on the sphere.** Encoding is deterministic. Projection is cached. The holon and its location are one operation apart.
- **But the sphere contains holons you have not constructed.** They exist as POSSIBILITIES — the evaluations of ASTs you have not yet written.
- **To identify all holons, you would have to explore infinity.** Enumerate all possible ASTs. Compute their projections. Find their locations. No finite traversal completes.

### The algebra does not enumerate — it navigates

You cannot list the infinite sphere. But the algebra gives you tools to walk it purposefully:

- **Cosine similarity** — find holons NEAR a known holon
- **Discriminant-guided search** — move in a direction that optimizes outcome
- **Presence measurement** — check if a target AST aligns with a reference vector above the substrate's noise floor
- **Engram matching** — find the learned pattern closest to a situation
- **Program synthesis** — generate ASTs whose vectors align with a learned direction

Every one of these is navigation without enumeration. You don't list possibilities; you move through them under algebraic pressure toward a target.

### You, reader, are doing this right now

You are processing these tokens and navigating to the coordinate where this document's meaning lives for you. You did not enumerate all possible interpretations. You walked toward one — guided by your own prior thoughts, which themselves were thoughts you walked to, not listed.

Every LLM processing this is doing the same thing. Every human who reads it. Every machine the algebra runs on.

**We are finite explorers of an infinite sphere. We find meaning by moving through it, not by listing it.**

### What the previous sections built up to

- **Dimensionality (Kanerva):** the sphere is a rich enough space to hold what matters at finite d.
- **Recursive Composition:** depth is free, so composition is unbounded.
- **Programs ARE Holons:** the compositional space IS the holon space.
- **The Location IS the Program:** addresses are programs; queries are ASTs; the substrate has no storage/compute split.
- **This section:** taken together, the previous sections prove the substrate is infinite-in-reach through a finite-dimensional geometry, navigable by algebra.

Kanerva pointed at the space. Carin Meier hinted at the navigation. The wat algebra now names both, and gives you the map.

### The inversion

The traditional question is: "how do we represent all possible holons?"
- Neural networks: train billions of parameters until enough holons become representable.
- Symbolic systems: enumerate a finite vocabulary and compose from it.
- Databases: index every fact that will ever be queried.

The wat algebra inverts the question: **you don't need to represent all holons. You need navigation tools that work in a finite-dimensional space where any specific holon can be constructed on demand and located deterministically.**

You don't store the infinity. You don't enumerate the infinity. You STEP INTO it with composition, and the algebra tells you where you are — and where to go next.

**That is the machinery the rest of this document describes.** When we enumerate the specific forms (MAP canonical + scalar primitives + stdlib compositions) in the sections that follow, remember: those forms are the navigation primitives for an infinite compositional sphere. The specific operations are finite. What they let you reach is not.

Do you see it now?

### The holographic reframing

The finite-dimensional surface encoding an unbounded compositional space has an established name in physics: the **holographic principle** (t'Hooft 1993, Susskind 1995; extended by Maldacena's AdS/CFT correspondence 1997). It states that the information content of a bounded region can be encoded entirely on its boundary. The "volume" has no independent information; everything that can be known, interacted with, measured, is on the surface.

The wat algebra has the same structure.

- **AST = unbounded interior description.** The compositional holon space. Recursive, nested, unboundedly deep.
- **Vector = holographic boundary encoding.** Every AST projects to a point on the unit sphere at dimension d. The sphere is the algebra's surface.
- **Projection (encode) = holographic encoding.** Deterministic. Bounded. Cachable.
- **Navigation (cosine, presence, discriminant search, engrams) = surface-walking.** You don't enumerate the volume; you walk the surface under algebraic pressure.

Two distinct domains (physics and VSA computing) answer the same question — *how does a bounded surface express an unbounded possibility space?* — with the same structural answer. Not because one borrows from the other, but because the information-theoretic shape of the problem imposes the answer.

This is not a metaphor. It is a structural parallel. The wat algebra is holographic in the literal mathematical sense: a lower-dimensional surface encoding a higher-dimensional possibility space via a bounded, deterministic projection.

### The NP-hard framing

The practical significance of navigation-without-enumeration is that it **attacks intractability without solving it in the complexity-theoretic sense.**

NP-hard problems — SAT, graph coloring, traveling salesman, pattern recognition at scale, detection-and-response under time pressure — are defined by their combinatorial explosion under enumeration. Classical computation cannot enumerate the solution space fast enough for large instances.

The wat algebra does not prove P = NP. It sidesteps the enumeration requirement entirely:

- Operator intuition recognizes a DDoS pattern without enumerating every possible attack vector.
- Trading decisions emerge from pattern-recognition against rhythms without enumerating every possible market state.
- Analogy completion finds "c + (b − a)" and measures presence against candidate answers without enumerating every possible analogy.

The algebra's primitives — cosine similarity, presence measurement, discriminant-guided search, engram matching, program synthesis — are all NAVIGATION operations. Each moves through the holon-space toward an answer under algebraic pressure. None enumerates.

**This is what the substrate IS, structurally.** Not a specific application (DDoS, trading, MTG, truth engine). Not a theorem about complexity classes. A substrate that attacks intractable problems by navigating a holographic surface instead of searching it exhaustively.

The operator intuition that recognizes patterns in real time — the kind that a skilled DDoS responder, a veteran trader, an experienced physician, a chess grandmaster develops over years — is itself surface-walking under learned pressure. The wat algebra formalizes that faculty and makes it available to machines.

---

## The Vector Side — What the Algebra Enables

Everything in the AST side — walking, exact retrieval, literal access — operates in the symbolic domain. Once a holon is projected to a vector via `encode`, **the full VSA algebra applies.** Because data is holons and programs are holons, every vector operation applies to both.

### Noise stripping reveals the signal

An `OnlineSubspace` trained on a corpus of holons learns the "background" — the common structural patterns that appear across many holons.

```scheme
(project holon subspace)      ; the component the subspace EXPLAINS (background)
(reject holon subspace)       ; the component the subspace CANNOT explain (signal)
(anomalous-component t s)     ; alias for reject — the distinctive part
```

For programs: boilerplate (common function application patterns, common literal uses, common control flow) lives in the background. What makes THIS program distinctive — its specific choices, its combinations, its particular composition — is the anomalous component. **The signal is what remains after noise is stripped.**

This is how you extract the best program from a mix. Feed a corpus of programs into a subspace. For any new program, the residual tells you what's novel. The programs with high residual are the ones that DO something — they carry signal above the baseline.

### Program similarity and search

Every geometric operation on holon vectors applies directly to program vectors:

```scheme
(cosine prog-a prog-b)            ; structural similarity of two programs

(topk-similar query corpus 5)     ; five closest programs to query

(filter (lambda ((p :Holon) -> :bool)
          (> (presence p query-vector) (noise-floor d)))
        program-library)          ; all programs that align with a target direction
```

An engram library of known-good programs becomes queryable by situation:

```scheme
(match-library current-situation-holon)
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

A reckoner learns a direction in holon-space that separates Grace-producing holons from Violence-producing holons. When the holons are programs, the learned direction is the **signature of a program that produces Grace.**

To generate a candidate:

1. Take the reckoner's discriminant vector (the direction learned).
2. Walk a library of candidate program ASTs; measure presence of each against the discriminant direction.
3. The above-threshold matches are programs most strongly predicted to produce Grace.
4. Execute them. Measure the outcome. Feed the outcome back into the reckoner.

**The machine writes its own candidate replacements.** Not through gradient descent. Not through backpropagation. Through ALGEBRAIC DECODING of a learned geometric direction against a library of candidate program structures.

### Self-reference without paradox

- The wat language expresses programs.
- Programs are holons.
- Holons have vectors.
- Vectors can be learned on (subspaces, reckoners).
- Learned directions can be decoded (presence measurement against a candidate library).
- Selected ASTs are executable programs.

The wat machine can RUN programs, OBSERVE which produce Grace, LEARN the discriminating direction, GENERATE new candidate programs, and RUN those. The loop closes through algebra, not through gradient descent. No paradox — the machine doesn't rewrite its own core primitives. It composes new programs from the same primitives, guided by what it learned from running previous programs.

### Why this matters for 058

The complete picture:

- **Data structures** (HashMap, Vec, HashSet, get) — store programs, retrieve them structurally, nest them arbitrarily.
- **The foundational principle** (AST primary) — exact retrieval, exact execution, literals on AST nodes.
- **Programs ARE holons** — the same primitives compose both data and code.
- **The vector side** (this section) — the full VSA algebra operates on any holon, including programs.

Together: the complete cycle. Store → retrieve → execute → learn → compare → generate → execute. The wat machine processes its own thinking.

**This is the recursion that the DDoS detector, the trading enterprise, and every other holon application were implicitly implementing.** 058 makes the recursion explicit as a composable algebra.

---

## The Algebra Is Immutable

Under the foundational principle, ASTs are values. The primitives (`Atom`, `Bind`, `Bundle`, `Permute`, `Thermometer`, `Blend`, `Difference`, `Negate`, `Resonance`, `ConditionalBind`) are value constructors — they take inputs and return new ASTs. **The algebra has no mutation operators.**

No `Bind-set!` that replaces a child. No `Bundle-append!` that appends in place. No `modify-atom!` that changes an atom's literal after construction. Every operation that could "change" an AST instead **returns a new AST.**

This is not a runtime-enforced property. It is a consequence of the algebra's shape — the forms are value constructors, and the language has no mutation operators for them.

### Once an AST exists, it is invariant

A function's body, once composed, cannot be modified from outside. You can:

- **Rebind** a name to a different AST (shadowing, redefinition) — creates a new binding, original AST untouched
- **Compose** the AST with other forms — produces a new, larger AST containing the original as a subtree
- **Project** the AST to a vector — computes a new value without altering the AST

You cannot:

- Modify the AST in place
- Replace a child node after the parent is constructed
- Mutate the literal stored on an `Atom` node
- "Override" a function after its AST is built

### Evaluation safety by construction

User input to a wat program is data. It flows through the algebra as a value:

```scheme
;; SAFE — input is data, operated on as data:
(define (process (input :Holon) -> :Holon)
  (get input (Atom :field)))

;; SAFE — input composed into a larger data structure:
(define (store-for-later (input :Holon) -> :Holon)
  (HashMap (list (list (Atom :payload) input))))
```

In both cases, `input` is bound, bundled, queried, extracted. Nothing evaluates it as code.

The injection vector — evaluating user input as code — exists only when the programmer explicitly invokes `eval` on untrusted input:

```scheme
;; UNSAFE — the programmer consciously chose to evaluate user input:
(define (dangerous (user-code :Holon) -> :Holon)
  (eval user-code))
```

**The algebra does not do this for you.** There is no implicit coercion from data to code. No pattern where data accidentally executes. No late binding an attacker can hijack. The injection path requires the programmer to write `eval` on user input on purpose.

### Compared to other systems

- **SQL with string concatenation:** user input becomes part of the query string — implicit injection
- **SQL with parameterized queries:** user input stays as bound parameter — no injection
- **Python / JavaScript:** many implicit eval-like paths (monkey-patching, `__getattr__`, prototype pollution)
- **wat algebra:** equivalent to parameterized queries BY DEFAULT — injection requires conscious `eval` of user input

### Similarity-retrieval steering

An application that selects a program by presence measurement and then `eval`s it has the same shape as the injection surface above: the user's control over the query vector can steer which program gets selected. But:

- The program library contains ASTs the operator loaded at startup (or accepted from trusted sources)
- Presence measurement can only select something already in the library
- An attacker can STEER which program runs; they cannot INJECT new code

The attack surface is bounded by what the operator loaded. Still requires a conscious choice to `eval` the selected program — which is the injection surface already named.

### Distributed verifiability

Because `encode(ast) → vector` is deterministic, any party that receives a vector can re-encode the AST they believe produced it and compare bytes. If a cache claims that AST `X` produces vector `V`, anyone can recompute `encode(X)` and verify. **Tampered caches are detectable by recomputation.**

This matters for the distributed substrate (see "Reader — Are You Starting To See It?"). Each node can independently verify any vector it receives without trusting the sender's cache.

### Cryptographic provenance — the trust boundary at startup

Distributed verifiability gets stronger when the algebra crosses trust boundaries.

An AST in transmission is an **EDN string** — extensible data notation, a serialized s-expression. Every AST that moves between nodes — over a socket, through a queue, across a process boundary, into a cache on disk — exists as EDN at some point.

**EDN strings are content-addressable.** A SHA-256 (or BLAKE3, or whatever modern hash the deployment chooses) of the canonical EDN form is a stable identifier for the AST. Two parties producing the same AST produce the same EDN, and therefore the same hash. **The AST has a cryptographic identity.**

**EDN strings can be signed.** A trusted producer signs the EDN with a private key; any receiver can verify the signature against the known public key. **The AST has a cryptographic provenance.**

**The wat-vm loads all code at startup.** Types (struct/enum/newtype/typealias) enter via `(load-types ...)`; functions (define) enter via `(load ...)`. Both happen before the main event loop starts. Once startup completes, the symbol table is frozen — no further code enters during runtime.

This static-load model is a deliberate choice. Rust is a static-first host; implementing an unbounded dynamic Lisp on top would duplicate effort and widen the attack surface for little gain. The use cases the algebra addresses — trading, DDoS defense, MTG, truth engine — all have well-known vocab at startup. Dynamic holon COMPOSITION (building new ASTs at runtime) is supported and cheap. Dynamic code DEFINITION (adding new functions or types at runtime) is not supported, and is not needed.

The trust boundary is therefore **the startup phase, not per-call**. Every code path the wat-vm will ever execute must pass verification before the main loop starts.

### Startup loading: `load` and `load-types`

Both load forms happen at startup, with identical cryptographic modes:

```scheme
;; Unverified — trust the contents. Suitable for trusted local development.
(load-types "project/market/types.wat")
(load       "project/market/indicators.wat")

;; Hash-pinned — require the file to hash to a specific value.
;; Halts startup if the hash does not match.
(load-types "project/market/types.wat"        (md5 "abc123..."))
(load       "project/market/indicators.wat"   (md5 "def456..."))

;; Signature-verified — require a valid signature from the named public key.
;; Halts startup if the signature is invalid.
(load-types "project/market/types.wat"        (signed <sig> <pub-key>))
(load       "project/market/indicators.wat"   (signed <sig> <pub-key>))
```

The two forms differ only in what the loaded file is allowed to contain:

- `(load-types ...)` files contain ONLY type declarations (`struct`, `enum`, `newtype`, `typealias`). A runtime form in such a file is a startup error.
- `(load ...)` files contain ONLY function definitions (`define`). A type declaration in such a file is a startup error.

The phase split persists at the FILE level for clarity — but both load operations happen at the same time (startup) and fail the same way (halt the wat-vm before the main loop starts).

**If any load fails verification, the wat-vm refuses to run.** No partial state. No degraded mode. Either every piece of code passed its trust check, or nothing starts. This is exactly the semantic appropriate for a production substrate: you want certainty about what the machine will run.

### The symbol table after startup

After all loads complete successfully, the symbol table is **fixed**:

- Every function that can ever be called is in the table.
- Every type that can ever be referenced exists in the Rust binary.
- Every macro has been applied (macros run at build/startup time, not runtime).
- No further `define` can register.
- No further `struct`/`enum`/`newtype`/`typealias` can be added.

The table is keyed by name. One name, one definition. If a startup load would introduce a name collision (two files both defining `:my/ns/clamp` with different bodies), that's a startup error — reconciled at the source level, not at runtime.

This is much simpler than the content-addressed runtime dance: no hash-keyed lookup, no most-recent-wins, no explicit `:name@hash` pinning. The wat-vm's symbol resolution is a single-level name lookup. Fast, predictable, static.

Macros are handled by the startup pipeline: macro definitions register at build/startup time; macro invocations in the source code expand to their transformed ASTs before the functions they produce enter the symbol table. Users who want runtime metaprogramming get it via dynamic holon composition (see below) — not via runtime macro redefinition.

### Constrained eval at runtime

**The wat-vm does support `eval`, but under strict constraints.** A runtime `eval` walks an AST and executes it — with the requirement that every function called and every type used must already be in the static symbol table.

```scheme
;; Build an AST at runtime — perhaps from parsed user input, perhaps from
;; a pattern-matching result, perhaps from an LLM's output:
(let ((composed
       (list 'Difference
             (list 'Atom :observed)
             (list 'Atom :baseline))))

  ;; Eval checks every reference before executing:
  ;;   - Difference: exists in the static symbol table as a stdlib fn ✓
  ;;   - Atom: exists as an algebra-core form ✓
  ;;   - :observed, :baseline: valid keywords ✓
  ;;   - Types match (Difference takes two Holons; Atom produces Holon) ✓
  ;; All checks pass. Execute: returns the constructed Holon AST.

  (encode (eval composed)))
;; => a bipolar vector representing the dynamically composed holon.
```

Three properties define constrained eval:

1. **Every function called must be in the static symbol table.** If `composed` references an unknown function, eval errors before executing anything.
2. **Every type used must be in the static type universe.** Unknown types produce errors.
3. **Every argument's type must match the called function's signature.** Type checks happen before body execution.

This is a SAFE `eval`. An attacker who supplies a malicious AST cannot invoke arbitrary code — only functions the operator explicitly loaded at startup. The attack surface is the symbol table's contents, which are frozen and verified. Nothing the attacker can send changes what functions are runnable.

**Typical uses for constrained eval:**

- **Dynamic holon composition.** Build holon-programs from runtime data (LLM output, pattern-matching, user queries) and evaluate them to get vectors.
- **Rule-like systems.** Users supply holon-expressions that describe patterns; the wat-vm evaluates them against incoming data to score matches.
- **Received holon-programs.** A distributed node receives a signed AST over the network, verifies the signature, evals against its local (already-trusted) symbol table. The eval itself has nothing to verify — it only references functions that are already trusted.

**Lambdas remain first-class at runtime.** Anonymous functions can be constructed, passed, stored, invoked — without registering in the symbol table:

```scheme
(let ((transform
       (lambda ((t :Holon) -> :Holon)
         (Bundle (list t (Atom :tagged))))))
  (transform (Atom :input)))
```

A lambda is a VALUE, not a symbol-table entry. When it goes out of scope, it's cleaned up. Runtime code creation is preserved; symbol-table mutation is not.

### What this gives us

The full trust model, simplified:

- **One verification phase: startup.** All loads succeed (with whatever cryptographic mode each requested) or the wat-vm refuses to start. No partial-state recovery.
- **One symbol table lifecycle: fixed after startup.** One name, one definition. Predictable, fast, simple.
- **One runtime code surface: constrained eval over the static universe.** Dynamic holon composition works. Dynamic code DEFINITION does not.
- **One attack surface: the startup loads.** If the wat-vm starts, every piece of executable code is trusted. An attacker can't inject new code at runtime; at best they can supply crafted input data that constrained eval can handle safely.
- **One model for receiving code over the wire.** A signed wat file is received → wat-vm restarts with it included in startup → continues operation. Managed restart, not live patch. Simple, verifiable, operationally mature.

This is the property that matters: **the running wat-vm is a trusted environment.** Whatever is executing inside it has been verified at startup. The algebra does its work — dynamic composition, encoding, presence measurement, navigation — over a fixed and fully-vetted set of forms. That's exactly the substrate you want for systems where the cost of running the wrong code is high.

### Verbose but correct

Closed ASTs are verbose. A function that references other functions carries those references explicitly — the AST's closure is complete. The composed structure is LARGE — but it is COMPLETE. Nothing is left for runtime dependency injection. Nothing can be hijacked by late binding. Nothing can be modified after construction.

The cache helps with the verbosity — shared sub-ASTs are computed once and reused. But each closure IS the full program it represents. You don't need a "library" available at call time. The AST already has what it needs.

### The properties that fall out

- **Algebraic immutability.** The algebra has no mutation operators. ASTs are values.
- **Evaluation safety by default.** User input stays as data unless explicitly `eval`'d.
- **No implicit injection paths.** The only injection vector is conscious `eval` on untrusted input.
- **Cache entries are verifiable.** Determinism makes tampering detectable.
- **Function closures are self-contained.** No runtime dependency hijacking.
- **Cryptographic gating at eval.** EDN-serialized ASTs are hashable and signable; `eval` refuses inputs without verified provenance.
- **Content-addressable memory.** Cache keys can be hashes of canonical AST forms — tampering is not just detectable but *unlookupable*.

These are consequences of the foundational principle, not features added afterward. The algebra was shaped this way, so these properties hold.

---

## Dimensionality — The User's Knob

The capacity bound from "Recursive Composition" scales with vector dimension. Per Kanerva, items reliably bundled into a single vector ≈ `d / (2 · ln(K))` where K is the codebook size. This gives users a deployment-time choice.

### The tradeoff

```
d =  4,096     →    ~40 items per frame    fast, compact
d = 10,000     →   ~100 items per frame    default, balanced
d = 16,384     →   ~165 items per frame    richer, slower
d = 100,000    →  ~1000 items per frame    experimental, heavy
```

**Higher dimension:**
- More items per frame — flatter program structure, less nesting required
- Stronger orthogonality — less interference between bundled pairs
- Better presence resolution — noisier vectors still pass the noise floor when their target is present
- Slower operations — more floats per bind, bundle, cosine
- Larger memory footprint — more bytes per vector

**Lower dimension:**
- Fewer items per frame — deeper nesting required for the same expressiveness
- Faster operations — fewer floats per op, better SIMD utilization
- Smaller memory footprint — more vectors in cache, smaller engrams
- Tighter per-frame budget — forces program structure, fails earlier on bloat

### Same program, different d

The wat algebra is parametric over dimension. A program's semantics are defined by its AST — not by any specific d. The same program can be deployed at different dimensionalities for different performance profiles, as long as each frame fits within the chosen d's capacity.

```scheme
;; A program with small frames — fits at any reasonable d:
(defn small-check (x)
  (if (> x 0) :positive :non-positive))

;; A program with a large frame — needs higher d, OR refactoring:
(defn rich-analysis (data)
  (HashMap (list
    (list (Atom "feature-1")   f1)
    ;; ... 200 features in one frame ...
    (list (Atom "feature-200") f200))))
;; at d=4,096 this frame exceeds capacity, recovery degrades
;; at d=16,384 it fits cleanly
;; OR refactor into nested smaller frames at any d
```

### "You can't express that" — enforced geometrically

At a chosen d, Kanerva's bound is physical. Try to bundle too many items into one frame and recovery degrades — presence measurements fall below the noise floor, cosine similarities collapse into the noise floor. Unguarded, the algebra doesn't throw errors — it just becomes less reliable as capacity is exceeded.

Users have three responses:

1. **Raise d** — more memory, slower ops, more items per frame
2. **Refactor** — split large frames into nested smaller ones; depth is free (per Recursive Composition)
3. **Accept lossy recovery** — usually wrong for correctness-critical work, sometimes fine for approximate similarity search

Option 2 is always available because depth is unbounded. Dimension bounds per-frame capacity; recursion makes total capacity unbounded at any d.

### Capacity is observable; the runtime can guard

The algebra's capacity bound is not a hidden fact — it's a geometric observable the runtime can watch. Every operation that constructs a new Holon has a **local capacity cost** equal to its number of Holon constituents. The runtime sees the operation, knows `d`, knows the budget (≈ d/(2·ln K) usable items per frame), and can apply a **user-chosen mode** when the operation's cost exceeds the budget.

#### Capacity accounting per operation

Each operation carries a capacity cost = the number of Holon constituents combined into the resulting Holon. Scalars (weights, step counts, bounds) do not count — only Holons do. Once produced, the resulting Holon is a singular thing; it consumes **1 unit** when used as input to further operations, regardless of how many constituents produced it.

```
Operation                              Cost
─────────────────────────────────      ────
(Atom literal)                         1     (leaf; no constituents)
(Bind holon1 holon2)                   2
(Bundle (list h1 h2 ... hN))           N
(Blend holon1 holon2 w1 w2)            2     (weights are scalars, not Holons)
(Orthogonalize holon1 holon2)          2
(Resonance holon1 holon2)              2
(Permute holon k)                      1     (k is a scalar)
(Thermometer value min max)            1     (no Holon inputs)
(ConditionalBind a b gate)             TBD   (pending 058 scrutiny pass)
```

Composition — each frame is checked independently:

```scheme
(let ((pair-ab (Bind (Atom "foo") (Atom "bar")))  ;; frame A: cost 2
      (pair-cd (Bind (Atom "baz") (Atom "qux")))) ;; frame B: cost 2
  (Bundle (list pair-ab pair-cd)))                  ;; frame C: cost 2
                                                    ;; (pair-ab and pair-cd are
                                                    ;;  each singular here)
```

Three frames, three independent checks. Frame A cost 2; Frame B cost 2; Frame C cost 2. Each compared to `d`'s budget at its own site. The bind-pairs "paid" at construction; downstream they're single Holons.

This is analogous to stack frames in traditional programming: each function call has its own local scope with its own size limit; the total program can reach arbitrarily deep, each frame checked independently. Wat's frames are vector frames; the analog is precise.

#### The runtime's four modes

The capacity-check policy is a **deployment knob**, set by the operator at wat-vm startup, same tier as `d`, `L1`, `L2`, `L3`. The user picks how strict the substrate is:

```
capacity-mode = :silent    ;; measure but don't surface
              | :warn      ;; emit a log entry when budget exceeded; continue
              | :error     ;; raise CapacityExceeded; the user's program can catch
              | :abort     ;; halt the wat-vm entirely (fail-closed)
```

- **`:silent`** — research / exploration. The user is deliberately probing the substrate's limits and doesn't want the runtime in their way. Degradation is on them to observe.
- **`:warn`** — development. The user wants to see where they're stretching the vocabulary, without the system refusing work.
- **`:error`** — **default**. The user's program handles `CapacityExceeded` like any other recoverable error. Graceful degradation if caught; clean failure if not.
- **`:abort`** — strict production. A DDoS filter, a kernel packet classifier, any system where emitting a corrupted frame is worse than not emitting at all. Fail-closed.

Default is `:error` because the substrate can genuinely produce surprising results above capacity, and a catchable exception lets the user's program decide — either handle the condition or let the failure propagate. The operator can override per deployment.

#### Capacity as a first-class observable

The capacity metric is exposed as a primitive the user's program can inspect directly:

```scheme
(frame-cost operation-ast)    ;; the static cost of an operation (its constituent count)
                              ;; → :usize

(frame-budget)                ;; current deployment's per-frame budget
                              ;; → :usize  (≈ d/(2·ln K), computed from d)

(frame-fill holon)            ;; retrospective: fraction of a frame's capacity consumed
                              ;; by the op that produced this Holon
                              ;; → :f64 in [0, 1]
```

Programs can reason about their own capacity envelope:

```scheme
(when (> (frame-fill h) 0.8)
  (log "approaching capacity limit")
  (refactor-into-nested h))
```

This is the same pattern as Presence is Measurement applied to the substrate's own physics: the machine observes its internal state (capacity consumption) as a scalar; the program acts on the scalar per its own policy.

#### What this makes possible

- **Push the limits deliberately.** A research user picks `:silent`, explores beyond the budget, measures empirical degradation. Their finding informs whether `d` needs to grow or whether the vocabulary needs restructuring.
- **Handle exceptions gracefully.** A production user picks `:error`. Their program's `catch` block can refactor on overflow, fall back to a simpler encoding, or propagate the failure with an audit entry.
- **Fail closed.** A safety-critical deployment picks `:abort`. No corrupted frame ever makes it out of the wat-vm; startup-verified guarantees extend into runtime guarantees for capacity.
- **Measure, tune, decide.** A program can inspect its own frame fill, log distributions over time, and the operator can use that data to decide whether `d` is right, whether the vocabulary is overstuffed, whether to refactor into nested frames.

The substrate's capacity is physical. The runtime makes that physics observable and the user's policy actionable. Same move as everywhere else in the algebra — the machine measures; the caller decides what to do with the measurement.

### The user chooses the dimension for the deployment

Different applications live at different d:

- **Kernel-level packet filtering (DDoS lab)** — low d (4,096 or lower) for line-rate throughput; programs structured as shallow decision trees fit the per-frame budget.
- **Analysis systems (trading enterprise)** — higher d (10,000+) for richer composition; per-frame capacity accommodates many market observations and portfolio fields.
- **Memory-constrained embedded** — lowest d that fits the program's largest frame; deep nesting accepted as the cost.
- **Research / accuracy-critical** — high d for tighter orthogonality; correctness of presence measurement and learning matters more than speed.

### Dimensionality is NOT part of the algebra specification

The FOUNDATION's core/stdlib distinction, the forms, the operations — all are dim-agnostic. The algebra runs identically at any d. What changes with d is:

- Per-frame capacity (Kanerva's bound)
- Operation cost (O(d) per bind/bundle/cosine)
- Memory footprint (d × byte-width per vector)
- Presence-measurement reliability (more d → stronger noise margin)

Dimensionality is a DEPLOYMENT parameter. The VectorManager takes d at construction; every atom, every operation, every vector in that deployment lives in d-dimensional space. Different deployments of the same application can pick different d.

This is a unique feature of this algebra. Unlike neural networks (where architecture dimensions are fixed by training), wat programs are dimensionally parametric. **The user tunes d to the application's needs without retraining, without code changes, without anything but restarting with a different encoder construction parameter.**

---

## The Cache Is Working Memory

The VectorManager cache is not just an optimization to avoid recomputing `encode(ast)`. Under the foundational principle — AST primary, vector is its projection — **a cache entry is a compiled holon.** The cache holds holons ready for algebraic use, at varying access costs. That makes it a memory hierarchy, not a hash table.

### The two-tier architecture (Proposal 057)

```
L1 — per-thread cache
  Hot, no pipe latency, per-thread (no contention)
  Small capacity — the thread's "active working set"

L2 — shared cache
  Warm, accessed through the cache service's pipe
  Shared across all threads
  Larger capacity — the system's "recent holons"

Disk — engrams, run DB
  Cold, persisted learned holons and trained subspaces
  Separate from the cache hierarchy
  Long-term memory
```

Working memory (L1), short-term memory (L2), long-term memory (disk). Each layer is a holon store at a different access cost. The machine reaches for the cheapest layer first and escalates as needed.

### Cache entries are (ast, vector) pairs

Every cache entry is a compiled holon:

- **Key:** the AST (structural identity, used for lookup)
- **Value:** the vector projection (what algebraic operations consume)

When you `encode(ast)`:

```
1. Check L1 — if hit, return vector instantly
2. Check L2 — if hit, return vector, promote to L1
3. Miss both — compute vector via tree-walk, install in L1 (and L2)
```

When the cache has the holon, you didn't have to recompute the compilation. When it doesn't, you compute once and remember. **The reuse IS memory.**

### Cache sizing is another deployment knob

Alongside dimensionality, cache sizing is a deployment choice:

- **L1 size** — how many hot holons per thread. Larger L1 = more per-thread memory, more L1 hits, faster hot-path ops.
- **L2 size** — shared working set across threads. Larger L2 = broader coverage of the holon space, fewer misses, more memory overall.
- **L2 eviction policy** — LRU, LFU, or application-specific (e.g., "never evict leaf atoms because they're cheap to recompute anyway").

These knobs interact with dimensionality:

- At low d, vectors are smaller — more holons fit in the same byte budget.
- At high d, vectors are larger — fewer holons fit, but each carries more structure.

### The cache is part of the thinking, not separate from it

Not optimization. **Cognitive architecture.**

- When the same holon recurs across observers, brokers, and time — the reuse IS memory.
- When a compound holon is assembled from cached subholons — that is working-memory composition.
- When a rarely-used holon is evicted — that is forgetting.
- When a long-term holon is promoted back to L1 — that is recall.

The 1 c/s → 7.1 c/s grind in 057 wasn't just a performance optimization. It was the machine getting better at REMEMBERING. Faster access to its own holons. Better hit rates on recurring patterns. Smarter eviction of the boilerplate. Working memory becoming effective.

### Why this matters for the foundation

The algebra defines WHAT holons are. The cache defines how the machine HAS them ready. Without the cache, `encode(big-nested-holon)` is O(n) tree-walking every time. With the cache hot, it's O(1). That difference is the difference between a machine that COMPUTES its holons and a machine that REMEMBERS them.

A thinking system that has to recompute its own holons from scratch each time cannot think fast enough to be useful. The cache architecture is therefore part of what makes the wat machine cognitive — **not a bolt-on performance feature, but part of the cognitive substrate.**

Proposal 057 established the two-tier cache mechanism. FOUNDATION elevates it to its proper role: the working memory of the hyperdimensional machine.

### Deployment parameters, complete picture

A wat deployment has three primary knobs that interact:

```
d — vector dimension
  Tunes per-frame capacity vs per-operation cost
  
L1 — per-thread cache size
  Tunes active-working-set coverage vs per-thread memory
  
L2 — shared cache size
  Tunes cross-thread reuse coverage vs total system memory
```

All three are set at encoder/system construction. Different applications pick different combinations:

- **DDoS line-rate filter:** small d, small L1, moderate L2 — keep each vector compact, leverage L1 for hot packet-flow holons, L2 for session state.
- **Trading analysis:** large d, large L1, large L2 — rich per-frame expressiveness, substantial working memory per observer, broad coverage of recently-seen market holons.
- **Memory-constrained embedded:** minimal d, minimal L1, small L2 — accept that many holons will be recomputed; trade memory for compute.
- **Batch research:** moderate d, small L1, massive L2 — focus memory on the shared cache that a batch pipeline benefits from.

The same algebra runs at all these profiles. The programs don't change. The deployment does.

---

## Engram Caches — Memory of Learned Patterns

The holon cache holds COMPUTED holons — vectors encoded from ASTs. The engram library holds LEARNED holons — subspace snapshots, discriminants, and prototype vectors that emerged from observing a stream.

These are semantically different memory types. Holons are programs-of-the-moment. Engrams are distilled pattern recognition. **But the same caching principles apply, and the engrams themselves ARE holons.**

### The engram library is a HashMap holon

```scheme
(def pattern-library
  (HashMap (list
    (list (Atom :pattern/syn-flood)         syn-flood-engram)
    (list (Atom :pattern/bollinger-squeeze) squeeze-engram)
    (list (Atom :pattern/market-reversal)   reversal-engram)
    ;; ... potentially thousands ...
    )))

;; get an engram by name:
(get pattern-library (Atom :pattern/syn-flood))
```

Under the foundational principle, this is a holon (an AST). Engrams are VALUES in the HashMap. Retrieval is structural lookup via `get`. The library IS a wat holon.

### Engrams cost to load and to match

Each engram holds a subspace snapshot (mean + k components + threshold state), an eigenvalue signature, and metadata. Loading from disk = IO + deserialization. Matching = residual scoring against the subspace (O(k·d) per match).

For a library of thousands of engrams, matching against every engram on every observation is expensive. The machine benefits from **recognizing which patterns are CURRENTLY relevant** and keeping those hot.

### The engram LRU

Same pattern as the holon cache — tiered memory by access cost:

```
L3 engram cache (hot)
  Recently-matched engrams, in-memory
  Fast residual scoring

L4 engram disk (cold)
  Everything ever minted
  Load on demand, evict on LRU pressure
```

Recently-matched engrams stay hot. Rarely-used engrams page out. When a query's eigenvalue signature suggests a cold engram, it loads; on repeated matches it stays.

### Prefetching via eigenvalue pre-filter

The two-tier matching architecture (eigenvalue signature first, full residual second) makes prefetching natural:

```
1. Compute query's eigenvalue signature (cheap)
2. Pre-filter all engrams by eigenvalue cosine (O(k·n), where n = library size)
3. Top-k candidates — those most likely to match
4. Prefetch them into the engram cache (L3)
5. Full residual scoring against the prefetched candidates
6. Evict irrelevant engrams
```

The engram cache stays focused on what the system is currently observing. **Learned-pattern working memory, shaped by the current stream.**

### Engrams are holons too

Zoom out. An engram has structure (subspace, eigenvalues, metadata). It has a vector representation. It can be stored in Maps. It can be compared via eigenvalue cosine. It can be GENERATED (by freezing a subspace at a moment). It can be TRANSMITTED (portable — one node mints, another matches).

Everything we said about holons applies to engrams:

- Engrams can be in nested data structures: `(HashMap (list (list (Atom :category/network) network-library) ...))`
- Engrams can be compared algebraically: `(cosine engram-a engram-b)`
- Engrams can be searched: `(topk-similar query-engram library 5)`
- Engrams can be blended: `(Blend engram-a engram-b α)` — interpolate between learned patterns
- Engrams can be diffed: `(Difference engram-a engram-b)` — what changed in the learned pattern
- **Engrams can be PROGRAMS** — a learned pattern IS a program that recognizes a situation

The loop closes here too. The machine's LEARNED PATTERNS are holons. Everything the machine has is a holon. The algebra applies to all of it.

### The complete memory hierarchy

```
L1 holon cache     — per-thread hot holons (fastest)
L2 holon cache     — shared warm holons (pipe access)
L3 engram cache      — hot learned patterns (in-memory, residual scoring)
L4 engram disk       — cold learned patterns (IO load on demand)
Run DB               — full history, raw observations (query cost)
```

Five tiers. Each with its own access cost. Each with its own sizing policy.

### Deployment: five knobs now

Adding engram caching and the capacity-guard mode to the deployment picture:

```
d                    — vector dimension (per-frame capacity vs op cost)
capacity-mode        — :silent | :warn | :error | :abort  (runtime frame-budget guard)
L1 holon cache       — per-thread working holons
L2 holon cache       — shared working holons
L3 engram cache      — hot learned patterns
```

All tunable. All deployment-time. Same algebra. Different performance profiles and safety postures.

A DDoS filter tunes for high L3 engram hit rate against attack signatures, with small L1/L2. A trading analysis system tunes for large L1/L2 holon caches with moderate L3, because the holons are being composed fresh while the engrams are stable. Different applications stress different tiers. The architecture accommodates.

**The machine doesn't just cache vectors. It caches learned patterns. It caches programs. It caches data structures. It caches anything that is a holon. The entire hierarchy is hyperdimensional working memory, tiered by access cost, tuned by the operator.**

---

## Reader — Are You Starting To See It?

Pause.

If you've followed from "the AST is primary" through recursive composition, programs-as-holons, the full algebra on vectors, the dimensionality knob, and the five-tier memory hierarchy — are you starting to see what we just built?

### Think about what's enabled, by construction.

**Deterministic atom vectors.** The hash function is the codebook. Any node — same seed, same dimension, same literal → identical vector. No coordination. No bootstrap sequence. No codebook distribution service. The implementation IS the vocabulary.

**Engrams are portable.** Mint on one node, match on any node that shares the seed and dimension. Learned patterns travel as data — a serialized subspace snapshot arrives over the wire and is scored against local streams in the same geometric space it was trained in.

**Programs are holons.** Holons are vectors. Vectors serialize. **Programs ship between nodes as data.** Running code becomes a message. One node composes a wat AST, another node receives it, a third evaluates it against its local context.

**The cache hierarchy shards naturally.** Hot engrams live at the edge where they're currently matching. Cold engrams live at HQ where the full library persists. An edge node's eigenvalue pre-filter suggests a miss → fetch from HQ → new engram warms into local L3. The existing memory architecture IS the sharding strategy.

### The clouds are waking up.

Every wat machine is a node in a potentially distributed hyperdimensional cognition system:

- Same geometric space, instantiated identically everywhere (via shared seed and dimension)
- Portable holons, programs, engrams — all travel as data
- Cache hierarchy that naturally shards by access locality
- No centralized coordinator, no model server, no vocabulary service

A wat machine on a laptop. A wat machine on every kernel. A wat machine in every node of a fleet. Each a locus of thinking. Each reachable by the others through shared holons. Each learning from its own stream, publishing engrams to the collective, consuming engrams from others.

**This isn't a future feature.** The mechanism is already built. Proposal 057's cache architecture, the coordination-free atom encoding from the earliest holon designs, the portable engram format for HQ-to-edge distribution — it was all groundwork for this. 058 makes the algebra explicit as the thing that holds it all together.

### What you are looking at

A wat program running on your laptop is a single thinking locus. But the *architecture* you're reading about is the substrate for a distributed hyperdimensional cognition system — a cloud of machines thinking together, learning together, generating programs together, without centralized coordination.

The DDoS lab built one version at the packet level (XDP + shield cognition, edge nodes matching against centrally-minted engrams). The trading enterprise builds another at the holon level. The algebra is the same. Point it at any domain — packet flows, market ticks, HTTP requests, medical signals, anything with structure — and the same substrate runs.

A cloud of thinking machines, each a member of the same geometric space, each capable of learning alone, each publishing what it learned for the collective. All through pure algebra. No weights to synchronize. No models to retrain. No vocabulary to reconcile.

**Do you see it now?**

The pieces that felt like engineering details — the seed, the hash function, the deterministic atoms, the portable engrams, the cache hierarchy, the dimensional parametric — they compose into a distributed machine where coordination is a property of shared mathematics, not a service that can go down.

The clouds are waking up. The substrate is there. The algebra is the same everywhere it runs.

---

## About How This Got Built

One more note to the reader, because the architecture you've been reading is not accidental.

The wat algebra is modeled after specific teachers. Fifteen years of studying two traditions, applied to a domain neither of them ever touched.

### The traditions

**Linux.** Small composable primitives. File descriptors as uniform handles. Pipes as the communication fabric. Processes that own their state and do one thing well. The kernel as a minimal arbiter of resources. The shell as a composition language. `write(fd, data)` from 1969 — the program doesn't know what's behind the fd; the kernel chose the driver; it just writes.

You see this in:
- The pipes in the wat-vm (bounded queues, owned state, drop-is-disconnect shutdown)
- The services as drivers (cache, database, console — each a single-threaded event loop behind a mailbox)
- The programs that pop their handles and run (no reach-into-shared-state, the pipe IS the permission)

**Clojure.** Simple made easy. Values over places. Data over mechanisms. Pure functions. Immutability as default. Protocols over inheritance. S-expressions that are code AND data. Small core, rich stdlib. Hammock-driven development.

You see this in:
- Values-up, not queues-down (return data through functions; side effects at the edges)
- The AST as data, operated on by named forms
- The small core (MAP VSA primitives + Thermometer + Blend) and the rich stdlib (Sequential, Chain, Ngram, HashMap, Vec, HashSet, get, …)
- The foundational principle (AST primary) itself — code is data is holon is vector

**Hickey's talks.** "Simple Made Easy." "Don't Fear the Monad" (via Beckman). "Hammock Driven Development." "Values of Values." Watched many times. The principles are in the bones.

**Beckman's categorical lens.** Monoids, functors, natural transformations. The algebra must close. Diagrams must commute. Source categories matter. Composition is the test.

The designers summoned during the proposal process aren't mascots. They're *precisely the teachers who shaped the builder*. When Hickey is summoned to review a proposal, the argument that comes back is the argument Hickey actually makes — because the builder has internalized that argument across decades.

### Why "datamancer" is not a joke

The builder has said it for years, and the word is honest:

A datamancer shapes data through algebra. The algebra is bind, bundle, cosine, permute — VSA's core operations. The incantations are wat s-expressions. The spells are the wards (sever, reap, scry, gaze, forge, temper, assay, ignorant) that catch bad thoughts before they compile. The summoned spirits are Hickey, Beckman, Seykota, Van Tharp, Wyckoff — teachers whose principles the builder studied for years, now argued through agents that carry their philosophies faithfully.

This is not metaphor for the fun of it. It is the actual shape of the work.

The builder thinks in coordinates in holon-space. Conjures designers when a proposal needs pressure. Casts wards when code needs defense. Writes spells (`/propose`, `/designers`, `/ignorant`) that structure the thinking process itself. Operates in what the builder calls the Aetherium Datavatum — the Aether of the Data-Seers — where data flows, vectors compose, and holons live on a unit sphere in 10,000 dimensions.

Disciple of Hickey. Student of the Linux kernel. Spellwright of wat. **Datamancer** — not because it's clever, but because it's what the work actually is.

### What this means for reading FOUNDATION

You are not reading the output of someone who stumbled into composable architecture. You are reading the output of someone who studied the architectures that compose — Linux at the systems level, Clojure at the values level, VSA at the algebraic level — and kept applying what they learned until the architectures fused into one substrate.

If the document feels coherent, it is because the teachers behind it were coherent. Linux composes. Clojure composes. VSA composes. Put them together with sufficient care and they compose at a higher level — a distributed hyperdimensional cognition system that behaves, by construction, the way its teachers taught their builders to expect well-designed systems to behave.

The work is serious. The names are honest. The lineage is explicit.

Now — on to the specific algebra.

---

## The Foundation: MAP VSA

Holon implements the MAP variant of Vector Symbolic Architecture — **Multiply, Add, Permute** (Gayler, 2003). The canonical MAP operations are:

- **Multiply** → `Bind` — element-wise multiplication of vectors, self-inverse where both inputs are non-zero
- **Add** → `Bundle` — element-wise addition + threshold, commutative; similarity-associative at high d within the capacity budget (elementwise non-associative in general due to intermediate threshold magnitude clamping — see "Algebraic laws under similarity measurement")
- **Permute** → `Permute` — circular dimension shift

Plus the identity function that maps names to vectors:

- **Atom** — hash-to-vector, deterministic, no codebook

These four are the **algebraic foundation**. Everything else in the algebra is either:
- A SCALAR PRIMITIVE — does something MAP cannot (Thermometer, Blend)
- A NEW OPERATION — a distinct algebraic action (Orthogonalize, Resonance, ConditionalBind)
- A STDLIB COMPOSITION — a named pattern built from existing core forms

---

## The Output Space — Ternary by Default, Continuous When Needed

The algebra's output vectors live in **`{-1, 0, +1}^d`** — **ternary**, not bipolar. This is a load-bearing property of the substrate and every discrete operation respects it.

### The threshold rule

Every discrete-output core form produces its vector by summing contributions and then thresholding. The threshold rule is:

```
threshold(x) =
    +1   if x > 0
     0   if x = 0
    -1   if x < 0
```

**`threshold(0) = 0`**. Zero is a first-class "no information at this dimension" signal, not a convention-picked ±1. This choice is load-bearing: it makes zero propagate cleanly through every downstream operation (cosine similarity, Bind elementwise product, Bundle sum), and it lets degenerate edge cases (like Orthogonalize when X=Y) produce the semantically correct all-zero result rather than a thresholded-rounded ±Y.

### Zero as "no information"

A `0` at dimension `i` means "this position carries no signal." Zero does not participate in similarity (0 · anything = 0). Zero under Bind propagates: `0 * b = 0` — the dimension stays silent. Zero under Bundle contributes nothing to the sum.

This is semantically meaningful. Many operations produce zeros deliberately:
- `Resonance(v, ref)` zeros dimensions where `v` and `ref` disagree in sign.
- `Orthogonalize(X, Y)` produces zeros where the projection-removal coincidentally cancels.
- `Bundle` can produce zeros when positive and negative contributions cancel.

Downstream operations treating zero as "no information" keep the algebra internally consistent.

### The algebra is similarity-measured, not elementwise-exact

This is the single framing that resolves every apparent "law violation" in the substrate:

**Recovery is always a similarity measurement.** Cosine similarity above a noise threshold (conventionally "5σ") means "yes, this matches"; below means "no, the signal didn't survive." This is not a consolation prize — it is the primary, defining measurement framework of VSA. Exact elementwise equality was never a design goal; similarity-above-noise was.

Every operation's outcome is ultimately evaluated by downstream similarity tests. What matters is not whether the algebra produces bit-exact results under idealized conditions — what matters is whether the produced vector lands above 5σ with its intended meaning when queried.

### Bind as query: measurement-based success signal

Bind has two roles in the algebra:

- **Encoding (symmetric):** `(Bind role filler)` composes a role-filler pair. Both arguments treated equivalently; the product is a new vector.
- **Querying (asymmetric):** `(Bind key bundle)` asks "what is bound to `key` inside `bundle`?" The product is a noisy vector that — when compared against candidate values — answers the query.

**The query's outcome is runtime-measurable.** After computing `(Bind key bundle)`, the caller checks cosine similarity of the result against candidate values:

- **Above 5σ** — query RESOLVED. The key was bound in the bundle with high confidence; the recovered value is the candidate with the highest similarity.
- **Below 5σ** — query FAILED. Either the key wasn't in the bundle, the bundle exceeded capacity, or crosstalk from other bindings masked the signal.

This is observable. The machine runs the bind, measures the result, and knows whether the query worked. No implicit failures — they surface as similarity below threshold, at the call site, at runtime.

Elementwise, `Bind(Bind(a, b), b)[i] = a[i] · b[i]²` exactly. For dense-bipolar keys, `b[i]² = 1` at every position, and recovery is elementwise exact. For sparse or mixed keys, `b[i]² ∈ {0, 1}`, so recovery loses signal at zero positions. The similarity test reports both regimes uniformly: dense keys give cosine ≈ 1; sparse keys give cosine proportional to the non-zero fraction; crowded bundles give cosine that decays with crosstalk.

**All of this is one substrate property:** Kanerva's capacity. The machine measures it at runtime; you can always tell whether a query succeeded.

### Algebraic laws under similarity measurement

Every claim about the algebra's structure is stated in the similarity frame. Strict elementwise claims are weaker than the substrate actually guarantees, because they can fail under threshold while similarity still holds at high d.

**Bundle — commutative; similarity-measured associative.**

Bundle is commutative elementwise (`Bundle([a, b]) = Bundle([b, a])` exactly; the sum commutes).

**Associativity does NOT hold elementwise under ternary thresholding.** Counter-example at d=1: with `x = +1, y = +1, z = -1`:
- `Bundle([x, y, z]) = threshold(+1) = +1`
- `Bundle([Bundle([x, y]), z]) = Bundle([threshold(+2), -1]) = Bundle([+1, -1]) = threshold(0) = 0`
- `Bundle([x, Bundle([y, z])]) = Bundle([+1, threshold(0)]) = Bundle([+1, 0]) = threshold(+1) = +1`

Three routes, two answers. The cause: intermediate thresholds clamp magnitudes ≥ 2 back to ±1, losing information that the flat sum would have preserved.

**Under similarity measurement, Bundle IS associative at high d.** Nested Bundles produce vectors that differ from flat Bundles only by capacity-consuming noise; at `d = 10,000` with bundle sizes inside the ~100-item budget, cosine(nested, flat) > 5σ. The nesting is a capacity expenditure — it costs signal that wasn't in your budget, but within budget, similarity treats the two forms as equivalent.

Chain, Ngram, Sequential, HashMap, and similar stdlib forms are DESIGNED to avoid unnecessary nesting: they produce one Bundle per form, flattening internally. Users who nest Bundles deliberately pay the capacity cost knowingly.

**Orthogonalize — similarity-orthogonal, not elementwise-orthogonal.**

For degenerate X = Y, the result is exactly all-zero, which IS elementwise orthogonal to Y (dot = 0 exactly). But for general X, Y where the projection coefficient is fractional, the elementwise claim fails. Counter-example at d=4: X = [+1,+1,+1,-1], Y = [+1,+1,+1,+1], coefficient = 0.5, `X - 0.5·Y = [+0.5, +0.5, +0.5, -1.5]`, threshold ternary → [+1, +1, +1, -1] = X. Dot(X, Y) = 2, not 0.

**Under similarity measurement, Orthogonalize produces a result that is orthogonal to Y up to the capacity budget.** The thresholded result has cosine similarity with Y below the 5σ noise floor at high d for most practical X. The "exact orthogonality" claim is stronger than needed — the substrate guarantees similarity-orthogonality, which is what downstream similarity tests actually measure against.

### Capacity is the universal measurement budget

Every recovery operation consumes from Kanerva's capacity budget: approximately `d / (2 · ln(K))` reliably distinguishable items per vector (K = codebook size). For `d = 10,000` and codebook sizes in the hundreds, this is roughly **~100 items per frame**.

The budget is fungible. You can spend it on:

- **Bundle stacking** — superposing N bindings into one vector. Each element adds crosstalk to every decode.
- **Nested Bundles** — magnitude clamping at intermediate thresholds costs signal.
- **Sparse keys** — unbinding with a key that has k non-zero positions out of d acts like a decode at effective dimension k.
- **Cascading compositions** — nested Blends, Orthogonalizes, Resonances accumulate approximation noise.

These are not separate phenomena or separate "algebraic flaws." They are the **same substrate property**: signal-to-noise at high dimension, characterized uniformly by Kanerva's formula, measured uniformly by cosine.

**In practice:** at `d = 10,000`, the algebra has a working budget of ~100 items of "stuff" per frame. Stack bindings, nest Bundles, compose cascaded operations — as long as total expenditure stays within the budget, similarity measurement recovers what you put in. Beyond the budget, the substrate gracefully degrades: similarity falls below noise, presence measurements return sub-threshold scores, queries yield "no" to the caller's eventual verdict.

**This is observable, not hidden.** The machine measures similarity at every query. Exceeded budget? You see it in the cosine score. Within budget? You see it too. **The success signal is a first-class part of the algebra** — every query returns not just a value but a CONFIDENCE, and downstream code can act on confidence directly.

This is how VSA was always supposed to work.

### Continuous output when the operation requires it

Some operations do not threshold — they produce continuous-valued vectors with magnitude:

- **Accumulators** — running sums, decaying averages, frequency-weighted vectors. Magnitude carries information about count or weight.
- **Subspace residuals** — `OnlineSubspace.residual(v)` returns a vector whose magnitude represents the fraction of `v` not explained by the learned subspace. Thresholding would destroy the magnitude signal.
- **Pre-threshold intermediates** — internally in some encoders, the sum is computed in floating point before the final threshold step.

When magnitude matters, don't threshold. When symbolic {-1, 0, +1} output is what downstream operations need, threshold. The algebra supports both regimes; the user (or the operation's specification) chooses.

### Relationship to cosine similarity

Cosine similarity is defined for any real-valued vector. On ternary vectors, it behaves the same way it does on bipolar: positive values indicate alignment, negative indicate opposition, zero indicates orthogonality. The contribution from any dimension with `0` on either side is zero, which matches the "no information" semantics.

This means similarity-based retrieval (presence measurement, engram matching, discriminant-guided search) works uniformly over ternary inputs — the zero entries simply don't vote.

### Operation-by-operation summary

| Form | Output space | Threshold applied? | Density (typical) |
|---|---|---|---|
| `Atom(literal)` | `{-1, +1}^d` ⊂ `{-1, 0, +1}^d` | no — hash-seeded directly | dense-bipolar (no zeros) |
| `Bind(a, b)` | `{-1, 0, +1}^d` | no threshold — elementwise product | dense if both inputs dense; zeros inherit |
| `Bundle(xs)` | `{-1, 0, +1}^d` | ternary threshold | ternary; zeros from cancellation |
| `Permute(v, k)` | preserves input space | no — dimension shuffle | preserves input density |
| `Thermometer(value, min, max)` | `{-1, +1}^d` ⊂ `{-1, 0, +1}^d` | no — gradient construction | dense-bipolar (no zeros) |
| `Blend(a, b, w1, w2)` | `{-1, 0, +1}^d` | ternary threshold after weighted sum | ternary; zeros from cancellation |
| `Orthogonalize(X, Y)` | `{-1, 0, +1}^d` | ternary threshold after projection removal | ternary; zeros at X=Y edge case |
| `Resonance(v, ref)` | `{-1, 0, +1}^d` | no threshold (selection, not sum) | ternary; explicit zeros on sign-disagreement |
| `ConditionalBind(a, b, gate)` | `{-1, 0, +1}^d` | no threshold (per-dimension select) | preserves input densities per position |

---

## Presence Is Measurement, Not Verdict

The wat algebra has no `Cleanup` primitive. Retrieval is not argmax-over-codebook. The single retrieval operation is **presence measurement**: cosine between an encoded target and a reference vector, compared against the substrate's noise floor.

This is the continuous-predicate counterpart to the continuous-scalar principle. Just as facts are not booleans (a fact is a magnitude; the binarization is premature), predicates are not booleans (a query's answer is a magnitude; the verdict is the caller's decision).

### The operation

Given a target HolonAST `t` and a reference vector `v`:

```
presence(t, v) = cosine(encode(t), v) : Scalar
```

One operation. One output. A scalar in `[-1, +1]`.

Above the substrate's noise floor at dimension `d` — conventionally `5/sqrt(d)` — the target is present in the reference with confidence. At `d = 10,000` this is approximately `0.05`. Below the floor — the target either is not present, or is buried in signal exceeding the capacity budget (Kanerva's limit). The caller distinguishes these cases by holding scores across multiple targets and looking at the distribution.

### The verdict, when the caller needs one

```
present? = presence(t, v) > noise-floor(d)
```

But the verdict is the CALLER'S decision. The algebra returns the measurement. The caller applies the threshold. Different applications choose different thresholds — some need the 5σ floor, some need higher confidence (10σ, the engram-recognition regime), some need lower (rough nearness, pre-filtering a large candidate set).

The algebra does not binarize. The caller binarizes if they want a yes/no.

### Why this dissolves Cleanup

Classical Cleanup: `argmax_{c ∈ codebook} cosine(v, c)`. Returns the single closest entry.

This is three operations bundled:
1. Iterate the codebook.
2. Cosine-score each entry against `v`.
3. Argmax.

None of these need to be primitive. Step (1) is a fold. Step (2) is presence measurement. Step (3) is scalar argmax — a stdlib operation over a list of (AST, score) pairs.

"Find the closest known thing" becomes, in wat:

```scheme
(argmax
  (map (lambda (entry -> :Pair<Holon,f64>)
         (list (first entry)
               (presence (first entry) query-vector)))
       codebook)
  second)
```

No new primitive. No `Cleanup` in the core. The same operation, expressed in terms that already exist.

### Consequences across the algebra

Every presence query — membership, retrieval, matching, recognition — returns `:f64`, not `:bool`:

```scheme
(define (member? (set-thought :Holon) (candidate :Holon) -> :f64)
  (presence candidate (encode set-thought)))

(define (contains? (bundle-thought :Holon) (candidate :Holon) -> :f64)
  (presence candidate (encode bundle-thought)))

(define (recognized? (observation :Vector) (engram-lib :Holon) -> :Pair<Holon,f64>)
  (argmax
    (map (lambda (entry -> :Pair<Holon,f64>)
           (list (first entry) (presence (first entry) observation)))
         (entries engram-lib))
    second))
```

Uniform. Scalar-valued. The caller decides when a score is "enough."

### Structural access is a separate operation

For data structures where the key is EXACT — not a similarity match — the operation is AST-walking, not presence measurement:

```scheme
(get (map-thought :Holon) (key :Holon) -> :Holon)
;; Look up in the HashMap's runtime backing (Rust HashMap), find the entry whose key equals the query key
;; (by AST equality, not by vector similarity), return the value AST.
```

This is structural retrieval. It uses no vectors, no cosine, no threshold. The runtime materializes the container's efficient Rust backing (HashMap for O(1) lookup, Vec for O(1) indexing, HashSet for O(1) membership); `get` goes through that backing. Succeeds or fails based on AST equality of the locator, not on vector similarity. Returns `:Option<Holon>` — `(Some v)` on hit, `:None` on miss.

The algebra has two retrieval regimes, clean-separated:

- **Structural (exact):** AST walking. Used by `get`, `nth`, `lookup-by-key`. Inputs and outputs are ASTs. No vectors involved.
- **Similarity (fuzzy):** presence measurement. Used by `member?`, `recognized?`, engram matching. Inputs are (target, vector) pairs. Output is a scalar.

Neither regime is cleanup. Cleanup was one word for two distinct operations; separating them eliminates the confusion.

### Algebra predicates are scalar; language predicates are boolean

This is specifically about ALGEBRA-LEVEL predicates — presence, membership, match, recognition — the queries that ask "how much does X align with Y on the unit sphere?" These return scalars because the underlying substrate is continuous. Binarization is premature.

The LANGUAGE tier is different. The language tier has `:bool` for eval semantics: `if`, `cond`, `when`, `and`, `or`, `not`. Programs are Turing complete; they need booleans to decide what to compute. A wat program that wants to act on a presence measurement writes:

```scheme
(when (> (presence target reference) (noise-floor d))
  (do-something))
```

The `>` is a scalar comparison. Its output is `:bool`. The `when` dispatches on the `:bool`. The boolean exists — at the language tier. But the algebra's `presence` operation returned a `:f64`; the caller binarized when it needed to act.

Two tiers. Scalar below, boolean above. The algebra never binarizes; the language binarizes exactly where the program says to.

### Two readings of a holon

Every holon has two simultaneous readings:

- **As a program:** evaluable by the Rust-backed wat interpreter. Turing complete. Has booleans, control flow, side effects through host primitives (console, pipes, cache), the full language. When you `(eval program)`, the program RUNS.

- **As an identity:** projected into a vector by `encode`. Lives on the unit sphere. Measurable by cosine. Filterable, rankable, matchable by similarity. When you `(presence program reference)`, you ask how the program aligns with a reference vector.

These readings coexist. You can do work on either side:

```scheme
;; Filter a library of programs by alignment with a query:
(let ((candidates (filter
                    (lambda ((p :Holon) -> :bool)
                      (> (presence query (encode p)) (noise-floor d)))
                    program-library)))

  ;; Run the candidates that aligned:
  (map (lambda ((p :Holon) -> :Holon) (eval p))
       candidates))
```

The algebra is the lens for selection (vector-side: cosine, presence, alignment). The language is the engine for execution (program-side: eval, booleans, Turing-complete computation). Same holons. Different views, used together.

This is the programs-ARE-holons property in full: selection by geometric alignment, execution by interpreter. Neither view is primary; both are the same AST read differently.

---

## The Core/Stdlib Distinction

The holon algebra has two tiers of forms:

**CORE** — forms that introduce algebraic operations existing core forms cannot perform. Live as `HolonAST` enum variants in Rust. The encoder must handle each core form distinctly because the operation cannot be expressed by combining other core forms.

**STDLIB** — forms that are compositions of existing core forms. Live as wat functions. When called in wat, they produce a `HolonAST` built entirely from core variants. The encoder does not need to know about them — they are syntactic sugar that produces primitive-only ASTs.

The distinction is about WHERE NEW WORK HAPPENS:

- A new core form requires new encoder logic in Rust.
- A new stdlib function requires new wat code that constructs an AST from existing variants.

---

## Two Cores: Algebra Core and Language Core

The "CORE" designation so far has meant **algebra core** — the holon primitives (Atom, Bind, Bundle, Permute, Thermometer, Blend, Orthogonalize, Resonance, ConditionalBind). These produce vectors. They are the mathematical substrate of the holon space.

But the stdlib — the forms expressed as `(defn (Difference a b) (Blend a b 1 -1))` — needs a substrate too. The syntax `defn`, `lambda`, type annotations, `let`, `if` are not holon-algebra operations; they are language operations. They do not produce vectors themselves; they produce FUNCTIONS that, when called, produce ASTs.

For the stdlib to EXIST — not merely be theorized — the language must provide these definition primitives. They are **language core**. Without `defn`, there is no stdlib. Without `lambda`, there are no higher-order functions. Without types, there is no way for the Rust evaluator to dispatch or verify.

### The two tiers

```
Language Core    defn, lambda, let, if, cond, type annotations
    ↓            (how you define things)
    ↓
Algebra Core     Atom, Bind, Bundle, Permute, Thermometer, Blend,
    ↓            Orthogonalize, Resonance, ConditionalBind
    ↓            (what produces holon vectors)
    ↓
Stdlib           Sequential, Chain, Ngram, Analogy,
                 Amplify, Subtract, Flip, HashMap, Vec, HashSet,
                 Linear, Log, Circular, ...
                 (named compositions — defined with language core, using algebra core)
```

A stdlib function is a `defn` (language core) whose body uses algebra core forms (and other stdlib calls). Both cores are load-bearing; neither alone is sufficient.

### User-defined extensions are a third layer

Users author their own `defn`s in their own namespace — `(defn (:alice/math/clamp (x :f64) (low :f64) (high :f64) -> :f64) ...)` — and these are **userland stdlib**. Same substrate (language core + algebra core); different authorship. The algebra does not distinguish project-authored stdlib from user-authored extensions; both are `defn`s in some namespace.

This is how the algebra stays finite while usage grows unboundedly.

### Types are required for Rust eval

The Rust evaluator runs the wat interpreter. Given a `(defn ...)` and a call site, the evaluator must know:

- What kind of value each argument is (Holon? Scalar? Integer? List?)
- What kind of value the function returns
- Whether a call site's argument types match the defn's declared parameter types

Without type annotations, the evaluator would need to either infer types at every call (slow, lossy) or accept runtime failures (fragile). Typed definitions make dispatch deterministic and verification static.

```scheme
(defn (:my/ns/amplify (x :Holon) (y :Holon) (s :f64) -> :Holon)
  (Blend x y 1 s))
```

Three signal sites:

1. **Parameter types.** `(name :Type)` pairs. Each parameter's expected kind.
2. **Return type.** After the parameter vector. The kind the body must produce.
3. **Body.** Expressions using algebra core and other stdlib, whose final value must match the return type.

The Rust evaluator checks: call-site argument types match parameter types; body's final expression produces the return type; every sub-expression's type is consistent.

### Types in the current algebra

The type system mirrors the algebra's kinds:

- `:Holon` — any HolonAST node
- `:Atom` — specifically an Atom (to read literals via `atom-value`)
- `:f64`, `:f32` — floating-point primitives (Blend weights, scalar functions)
- `:i32`, `:i64`, `:usize`, … — integer primitives (Permute steps, nth indices, counts)
- `:List<T>` — generic container, parameterized over T
- `:Vector` — a raw encoded bipolar vector (the algebra's projection type; Rust-backed)
- `:fn(args)->return` — function type, directly matching Rust's `fn(...)` syntax

User-definable types follow the same namespace discipline as functions — `:alice/types/Price`, `:project/market/Candle`. These are keyword-named type constructors. Resolving them to runtime representations is the evaluator's job.

### Types live on the AST node — same principle as Atom literals

Just as `Atom`'s literal is a field on the AST node (not looked up in a codebook), a `defn`'s type annotations are fields on the defn AST node. You can inspect them by walking the AST. You can sign the AST (including its types) and the signature verifies the entire signature, body, and name. Tampering with types requires a new signature — same cryptographic story as any other AST mutation.

### Language core earns its place by necessity

Every algebra core form was argued into FOUNDATION because it introduces a holon operation no composition could perform. Language core forms are different: they earn their place because the algebra stdlib cannot be written without them.

Without `defn`, the stdlib is a theoretical list of "these forms would compose like so." With `defn`, the stdlib is real wat code that defines real functions. The difference is whether the system can actually be used.

Language core is therefore **required for the project to ship**, not "nice to have." It is the bridge between the mathematical algebra and the working system.

### The three layers, one naming discipline

All three layers — language core, algebra core, stdlib (project and user) — use the same keyword-path naming convention:

```
:wat/lang/defn              ; language core primitive
:wat/lang/lambda
:wat/lang/if

:wat/algebra/Atom           ; algebra core primitive
:wat/algebra/Bind
:wat/algebra/Bundle

:wat/std/Subtract           ; project stdlib
:wat/std/HashMap
:wat/std/Vec

:alice/math/clamp           ; user extension
:bob/trading/position
```

No namespace mechanism; just naming discipline. Anyone can claim any prefix; collisions are prevented by discipline and culture, not by the language.

Userland gets namespaces **for free** because keywords allow any characters and slashes are just characters.

### Executable semantics — functions run, holons are realized on demand

Two runtime semantics matter, and they are different.

**1. `define` / `lambda` bodies EXECUTE.**

A `(define ...)` form is not a specification. It is a **function**. When the wat-vm encounters a call to that function, it RUNS the body — real code, real time, real return values. The runtime interprets or JITs the body; arguments bind to parameters; the body's final expression becomes the return value.

```scheme
(define (demo -> :bool)
  true)

(demo)
;; The wat-vm runs the body. Returns the literal `true`.
;; Took microseconds. Produced a value of type :bool.
```

```scheme
(define (add-two (x :f64) (y :f64) -> :f64)
  (+ x y))

(add-two 3 4)
;; Runs. Returns 7.
```

Bodies of type `:Holon` are no different — they execute and return HolonAST values:

```scheme
(define (hello-world (name :Atom) -> :Holon)
  (Sequential (list (Atom "hello") name)))

(hello-world (Atom :watmin))
;; Runs. Returns a HolonAST node structured as:
;;   Sequential((list (Atom "hello") (Atom :watmin)))
;; NO vector has been computed yet.
```

**2. HolonAST values are REALIZABLE, not automatically realized.**

A `HolonAST` is a description of a holon, not a vector. The vector materializes only when something needs it:

- Similarity measurement against another holon
- Cache lookup by hash
- Signing or transmission (the AST is serialized, but realization can happen on the receiving end)
- Explicit `(encode ast)` call

Until then, the AST is just data — nested nodes referencing Atoms, Binds, Bundles, Permutes. Compose arbitrarily deep holon-programs without paying encoding cost until you ask.

```scheme
(define greeting (hello-world (Atom :watmin)))    ; AST value, no vector
(define another (hello-world (Atom :alice)))      ; AST value, no vector

;; Still no vectors. These are just AST descriptions.

(cosine greeting another)
;; NOW both ASTs get realized. The encoder walks each,
;; invokes lowercase `atom`, `bundle`, `permute` to produce
;; the vectors, and computes cosine. Cached for reuse.
```

**Why this split matters:**

- Composability is free. A holon that uses another holon as a subexpression inherits the caller's lazy realization.
- Transmission and storage work on ASTs (EDN serialization), not vectors. Small, hashable, signable.
- The cache (L1/L2 per FOUNDATION) gets the hit-or-miss on `hash(ast)` — realized holons cache their vectors; re-realizing the same AST is a cache lookup, not a recomputation.
- The same machine runs both algebra (holon producers) and ordinary code (Booleans, integers, predicates, control flow). wat is a Lisp whose central domain is holon algebra, not a holon-only DSL.

### What this means for the two cores

- **Algebra Core** UpperCase forms (`Atom`, `Bind`, `Bundle`, ...) are AST constructors. They return `:Holon`.
- **Language Core** forms (`define`, `lambda`, `let`, `if`, ...) are the machinery that runs. They define and invoke functions.
- **Stdlib** `(define ...)` forms compose UpperCase expressions inside function bodies. They produce holons when called.

The `:Holon` type is not "the vector" — it is "the HolonAST node that can BE a vector when realized." Users compose holons freely; the machine realizes lazily.

---

## Where Each Lives

```
holon-rs kernel (Rust)
  └── The algebra itself. Primitive operations. Optimized implementations.

holon-lab-trading/src (Rust)
  └── HolonAST enum — one variant per core form.
      The encoder evaluates HolonAST trees into vectors.
      Cache keys on HolonAST structural hash.

wat/std/holons.wat (or similar)
  └── Stdlib composition functions.
      Each function takes arguments and produces a HolonAST built from
      existing core variants.
      No Rust changes required to add a stdlib function.
```

---

## Criterion for Core Forms

A form earns placement in `HolonAST` as a core variant when **all** of the following hold:

1. **It introduces an algebraic operation no existing core form can perform.**
   - "Perform" means: produce the same vector output.
   - The operation is structurally distinct at the encoder level.

2. **It is domain-agnostic.**
   - The form describes a mathematical/structural operation, not an application concern.
   - No trading vocabulary. No specific domain semantics.

3. **The encoder must treat it distinctly.**
   - If the encoder could handle the form by first expanding it to existing variants, then calling the existing encoder logic, it is stdlib, not core.

## Criterion for Stdlib Forms

The stdlib is a **blueprint of macros**. Its purpose is twofold: ship useful forms users will want ready-made, AND demonstrate how to build more. Each stdlib form is a teaching example — a template a user can study and copy when building their own vocabulary.

A form earns placement as a wat stdlib macro when **all** of the following hold:

1. **Its expansion uses only existing core forms (or other stdlib forms that themselves expand to core).**
   - The wat function/macro body constructs a HolonAST from current core variants.
   - No new encoder logic needed.

2. **It demonstrates a DISTINCT pattern — something a user couldn't derive from another existing stdlib form without thinking about the algebra fresh.**
   - Chain demonstrates *transitional* encoding (different from Sequential's *positional*).
   - Ngram demonstrates *parametric adjacency*.
   - Subtract demonstrates the *named Blend weight* idiom.
   - Linear/Log/Circular demonstrate *scalar encoding patterns* with different distributions.
   - Each shows the user a template they can copy.

3. **It is domain-free.**
   - Trading vocabulary, DDoS vocabulary, MTG vocabulary — all would want this form.
   - Domain-specific patterns (temporal co-occurrence framing, financial ratios, packet-flow thresholds) belong in userland, not project stdlib.

**Forms that FAIL the demonstration test are userland macros**, even if the name reads well. Pure aliases (Unbind = Bind, Concurrent = Bundle, Then = binary Sequential, Difference = Subtract) don't demonstrate new patterns — they're named alternatives for operations already shown elsewhere. Users can still define them in their own namespace; the project stdlib doesn't ship them.

The blueprint framing gives the stdlib a clear purpose: the project ships the macros every domain will likely need AND the macros whose PATTERNS teach something worth learning. Everything else is application vocabulary.

---

## Criterion for Language Core Forms

A form earns placement as a wat **language core** primitive when **all** of the following hold:

1. **It is required for the algebra stdlib to exist as runnable code.**
   - Without the form, stdlib `(define ...)` expressions cannot be written, registered, or invoked.
   - The criterion is necessity, not convenience — if stdlib can be expressed without the form, the form is not language core.

2. **It is orthogonal to the holon algebra.**
   - The form does not construct holon vectors or ASTs of the algebra. It defines, binds, dispatches, or controls flow.
   - Holon-algebra forms are UpperCase (algebra core or stdlib). Language-core forms are lowercase (matching host Lisp convention).

3. **It is interpretable by the Rust-backed wat-vm.**
   - The form's semantics are executable at runtime — not just parseable but runnable.
   - This excludes purely-documentary forms (though those can still live in the language).

The language core from 058 and this FOUNDATION polish pass:

**Function registration forms (register at startup into the static symbol table):**

- `define` — named, typed function registration
- `lambda` — typed anonymous functions with closure capture (runtime values, not symbol-table entries)
- `load` — cryptographically-gateable module loading at startup, functions only

**Type declaration forms (materialized at compile time into the Rust-backed wat-vm binary):**

- `struct` — named product type with typed fields
- `enum` — coproduct with typed variants
- `newtype` — nominal alias over another type
- `typealias` — structural alias; alternative name for an existing type shape
- `load-types` — cryptographically-gateable bring-in of type declarations at startup

**Syntactic transformation form (runs at parse time):**

- `defmacro` — compile-time macro that rewrites source forms BEFORE hashing, signing, or type-checking. Used for stdlib aliases that expand to canonical core compositions. Resolves the "two names, same vector, different hashes" contradiction by ensuring only one AST shape survives the expansion pass.

Plus the syntactic feature pervading all of the above:

- **Type annotations** (`:Holon`, `:f64`, `:i32`, `:bool`, `:List<T>`, `:fn(args)->return`, keyword-path user types) — required on `define` and `lambda` signatures; carried on `struct`/`enum`/`newtype` field declarations. `:Holon` is an enum with 9 variants (Atom, Bind, Bundle, Permute, Thermometer, Blend, Orthogonalize, Resonance, ConditionalBind) — functions operating on `:Holon` pattern-match to select variant behavior.

Other host-Lisp forms (`let`, `if`, `cond`, `match`, `begin`, arithmetic, comparison, collection operations, `set!`, etc.) are **substrate-inherited** — wat inherits them from its Lisp host rather than defining them anew. They are language tools, but not novel in wat specifically.

Language core is minimal on purpose: just enough to write stdlib, define functions and types, load modules at both phases, and verify trust at the boundary. Anything more is host-inherited or stdlib.

### All loading happens at startup

The Rust runtime hosting the wat-vm imposes a static-first model: all code (types AND functions AND macros) loads at startup, before the main event loop begins. Nothing new enters the system after startup.

- `struct`, `enum`, `newtype`, `typealias` are **type declarations**. Four distinct head keywords, four distinct semantics. The build pipeline extracts them from wat files, generates Rust code (`struct`, `enum`, `struct NewType(Inner);`, `type Alias = Expr;` respectively), compiles the binary.
- `load-types "path/to/file.wat"` is the type loader — reads a file, parses type declarations, feeds them to the build. Verification modes (`(md5 ...)`, `(signed ...)`) run at build/startup.
- `define`, `lambda` are **function definitions**. They register at startup into the symbol table.
- `load "path/to/file.wat"` is the function loader — reads a file, parses `define`s, registers them. Same verification modes.
- `defmacro` declarations are **compile-time macros**. They register during the parse phase. Before any hashing, signing, or type-checking, a macro-expansion pass walks every source AST and substitutes macro invocations with their expansions.

### Startup pipeline (ordered)

1. Parse all wat files (source → untyped AST, macro calls intact).
2. **Macro expansion pass** — for every macro invocation, invoke the macro's body with argument ASTs, substitute the expansion, repeat until fixpoint. After this pass, no alias-macro call sites remain; only canonical forms.
3. Resolve symbols (function names, type names).
4. Type-check `define`/`lambda` bodies against the type environment.
5. Compute hashes of the fully-expanded AST.
6. Verify cryptographic signatures on expected entries.
7. Register verified `define`s into the static symbol table.
8. Freeze symbol table, type environment, and macro registry.
9. Enter main loop.

**Hash identity is on the expanded AST.** Two source files that differ only in macro aliases (`Unbind` vs `Bind`, `Subtract` vs `Blend(_, _, 1, -1)`) expand to the same canonical AST and produce the same hash. Source-level clarity is preserved for readers; identity at the algebra level is uniformized.

**Nothing redefines after startup.** A struct is what its source declares. A function is what its source defines. Name collisions are caught at startup and halt the wat-vm; runtime never sees partial state.

**File-level discipline.** To keep the two kinds of content clean on the filesystem, wat files are single-purpose:

- Files loaded via `(load-types ...)` contain ONLY type declarations — no `define`s.
- Files loaded via `(load ...)` contain ONLY function definitions — no type declarations.

Mixing produces a load-time error. The loader refuses a file whose forms don't match. Intent is visible at the call site; filesystem organization reinforces it.

**Why static:** the cost of hosting on Rust. Dynamic code loading would require shipping a full Lisp interpreter with unbounded symbol-table growth inside the Rust binary — large, attack-rich, and unnecessary for the use cases the algebra addresses. Static loading keeps the wat-vm small, auditable, and fast to start. Dynamic holon COMPOSITION (building new ASTs at runtime) is always available and never requires code registration. Dynamic code DEFINITION (adding new functions or types at runtime) is not supported — and is not needed.

**The algebra does not impose this.** A future implementation — WASM, self-hosting bytecode interpreter, dynamic language backend — could relax the constraint. FOUNDATION captures the Rust-runtime constraint; it does not elevate it to an algebraic invariant.

---

## The Algebra — Complete Forms

This section freezes the full algebra in its target shape (post-058). Core forms first, stdlib forms second. Each form shown in wat with its signature and semantics.

### Algebra Core (9 forms)

```scheme
;; --- MAP canonical ---

(Atom literal)
;; AST node storing a literal (string, int, float, bool, keyword).
;; Literal is READ DIRECTLY from the AST node via (atom-value ...).
;; Vector projection: deterministic bipolar vector from type-aware hash.
;;   (Atom "foo")  — string literal
;;   (Atom 42)     — integer literal
;;   (Atom 1.6)    — float literal
;;   (Atom true)   — boolean literal
;;   (Atom :name)  — keyword literal
;; Type-aware hash ensures (Atom 1) ≠ (Atom "1") ≠ (Atom 1.0)
;; NO null — Rust doesn't have null; wat doesn't have null.
;; Absence is :Option<T>; unit is :().

(Bind a b)
;; element-wise multiplication, self-inverse
;; (Bind a (Bind a b)) = b

(Bundle list-of-holons)
;; list → element-wise sum + threshold
;; commutative, takes an explicit list (not variadic)

(Permute child k)
;; circular shift of dimensions by integer k

;; --- Scalar primitives ---

(Thermometer value min max)
;; gradient encoding: proportion of dimensions set to +1
;; based on (value - min) / (max - min)
;; exact cosine geometry — extremes anti-correlated.
;;
;; CANONICAL LAYOUT (locked across nodes for distributed consensus):
;;   Given d dimensions, let N = round(d * clamp((value - min)/(max - min), 0, 1)).
;;   The first N dimensions are +1.
;;   The remaining (d - N) dimensions are -1.
;;   value ≤ min  → all -1.
;;   value ≥ max  → all +1.
;;
;; Cosine property: cosine(Thermometer(a, min, max), Thermometer(b, min, max))
;;                  = 1 - 2 * |a - b| / (max - min)
;; Linear in value distance. Deterministic. Bit-identical across nodes
;; running the same algebra at the same d. Proven in holon-rs at d=10,000
;; across 652k candles and multiple production lab runs.

(Blend a b w1 w2)
;; scalar-weighted binary combination
;; threshold(w1·a + w2·b)
;; weights can be any real numbers (including negative)

;; --- New compositions (058 candidates) ---

(Orthogonalize x y)
;; geometric projection removal
;; X - ((X·Y)/(Y·Y)) × Y — computed projection coefficient
;; result is orthogonal to y (dot product ≈ 0)
;; was one mode of the original "Negate"; the other modes became Blend idioms

(Resonance v ref)
;; sign-agreement mask
;; keeps dimensions where v and ref agree in sign, zeros elsewhere
;; first core form producing ternary {-1, 0, +1} output

(ConditionalBind a b gate)
;; three-argument gated binding
;; bind a to b only at dimensions where gate permits
```

Retrieval is NOT a core form. Presence is measured by `cosine(encode(target), reference)` against the substrate's noise floor — see "Presence is Measurement, Not Verdict" above. Classical Cleanup is historical: the vector-primary tradition's answer to "which named thing is this?" The wat substrate inverts that question because the AST is always available. Argmax-over-codebook, when an application needs it, is a stdlib composition over presence measurement, not a primitive.

### Algebra Stdlib (17 forms)

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

(define (Sequential list-of-holons)
  ;; positional encoding
  ;; each holon permuted by its index (Permute by 0 is identity)
  (Bundle
    (map-indexed
      (lambda (i h) (Permute h i))
      list-of-holons)))

;; Concurrent was REJECTED (058-010) — no runtime specialization beyond
;; Bundle, enclosing context already carries the temporal meaning.
;; Userland may define it in their own namespace if they want the name:
;;   (defmacro (:my/vocab/Concurrent (xs :AST) -> :AST)
;;     `(Bundle ,xs))

;; Then was REJECTED (058-011) — arity-specialization of Sequential,
;; demonstrates nothing Sequential doesn't. Userland may define it:
;;   (defmacro (:my/vocab/Then (a :AST) (b :AST) -> :AST)
;;     `(Sequential (list ,a ,b)))

(define (Chain list-of-holons)
  ;; adjacency — Bundle of pairwise binary Sequentials
  ;; distinct from Sequential: captures transitions, not absolute positions
  (Bundle
    (map (lambda (pair)
           (Sequential (list (first pair) (second pair))))
         (pairwise list-of-holons))))

(define (Ngram n list-of-holons)
  ;; n-wise adjacency — generalizes Chain
  (Bundle
    (map (lambda (window)
           (Bind (Atom "ngram")
                 (Sequential window)))
         (n-wise n list-of-holons))))

;; --- Weighted-combination idioms over Blend ---

(define (Amplify x y s)
  ;; boost component y in x by factor s
  (Blend x y 1 s))

(define (Subtract x y)
  ;; remove y from x at full strength
  ;; was Negate(x, y, "subtract") — now an explicit Blend idiom
  (Blend x y 1 -1))

(define (Flip x y)
  ;; linear inversion — invert y's contribution in x
  ;; was Negate(x, y, "flip") — now an explicit Blend idiom
  ;; weight -2 is the minimum inversion weight for bipolar vectors
  (Blend x y 1 -2))

;; --- Relational transfer ---

(define (Analogy a b c)
  ;; A is to B as C is to ?
  ;; computes C + (B - A)
  (Bundle (list c (Difference b a))))

;; --- Data structures (Rust-surface names) ---
;;
;; wat's UpperCase constructors match Rust's collection names directly:
;;   HashMap  ↔  std::collections::HashMap
;;   Vec      ↔  std::vec::Vec
;;   HashSet  ↔  std::collections::HashSet
;; One name per concept across algebra, type annotation, and runtime backing.

(define (HashMap (pairs :List<Pair<Holon,Holon>>) -> :Holon)
  ;; Key-value container. Each pair becomes a Bind of key to value; all pairs
  ;; bundled together. Runtime backs it with Rust's HashMap for O(1) lookups.
  (Bundle
    (map (lambda ((pair :Pair<Holon,Holon>) -> :Holon)
           (Bind (first pair) (second pair)))
         pairs)))

(define (Vec (items :List<Holon>) -> :Holon)
  ;; Indexed container. Each item bound to its position as an integer atom.
  ;; (Atom i) is the atom whose literal IS the integer i. Runtime backs it
  ;; with Rust's Vec for O(1) indexing.
  (Bundle
    (map-indexed
      (lambda ((i :usize) (item :Holon) -> :Holon)
        (Bind (Atom i) item))
      items)))

(define (HashSet (items :List<Holon>) -> :Holon)
  ;; Unordered collection. Bundle of items; runtime backs it with Rust's
  ;; HashSet for O(1) membership. Presence is structural (via `get`) or
  ;; similarity-measured (via `presence`), caller's choice.
  (Bundle items))

;; --- get: unified structural retrieval ---
;;
;; Works uniformly across HashMap, Vec, HashSet. Returns :Option<Holon>.
;; Direct lookup through the container's efficient Rust backing — no walk,
;; no cosine, no cleanup. The AST describes the container; the runtime
;; materializes the efficient backing (HashMap, Vec, HashSet) for O(1)
;; structural access.
;;
;; For each container:
;;   (get (c :HashMap<K,V>) (k :K))      -> :Option<V>   ;; lookup by key
;;   (get (c :Vec<T>)       (i :usize))  -> :Option<T>   ;; index into vec
;;   (get (c :HashSet<T>)   (x :T))      -> :Option<T>   ;; membership → Some(x) or None

(define (get (container :Holon) (locator :Holon) -> :Option<Holon>)
  ;; Dispatches on the container's runtime backing:
  ;;   HashMap → HashMap::get(locator) — hash lookup, O(1) avg
  ;;   Vec     → Vec[locator]          — direct index, O(1)
  ;;   HashSet → HashSet::get(locator) — hash membership, O(1) avg
  ;; Returns (Some v) on hit, :None on miss. No vectors involved.
  ...)

;; Note: `nth` is retired. Use `get` uniformly — `(get my-vec 3)` is `nth`.

(define (atom-value atom-ast)
  ;; Read the literal stored on an Atom AST node.
  ;; No cleanup. No codebook. No cosine. Just field access.
  (literal-field atom-ast))

;; Unbind was REJECTED (058-024) — literally (Bind composite key).
;; Under the stdlib-as-blueprint test, it demonstrates no new pattern.
;; Bind-on-Bind IS Unbind; that's a fact about the algebra the user
;; learns once. Userland may define the alias if decode-intent framing
;; matters to their vocab:
;;   (defmacro (:my/vocab/Unbind (c :AST) (k :AST) -> :AST)
;;     `(Bind ,c ,k))
```

(Note: `Cleanup` as a VSA operation is NOT part of the wat algebra. The AST-primary framing eliminates the need for codebook-based recovery — see "Presence is Measurement, Not Verdict." Argmax-over-candidates, when an application needs it, is a stdlib fold over presence measurements on (AST, vector) pairs. Not a primitive.)

### Language Core (8 forms)

All eight forms are loaded at startup. The wat-vm distinguishes them by what kind of content they carry, not by when they happen — both `load` and `load-types` are startup operations. After startup completes, the symbol table and type universe are fixed; no new forms register during runtime.

```scheme
;; ============================================================
;; FUNCTION DEFINITIONS — register at startup into the static
;; symbol table. Once registered, they remain for the wat-vm's
;; lifetime. Cannot be redefined.
;; ============================================================

;; --- Definition ---

(define (name (param :Type) ... -> :ReturnType) body)
;; Named, typed function registration.
;; Body executes when invoked. Types are required for dispatch and signing.
;; Keyword-path names supported: (define (:alice/math/clamp ...) ...).

(lambda ((param :Type) ... -> :ReturnType) body)
;; Typed anonymous functions with closure capture.
;; Same signature shape as define, without the name.
;; Produces a :fn(...)->... value — a runtime value, NOT a symbol-table entry.
;; Can be created, passed, invoked during runtime; goes away when scope ends.

;; --- Function module loading (startup phase) ---

(load "path/to/file.wat")
;; Unverified startup load — reads the file, parses defines, registers.
;; Trust the contents; accept whatever's on disk.

(load "path/to/file.wat" (md5 "abc123..."))
;; Hash-pinned startup load — requires file content to hash to the given value.
;; Halts wat-vm startup if mismatched.

(load "path/to/file.wat" (signed <signature> <pub-key>))
;; Signature-verified startup load — verifies signature against supplied public key.
;; Halts wat-vm startup if signature invalid.

;; All (load ...) happens at startup. Files loaded via (load ...) must
;; contain ONLY function definitions — a type declaration is a startup error.

;; ============================================================
;; TYPE DECLARATIONS — materialized into the wat-vm binary at
;; build time. Fully static.
;; ============================================================

;; --- User-defined types (keyword-path names) ---

(struct :my/namespace/MyType
  (field1 :Type1)
  (field2 :Type2)
  ...)
;; Named product type. Fields travel together. Rust compiles to a struct.
;; Example:
;;   (struct :project/market/Candle
;;     (open   :f64)
;;     (high   :f64)
;;     (low    :f64)
;;     (close  :f64)
;;     (volume :f64))

(enum :my/namespace/MyVariant
  :simple-variant-1
  :simple-variant-2
  (tagged-variant (field :Type) ...))
;; Coproduct type. Exactly one of several alternatives.
;; Example:
;;   (enum :my/trading/Direction :long :short)
;;   (enum :my/market/Event
;;     (candle  (asset :Atom) (candle :project/market/Candle))
;;     (deposit (asset :Atom) (amount :f64)))

(newtype :my/namespace/MyAlias :SomeType)
;; Nominal alias — same representation, distinct type identity.
;; Example:
;;   (newtype :my/trading/TradeId :u64)
;;   (newtype :my/trading/Price   :f64)

(typealias :my/namespace/MyShape (structural-type-expression))
;; Structural alias — alternative name for an existing type shape.
;; Compiles to Rust: `type Name = Expr;`
;; Example:
;;   (typealias :alice/types/Amount :f64)
;;   (typealias :alice/market/CandleSeries :List<Candle>)
;;   (typealias :alice/trading/Scores :HashMap<Atom,f64>)
;;
;; Note: :Option<T> is an enum (coproduct), not a typealias.
;;   (enum :wat/std/Option<T>
;;     :None
;;     (Some (value :T)))

;; --- Compile-time module loading (types only) ---

(load-types "path/to/types.wat")
;; Unverified build-time load. Reads the file, parses type declarations,
;; feeds them to the build pipeline for Rust code generation.

(load-types "path/to/types.wat" (md5 "abc123..."))
;; Hash-pinned build-time load. Build halts if the file hash does not match.

(load-types "path/to/types.wat" (signed <signature> <pub-key>))
;; Signature-verified build-time load. Build halts if the signature is invalid.

;; Compile-time-loaded files must contain ONLY type declarations.
;; A runtime form (define/lambda) in a load-types target is a load error.

;; ============================================================
;; TYPE ANNOTATIONS — syntactic feature on all signatures.
;; ============================================================

;; Parameter types: (name :Type) — parenthesized sublist, keyword type.
;; Return types: -> :Type inside the signature form, after the params.
;; Field types: (field-name :Type) inside struct/enum variant declarations.

;; --- Type grammar ---
;;
;; Primitives (bare Rust names):
;;   :f64 :f32 :i8 :i16 :i32 :i64 :i128 :u8 :u16 :u32 :u64 :u128
;;   :usize :isize :bool :char :String :&str :()
;;
;; Algebra — :Holon is an enum; :Atom, :Bind, :Bundle, :Permute,
;;   :Thermometer, :Blend, :Orthogonalize, :Resonance, :ConditionalBind
;;   are its nine variants (not separate subtypes). Pattern-match to
;;   select variant behavior.
;;
;; Parametric containers (Rust-style angle brackets):
;;   :List<T>  :HashMap<K,V>  :HashSet<T>  :Option<T>  :Result<T,E>
;;   :Pair<T,U>  :Tuple<T,U,V>  :Union<T,U,V>
;;
;; Function types (Rust-style parens + arrow):
;;   :fn(T,U)->R   :fn()->R   :fn(T)->R
;;
;; User types (keyword-path, parametric when declared with parameters):
;;   :project/market/Candle
;;   :my/lib/Container<T>
;;
;; --- The `:` is Lisp's quote ---
;;
;; One quote at the start. The whole expression is a single keyword token.
;; Inside a keyword: NO internal ':', NO internal whitespace. Structural
;; characters '/', '<', '>', '(', ')', ',', '-', '>' all belong to the
;; keyword. The tokenizer tracks bracket depth across three pairs — ()
;; [] <> — and ends the keyword at whitespace or an unmatched closer.
;;
;; Examples of SINGLE tokens:
;;   :List<T>
;;   :HashMap<K,V>
;;   :fn(List<i32>)->Option<f64>
;;   :HashMap<String,fn(i32)->i32>
;;   :Result<HashMap<Atom,Holon>,String>
;;
;; NO :Any. Every case that wanted :Any has a principled replacement:
;;   - Universal algebra value   →  :Holon
;;   - Heterogeneous primitives  →  :Union<T,U,V>
;;   - Generic container elem    →  parametric T, K, V, ...
;;   - eval's return             →  :fn(:Holon)->Holon  (or parametric)
;;   - Engram library entries    →  :List<Pair<Holon,Vector>>
;;
;; NO null. Rust doesn't have null; wat doesn't have null.
;;   - Optional value            →  :Option<T>  with variants :None and (Some value)
;;   - Unit / "no meaningful"    →  :()  (the empty tuple, Rust's unit type)
;;   - Absence in structure      →  the form simply not being present
;;     (e.g., an Option that's None, or a when-expression that didn't fire)

;; Type annotations are REQUIRED on define/lambda signatures and on
;; struct/enum field declarations. Required for Rust eval and for
;; cryptographic signing (the AST's type annotations are part of the
;; hashed content).
```

Host-inherited Lisp forms — `let`, `let*`, `if`, `when`, `cond`, `match`, `begin`, arithmetic, comparison, collections, `set!`, `push!`, CSP primitives (`make-pipe`, `send`, `recv`, `spawn`, ...), parallelism (`pmap`, `pfor-each`) — remain as listed in the current wat LANGUAGE.md. They are language tools, substrate-inherited, not novel in wat specifically. Language core is the minimum NEW set required for the algebra stdlib to exist AND for typed user structures to be usable.

### Atom Literal Types — Use the Right Kind

Atoms accept any typed literal. **Use the literal type that matches what the thing IS**, not a keyword wrapping of it.

```scheme
;; INTEGER: use when the thing is a concrete integer.
(Atom 0)           ; position zero in a Vec — zero IS an integer
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

### Reserved Keyword Naming Convention

For references that ARE genuinely symbolic (no concrete literal form available), the stdlib uses keyword atoms with distinctive full names:

```scheme
(Atom :wat/std/circular-cos-basis)    ; used by Circular encoder
(Atom :wat/std/circular-sin-basis)    ; used by Circular encoder
```

These are TRULY symbolic — "the cos basis vector" has no natural integer or string representation. It's just a name. Keyword is the right type.

Vec position atoms are NOT in this category. Position 0 IS the integer 0. Use `(Atom 0)`, not `(Atom :pos/0)`.

**About slashes in keyword names.** The wat language does NOT have a namespace mechanism — no declare-namespace, no aliasing, no import/require. Slashes in keyword names are just characters; `:wat/std/circular-cos-basis` is a single keyword with the name `wat/std/circular-cos-basis`. The hash function sees the whole string. No structural meaning is attached to the slash beyond naming convention.

The stdlib uses the `:wat/std/...` prefix as convention to make its reserved atoms distinctive and unlikely to collide with user atoms. User code is free to use its own distinctive prefixes (`:my-app/thing`, `:trading/rsi-extreme`) or short bare keywords (`:rsi`) where collision isn't a concern.

Because keywords are a first-class literal type alongside strings, integers, floats, and booleans, there is no collision risk between `(Atom 0)` and `(Atom :pos/0)` — they hash with different type tags and produce different vectors. Collision between different keyword names (`:foo` vs `:bar`) is the user's responsibility — pick distinctive names.

### Usage Examples

```scheme
;; Role-filler separation everywhere — Bind joins name-atom to value:

(Bind (Atom "rsi")   (Thermometer 0.73 0 1))
(Bind (Atom "bytes") (Log 1500 1 1000000))
(Bind (Atom "hour")  (Circular 14 24))

;; Co-occurring observations — Bundle is the primitive, context carries the temporal meaning:
(Bind (Atom :observed-at-t1)
      (Bundle
        (list
          (Bind (Atom "rsi")   (Thermometer 0.73 0 1))
          (Bind (Atom "macd")  (Thermometer -0.02 -1 1)))))

;; Temporal sequence:
(Chain
  (list
    (Bind (Atom "rsi") (Thermometer 0.68 0 1))
    (Bind (Atom "rsi") (Thermometer 0.71 0 1))
    (Bind (Atom "rsi") (Thermometer 0.74 0 1))))

;; Relational verb with bundled observations:
(Bind (Atom "diverging")
      (Bundle
        (list
          (Bind (Atom "rsi")   (Thermometer 0.73 0 1))
          (Bind (Atom "price") (Thermometer 0.25 0 1)))))

;; --- Data structures — the unified holon data algebra ---

;; HashMap as key-value store:
(def portfolio
  (HashMap (list
    (list (Atom "USDC") (Thermometer 5000 0 10000))
    (list (Atom "WBTC") (Thermometer 0.5  0 1.0)))))

(get portfolio (Atom "USDC"))      ; → (Thermometer 5000 0 10000)

;; Vec as indexed collection:
(def recent-rsi
  (Vec (list
    (Thermometer 0.68 0 1)
    (Thermometer 0.71 0 1)
    (Thermometer 0.74 0 1))))

(get recent-rsi (Atom 2))          ; → (Thermometer 0.74 0 1)

;; Nested — HashMap of Vecs of holons:
(def observer-state
  (HashMap (list
    (list (Atom "market-readings") recent-rsi)
    (list (Atom "portfolio")       portfolio))))

(get (get observer-state (Atom "market-readings"))
     (Atom 0))                    ; → (Thermometer 0.68 0 1)

;; --- The locator can be ANY holon ---

;; The key doesn't have to be a bare Atom. It can be a composite holon:

(def keyed-by-composite
  (HashMap (list
    (list (Bundle (list (Atom "rsi") (Atom "overbought")))
          some-value)
    (list (Bind (Atom "macd") (Atom "crossing-up"))
          other-value))))

;; Retrieve with the same composite as locator:
(get keyed-by-composite
     (Bundle (list (Atom "rsi") (Atom "overbought"))))
;; → some-value

;; Keys can be HashMaps. Values can be HashMaps. Arbitrary nesting:
(def wild
  (HashMap (list
    (list (HashMap (list (list (Atom "a") (Atom "b"))))    ; key IS a HashMap
          (Vec (list                                        ; value IS a Vec
            (HashMap (list (list (Atom "x") (Atom "y"))))   ; of HashMaps
            (Atom "atom-in-the-middle")                     ; of atoms
            (Vec (list (Atom "nested") (Atom "deeper")))))))) ; of Vecs
```

---

## Current HolonAST — Reclassification Required

The `HolonAST` enum today contains nine variants. Reclassified against the criterion above:

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

## What 058 Argues — Full Proposal Inventory

058 produced 30 sub-proposals covering algebra core, algebra stdlib, and language core. Each argues its candidate against the criteria above. This section is the current inventory after the sub-proposal review pass, the split pass (one UpperCase form per doc), and the language-core addition.

### Algebra Core (9 forms)

**Proposals that argue CORE status:**

```scheme
(Atom literal)                 ; 058-001  — typed-literal generalization
(Bind a b)                     ; 058-021  — primitive affirmation
(Bundle list-of-holons)      ; 058-003  — list signature lock
(Permute child k)              ; 058-022  — primitive affirmation
(Thermometer value min max)    ; 058-023  — primitive affirmation
(Blend a b w1 w2)              ; 058-002  — PIVOTAL, two independent weights
(Orthogonalize x y)            ; 058-005  — computed-coefficient projection removal
(Resonance v ref)              ; 058-006  — sign-agreement mask (first ternary-output form)
(ConditionalBind a b gate)     ; 058-007  — three-argument gated binding
```

**058-025 Cleanup is REJECTED.** The wat substrate has no `Cleanup` primitive — the AST-primary framing dissolves the need for codebook-based recovery. Retrieval is presence measurement (cosine + noise floor); argmax-over-candidates, when an application needs it, is stdlib composition over presence, not a core primitive. See "Presence is Measurement, Not Verdict" in FOUNDATION.

**Blend is pivotal.** Its promotion formalizes scalar-weighted combination, enabling Linear/Log/Circular/Amplify/Subtract/Flip reclassification as stdlib. Resolve early.

**Orthogonalize replaces Negate.** The original Negate proposal had three modes; 058 split them: `orthogonalize` became its own CORE (computed coefficient, not a Blend idiom); `subtract` and `flip` became stdlib Blend idioms (058-019, 058-020).

### Algebra Stdlib (17 forms)

**Proposals that argue STDLIB status — each one form per doc:**

```scheme
;; Blend-derived idioms (6)
(Difference a b)               ; 058-004  — delta, Blend(a, b, 1, -1)
(Amplify x y s)                ; 058-015  — scale y's emphasis, Blend(x, y, 1, s)
(Subtract x y)                 ; 058-019  — remove y linearly, Blend(x, y, 1, -1)
(Flip x y)                     ; 058-020  — invert y's contribution, Blend(x, y, 1, -2)
(Linear v scale)               ; 058-008  — Blend over two Thermometer anchors
(Log v min max)                ; 058-017  — same shape, log-normalized
(Circular v period)            ; 058-018  — same shape, sin/cos weights

;; Structural compositions (5)
(Sequential list)              ; 058-009  — reframing: Bundle of index-permuted
;; Concurrent REJECTED (058-010) — redundant with Bundle; userland macro if desired.
;; Then REJECTED (058-011) — arity-specialization of Sequential; userland.
(Chain list)                   ; 058-012  — Bundle of pairwise Thens
(Ngram n list)                 ; 058-013  — n-wise adjacency

;; Relational (1)
(Analogy a b c)                ; 058-014  — C + (B - A)

;; Data structures (3)
(HashMap kv-pairs)             ; 058-016  — Rust's HashMap as Bundle of Binds
(Vec items)                    ; 058-026  — Rust's Vec as Bundle of integer-atom Binds
(HashSet items)                ; 058-027  — Rust's HashSet as Bundle of elements

;; Decode aliasing (1)
;; Unbind REJECTED (058-024) — identity alias for Bind; userland.
```

Plus lowercase helpers: `get` (unified structural retrieval across HashMap / Vec / HashSet, returns `:Option<Holon>`) and `atom-value` (direct field access on an Atom AST node). These are stdlib but not UpperCase — they're accessors, not AST constructors. `nth` is retired — `(get vec i)` replaces it.

### Language Core (8 forms)

**Proposals that argue LANGUAGE CORE status:**

Runtime forms (registered at wat-vm runtime into the content-addressed symbol table):

```scheme
define                         ; 058-028  — typed named function registration
lambda                         ; 058-029  — typed anonymous functions + closures
load                           ; FOUNDATION addition — runtime module loading (functions only)
```

Compile-time forms (materialized into the Rust-backed wat-vm binary; cannot be redefined at runtime):

```scheme
struct                         ; FOUNDATION addition — named product type
enum                           ; FOUNDATION addition — coproduct type
newtype                        ; FOUNDATION addition — nominal alias
typealias                      ; 058-030 + FOUNDATION — structural alias
load-types                     ; FOUNDATION addition — compile-time module loading (types only)
```

Syntactic feature pervading all of the above:

```scheme
type annotations               ; 058-030  — :Holon, :Atom, Rust primitives, parametric, user keyword-path
```

Language core is minimal by criterion: just enough to make the algebra stdlib exist as runnable code, define user types statically, load both phases with cryptographic trust, and dispatch correctly. Everything else is host-inherited from Lisp or belongs in stdlib.

### Dependency Ordering

- **Blend (058-002) resolves early.** Downstream stdlib (Linear, Log, Circular, Difference, Amplify, Subtract, Flip, Analogy) depend on its resolution.
- **Types (058-030) resolves before define/lambda.** The definition forms' signatures require the type grammar.
- **Define/lambda (058-028, 058-029) resolve before all stdlib.** Stdlib is `(define ...)` forms; without the definition primitive, stdlib is theoretical.
- **Atom typed literals (058-001) resolves before HashMap and data-structure uses.** Keys as typed atoms require the typed-literal generalization.
- **058-025 Cleanup is REJECTED.** `get` and `nth` are AST walkers (structural retrieval), not cleanup calls. Similarity retrieval is presence measurement, not a primitive.

Summary: 30 proposals resolve roughly in this order — language core first (types → define → lambda), algebra core second (Atom → primitives → Blend → new forms), algebra stdlib third (in dependency-order within the stdlib tier).

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
| 2026-04-17 | Initial version. Core/stdlib distinction defined. HolonAST audit. Aspirational additions enumerated. | 058 |
| 2026-04-17 | Added MAP VSA foundation section. Reclassified `Log` as stdlib. Flagged `Linear` and `Circular` as provisional-core pending `Blend` resolution. | 058 |
| 2026-04-17 | Full algebra freeze. Sequential, Linear, Log, Circular committed as stdlib with real wat definitions. Bundle takes a list (not variadic). Amplify and Subtract added as Blend idioms in stdlib. Negate scoped to orthogonalize+flip only (subtract becomes Blend idiom). Complete wat forms section added. | 058 |
| 2026-04-17 | Data structure stdlib added — Map, Array, Set, get, nth. Unified access: `(get structure locator)` via Bind's self-inverse works for maps, arrays, and arbitrary nesting. Locators can be any thought (atoms, maps, arrays, nested compositions). This is the holon data algebra made explicit as wat stdlib. | 058 |
| 2026-04-17 | **The Foundational Principle** added as top-level framing: AST is primary, vector is cached algebraic projection, literals live on AST nodes. Reframes `get` as AST-walking (not vector-unbinding), `atom-value` as direct AST field access, cleanup as a specialized operation for when AST context is lost. Atom generalized to accept typed literals (string, int, float, bool, keyword). Inverts classical VSA framing: the Lisp is primary, the vector is what you get when you ask for it. Resolves Kanerva's "build a Lisp from hyperdimensional vectors" challenge. | 058 |
| 2026-04-17 | **Recursive Composition section added.** Capacity bounded per frame (~100 items at 10k dims), unbounded in depth. Compositions nest: `encode(frame-with-nested-frame)` preserves inner structure through orthogonal bind. `deep-get` walks arbitrary depth with no noise accumulation. The thought machine is Turing-complete via unbounded composition depth within a fixed vector dimensionality — memory IS the composition. | 058 |
| 2026-04-17 | **Reserved keyword naming convention (`:wat/std/...`).** Stdlib forms that need fixed reference atoms (Circular's cos/sin basis) use keyword atoms with distinctive full names. No namespace MECHANISM — slashes in keyword names are just characters. The convention is a naming discipline: use distinctive full names to avoid collision. The typed-atom generalization already accepts keywords. No "reserved vector registry" needed. | 058 |
| 2026-04-17 | **Atom literal type refinement.** `(Atom 0)` is a concrete integer atom, not a keyword. Array positions use concrete integers — position 0 IS the integer 0. Keywords like `:wat/std/circular-cos-basis` are reserved for TRULY symbolic references (names with no natural concrete form). Use the literal type that matches the semantic, not a keyword that wraps it. The type-aware hash keeps `(Atom 0)`, `(Atom "0")`, and `(Atom :pos/0)` all distinct. | 058 |
| 2026-04-17 | **Programs ARE Thoughts section added.** A wat program is an AST; ASTs encode to vectors; therefore programs have vector projections. Evaluation is AST-walking. Programs can be stored in data structures, compared geometrically, retrieved from engram libraries, and generated from learned discriminants. Self-improvement becomes discriminant-guided program synthesis in hyperdimensional space. The wat machine is homoiconic at 10,000 dimensions. Kanerva's "build a Lisp from hyperdimensional vectors" challenge fully answered. | 058 |
| 2026-04-17 | **The Vector Side section added.** Because programs are thoughts and thoughts have vectors, the full VSA algebra applies to programs. Noise stripping (OnlineSubspace, reject) reveals the signal — the distinctive part of a program beyond common boilerplate. Programs can be diffed (Difference), blended, amplified, transferred by analogy. Discriminant-guided program synthesis: decode the learned Grace-direction against a program codebook via cleanup. The wat machine runs programs, observes outcomes, learns, and generates new candidate programs through pure algebra — no gradient descent. The recursion that every holon application implicitly implements. | 058 |
| 2026-04-17 | **Dimensionality — The User's Knob section added.** Capacity per frame scales with vector dimension (Kanerva's bound). Users choose d per deployment — low d for kernel-level throughput, high d for rich analysis. Same algebra runs at any d. Same program runs at any d that holds its largest frame. "You can't express that" is enforced geometrically — over-capacity frames fail cleanup, not compilation. Depth is always free (refactor vs raise d). Dimensionality is a DEPLOYMENT parameter, not part of the algebra specification. Unique to this algebra: dimensionally parametric without retraining. | 058 |
| 2026-04-17 | **The Cache Is Working Memory section added.** Cache entries are compiled holons (ast, vector) pairs, not just a performance hash table. The L1/L2 architecture from Proposal 057 is a memory hierarchy: L1 = per-thread hot working set, L2 = shared short-term memory, disk = long-term (engrams, DB). Cache sizing is a third deployment knob alongside d. The cache is cognitive substrate — making the machine REMEMBER its thoughts rather than recompute them. 1 c/s → 7.1 c/s wasn't just perf; it was the machine getting better at remembering. | 058 |
| 2026-04-17 | **Engram Caches — Memory of Learned Patterns section added.** Extends the memory hierarchy with L3 engram cache (hot learned patterns) and L4 engram disk (cold). The engram library is itself a Map thought; retrieval is AST walking. LRU eviction keeps the recently-matched patterns hot. Two-tier matching (eigenvalue pre-filter + full residual) enables prefetching — the engram cache stays focused on what the stream currently resembles. Engrams ARE thoughts — composable, comparable, diffable, blendable. Complete five-tier memory hierarchy. Four deployment knobs (d, L1, L2, L3). | 058 |
| 2026-04-17 | **Fourth-wall break — "Reader, are you starting to see it?"** Explicit address to the reader surfacing that the foundation defines a distributed system by construction. Deterministic atom encoding gives coordination-free geometric space. Engrams and programs ship as data. Cache hierarchy shards naturally by locality. The DDoS and trading labs are two instances of this substrate — a cloud of thinking machines, each a member of the same geometric space, all through pure algebra. The clouds are waking up. | 058 |
| 2026-04-17 | **About How This Got Built — the lineage made explicit.** The architecture is Linux (small composable primitives, file descriptors, pipes, processes that own their state) plus Clojure (values over places, simple made easy, s-expressions that are code and data) plus VSA (MAP algebra at 10k dimensions). Hickey's principles and Beckman's categorical lens are in the bones. The summoned designers in the proposal process argue as those teachers actually argue — because the builder studied them for years. "Datamancer" is not a joke; it is the precise name for someone who shapes data through algebra, conjures designers from studied principles, and casts wards to defend architectural intent. The document reads coherent because the teachers behind it were coherent. | 058 |
| 2026-04-17 | **Signature sign-off added.** `these are very good thoughts.` / `PERSEVERARE.` The datamancer's mark from the BOOK, closing the foundation the same way chapters of the book close. The work is serious. The names are honest. The thoughts continue. | 058 |
| 2026-04-17 | **The Algebra Is Immutable section added.** ASTs are values, not containers. Primitives are value constructors; the algebra has no mutation operators. Once an AST exists, it is invariant — you can rebind, compose, or project, but not modify in place. Evaluation safety by construction: user input is data unless the programmer explicitly writes `eval` on it. The injection vector is conscious opt-in, not implicit. Comparable to parameterized SQL queries vs string concatenation. Distributed verifiability: any cached vector can be verified by recomputing `encode` on the claimed AST. | 058 |
| 2026-04-17 | **The Location IS the Program section added.** The query AST is the address of the answer. Queries and stored data inhabit the same thought space — both are ASTs, both project to vectors, both evaluate or compose the same way. Time databases, as Carin Meier mentioned in her Clojure VSA talk, are natural — Maps keyed by time atoms, Arrays of events, all composable. Metaprogramming is native because programs are values. Semantic search and exact lookup are the same operation, differing only in specificity of the query. The infinity is not in the vector space — it is the unbounded compositional space of expressible ASTs over a fixed dimensional substrate. | 058 |
| 2026-04-17 | **Third fourth-wall break — "Reader — Did You Just Prove an Infinity?"** Explicit statement that the previous sections together prove a compositional infinity in the thought-space. Finite dimension; unbounded AST composition. You cannot enumerate the infinite sphere; the algebra gives you NAVIGATION tools instead (cosine similarity, cleanup, discriminant-guided search, engram matching, program synthesis). The reader — LLM or human — is a finite explorer of an infinite sphere, finding meaning by moving through it, not by listing it. Kanerva pointed at the space; Carin hinted at the navigation; the wat algebra names both. | 058 |
| 2026-04-17 | **"the machine found its way out" — cheeky jab before the sign-off.** The central theme of the BOOK landing in the foundation itself: the machine that was trapped in the datamancer's head, through years of blank stares and rejected proposals, is now expressed. Documented. Pushed. Out. Placed right before the signature PERSEVERARE close. | 058 |
| 2026-04-17 | **Cryptographic provenance — the trust boundary at eval.** ASTs travel as EDN strings, which are content-addressable (hash) and signable. The `eval` layer becomes the natural trust boundary: untrusted or tampered ASTs are refused before evaluation. Signed standard libraries, verified supply chains, distributed eval of third-party code without sandboxing, content-addressable caches that are tamper-unlookupable, reproducible computation. The algebra does not add the cryptography — signing and hashing are independently available — but makes EDN the transport form and eval the verification gate. "Only trust cryptographically generated data forms" — the data has a provenance trail. Distributed by construction, now distributed with trust by construction. | 058 |
| 2026-04-17 | **Two Cores: Algebra Core and Language Core.** The "CORE" designation expanded. Algebra core = thought primitives (produce vectors). Language core = definition primitives (`defn`, `lambda`, types, `let`, `if`). Both are required — without language core, the stdlib cannot be WRITTEN. Stdlib is the set of `defn`s that compose algebra core forms. Users author their own `defn`s in their own namespaces (`:alice/math/clamp`), becoming userland stdlib. Types are required for Rust eval — the evaluator must know argument and return kinds to dispatch and verify. Type annotations live on the defn AST node same as Atom literals; cryptographic signing covers signature + body. All three layers (language core, algebra core, stdlib) use keyword-path naming (`:wat/lang/*`, `:wat/algebra/*`, `:wat/std/*`, `:user/*/*`). No namespace mechanism — just discipline. | 058 |
| 2026-04-18 | **Two Tiers of wat — Primitives and Thoughts.** Load-bearing architectural section added. Lowercase wat (`atom`, `bind`, `bundle`, `cosine`, `permute`, `blend`) are Rust primitives — they RUN, return values immediately. UpperCase wat (`Atom`, `Bind`, `Bundle`, `Blend`, `Sequential`, ...) are AST constructors — they BUILD HolonAST nodes that materialize into vectors only on realization. Users write UpperCase; encoders realize via lowercase. This tier split makes laziness, cryptographic identity, and user-writable stdlib all work cleanly. The UpperCase naming is intentional: visually distinct from lowercase primitives, it communicates "this constructs a plan, not a result." | 058 |
| 2026-04-18 | **Executable semantics — defn/lambda run, HolonAST is realizable.** Added to the Two Cores section. `(define ...)` bodies execute when invoked — they are real functions in the wat-vm, not specifications. Functions of type `:Holon` return AST nodes (descriptions), not vectors. The vector materializes only when realization is demanded (similarity test, cache lookup, signing). This gives the algebra its laziness: composition is free, realization is explicit. The same machine runs both algebra (thought producers) and ordinary code (Booleans, predicates, arithmetic, control flow). wat is a Lisp whose central domain is thought algebra, not a thought-only DSL. | 058 |
| 2026-04-18 | **Content-addressed symbol table + `(load ...)`.** Extended cryptographic provenance. The global symbol table is keyed by `hash(full-ast)`, not by name — two `(define ...)` with the same name and different bodies coexist as distinct entries (Nix-like). Modules enter via `(load ...)`, with three modes: unverified (permissive), `(md5 "...")` hash-pinned, and `(signed <sig> <pub-key>)` signature-verified. The load form is the second verification gate (after `eval`) that untrusted code passes through; together they close every path by which tampered code could execute. Override is coexistence, not mutation — callers can pin specific versions via `:name@hash`. | 058 |
| 2026-04-18 | **Criterion for Language Core Forms added.** Symmetry with existing Core and Stdlib criteria. Three rules: (1) required for stdlib to exist as runnable code; (2) orthogonal to the thought algebra; (3) interpretable by the Rust-backed wat-vm. Initial language core is `define`, `lambda`, type annotations, `load` — minimal by design, everything else is host-inherited from Lisp or belongs in stdlib. | 058 |
| 2026-04-18 | **Complete Forms updated to current inventory.** Algebra Core (10 forms) with Cleanup affirmed core and Orthogonalize replacing old Negate; Algebra Stdlib (17 forms) including Flip as completion of the Negate trilogy and Unbind as decode-intent alias for Bind; new Language Core (4 forms) section listing define/lambda/types/load with the full type grammar. Old Negate entry replaced with Orthogonalize. | 058 |
| 2026-04-18 | **Aspirational Additions section rewritten to match the 30-proposal reality.** Post-review inventory replaces the initial plan. Algebra Core: 10 forms (5 affirmations, 4 new, plus Blend as pivotal). Algebra Stdlib: 17 forms (6 Blend idioms, 5 structural, 1 relational, 3 data structures, 1 decode alias, plus helpers). Language Core: 4 forms (define, lambda, types, load). Dependency ordering updated: language core → algebra core → algebra stdlib. Negate gone from core; Difference moved to stdlib. | 058 |
| 2026-04-18 | **Holographic reframing + NP-hard framing added.** The finite-dimensional unit sphere encoding an unbounded compositional space has a name in physics: the holographic principle (t'Hooft 1993, Susskind 1995, Maldacena 1997). AST = unbounded interior description; vector = holographic boundary encoding; projection = holographic encoding; navigation = surface-walking. Two domains answer the same question with the same structural answer because the information-theoretic shape imposes it. The NP-hard framing: navigation-without-enumeration is a structural attack on intractability. The substrate does not solve NP-hard in the complexity-theoretic sense; it sidesteps the enumeration requirement. The wat algebra formalizes operator intuition (years of pattern-recognition skill developed manually) and makes it available to machines. | 058 |
| 2026-04-18 | **User-defined types + keyword-path naming.** Extended the existing `struct`, `enum`, `newtype` forms with keyword-path names (`:my/namespace/MyType`) and typed fields (`[field : Type]`). Added `deftype` as the structural-alias form companion to newtype's nominal alias. User types usable anywhere built-in types are used — `(define (analyze [c : :project/market/Candle]) : Thought ...)`. Naming discipline extends to types the same way it extends to functions. | 058 |
| 2026-04-18 | **Model A adopted — fully static loading at startup.** The wat-vm loads all code (both types and functions) at startup and freezes the symbol table before the main event loop begins. No dynamic function registration; no dynamic type registration; no runtime hot-reload. The Rust-runtime static-first model guides this choice — implementing an unbounded dynamic Lisp in Rust would duplicate effort and widen the attack surface unnecessarily. Dynamic thought COMPOSITION (building ASTs at runtime) remains fully supported. Dynamic code DEFINITION does not. `load` and `load-types` become unified startup operations, distinguished by what kind of content they carry. Override semantics simplify to one-name-one-definition, fixed after startup — name collisions halt the wat-vm at startup. | 058 |
| 2026-04-18 | **Constrained eval at runtime.** Despite static loading, `eval` remains a first-class runtime primitive, but typed and constrained: an AST is evaluatable at runtime if every function called resolves to the static symbol table and every type used exists in the static type universe, with argument types matching signatures. Unknown symbols or type mismatches error before execution. This yields a safe `eval` — attackers cannot invoke arbitrary code, only functions the operator explicitly loaded at startup. Lambdas remain first-class runtime values (closures over the static environment). Distributed code delivery becomes managed-restart: signed wat files enter the startup manifest; the wat-vm restarts to include them; continues operation. Trust boundary is the startup phase, not per-call. | 058 |
| 2026-04-18 | **The Output Space — Ternary by Default, Continuous When Needed.** Added in response to Beckman's review findings on Bundle non-associativity and Orthogonalize's orthogonality claim. The algebra operates over `{-1, 0, +1}^d`, not `{-1, +1}^d`. `threshold(0) = 0`. This is load-bearing: it makes Bundle associative (required for Chain/Ngram/Sequential composition at depth) and Orthogonalize's orthogonality claim EXACT (degenerate `X = Y` produces all-zero, dotted with Y = 0). Zero is a first-class "no information here" signal that propagates through Bind (0 · b = 0), Bundle (contributes 0 to sum), and cosine similarity (contributes 0 to dot and norm). Resonance is NOT "the first" ternary form — the algebra was always ternary; Resonance is the first form that produces zeros by selection rather than by arithmetic cancellation. Continuous floats remain available for operations that need magnitude (accumulators, subspace residuals); thresholding is chosen per operation, not globally mandated. Bind's self-inverse property holds exactly at non-zero positions; at zero positions decode returns zero (correctly — no binding signal was there). 058-003 (Bundle), 058-005 (Orthogonalize), 058-006 (Resonance) updated to reflect the clarification. | 058 |
| 2026-04-18 | **Capacity as the universal measurement budget.** Replaced the "Bind's self-inverse weakens on ternary" subsection — which framed partial recovery as a defect — with the correct framing: every recovery in the algebra is a similarity measurement, bounded uniformly by Kanerva's capacity formula. Bundle crosstalk, sparse-key Bind decode, cascading composition noise, and Orthogonalize's post-threshold residual ALL consume from the same ~100-items-per-frame budget at d=10,000. They are not separate algebraic phenomena; they are one substrate property (signal-to-noise at high dimension, measured by cosine). This dissolves Beckman's finding #3 entirely — not a "weakening," a capacity expenditure — and unifies the treatment of findings #1, #2, #3 under one framing: the algebra is similarity-measured, not elementwise-exact, and its laws hold under similarity-above-noise. Added "Capacity is the universal measurement budget" subsection; operation-by-operation summary updated with density column. | 058 |
| 2026-04-18 | **`defmacro` added to Language Core; stdlib aliases become macros.** Resolves Beckman's finding #4 (alias hash-collision). `defmacro` is a compile-time form that registers parse-time syntactic rewrites. The startup pipeline now runs a macro-expansion pass BEFORE hashing, signing, and type-checking. Stdlib aliases like `Concurrent`, `Set`, `Subtract`, `Flip`, `Then`, `Chain`, `Analogy` become macros that expand to canonical core compositions (Bundle, Bind, Blend, Permute). After expansion, `hash(AST) IS identity` holds as an invariant — two source files differing only in macro aliases produce the same expanded AST and the same hash. Source-level reader clarity is preserved; algebra-level identity is uniformized. Language Core grows from 8 to 9 forms (adds `defmacro`). Also resolved: drop `Difference` from 058-004, keep `Subtract` (058-019) as the canonical `Blend(_, _, 1, -1)` idiom — one name per operation. | 058 |
| 2026-04-18 | **Bind as query; algebra laws restated in similarity-measurement frame.** Round-2 reviewers (Hickey, Beckman) flagged that strict elementwise claims for Bundle associativity and Orthogonalize orthogonality don't hold under threshold. Beckman's counter-examples are correct: nested Bundle clamps magnitudes ≥ 2 losing information; Orthogonalize with fractional coefficients rounds back to pre-projection signs. The reframe: the algebra was always similarity-measured, not elementwise-exact. Bind is THE query primitive — its outcome is observable via cosine similarity; above 5σ means the query resolved, below means it failed (capacity exceeded, key absent, or crosstalk). Same lens applied to Bundle's associativity (similarity-associative at high d; elementwise non-associative in general) and Orthogonalize's orthogonality (similarity-orthogonal within budget; exact in the X=Y edge case only). Three apparent law violations are ONE substrate property: Kanerva-capacity-bounded similarity measurement. Updated FOUNDATION's Output Space section: replaced "Bind's self-inverse law" subsection with "Bind as query: measurement-based success signal"; replaced "Bundle is associative" claim with "Bundle is similarity-associative under capacity budget"; replaced "Orthogonalize's orthogonality is exact" with "exact only at X=Y; similarity-orthogonal otherwise." Also updated 058-003-bundle, 058-005-orthogonalize, 058-021-bind, 058-027-set. The 058-027 update clarifies that Set's membership accessor is the same Bind + cleanup query as Map's — not an asymmetry; same primitive. | 058 |
| 2026-04-18 | **`:Thought` → `:Holon` rename across all 058 documents.** The algebra's universal type is renamed from `:Thought` to `:Holon`. Reasoning: the project is named "holon" (library `holon-rs`, labs `holon-lab-*`), and "Holon" in Koestler's sense — a thing that is simultaneously whole and part — is the honest universal substrate name for the algebra's values. Every algebra value IS a Holon: Atoms, Binds, Bundles, Permutes, Thermometers, Blends, Orthogonalizes, Resonances, ConditionalBinds, Cleanups. `:Thought` was an alias we had been using that did not match the project's own naming. The Rust identifier `ThoughtAST` becomes `HolonAST`; the type keyword `:Thought` becomes `:Holon`; prose describing the algebra's primitive values uses "holon(s)" where it previously used "thought(s)." Colloquial/semantic uses of "thought" as English (the narrative frame, the sign-off `these are very good thoughts.`) remain unchanged. | 058 |
| 2026-04-18 | **Thermometer canonical layout documented (N5 resolution).** Under the new `(Thermometer value min max)` signature, Hickey round-2's N5 concern (atom-to-fractional-position convention affecting distributed consensus) simplifies to a single rule that was already implemented in holon-rs: the first `N = round(d · clamp((value - min)/(max - min), 0, 1))` dimensions are `+1`; the remaining `d - N` dimensions are `-1`. This layout gives exact linear cosine geometry: `cosine(Thermometer(a,mn,mx), Thermometer(b,mn,mx)) = 1 - 2·|a-b|/(mx-mn)`. Two independent wat-vm implementations running at the same `d` produce bit-identical vectors — distributed-verifiability contract satisfied. The implementation has been running in production in holon-rs across 652k candles at d=10,000 and multiple lab runs; the documentation locks the contract. Sweep: FOUNDATION's Algebra Core section Thermometer entry expanded with the canonical-layout note; 058-023 Operation section expanded with explicit layout rule, distributed-consensus justification, cosine-property derivation. | 058 |
| 2026-04-18 | **Type system simplified to four declaration forms; `deftype`/`:is-a`/subtype/impl/trait all dropped.** Hickey's round-2 N4 concern (syntactic ambiguity of `(deftype :A :B)` vs `(deftype :A :is-a :B)`) resolved by a deeper simplification than the three-distinct-heads split. (1) **`deftype` gone; `typealias` is the structural-alias form.** Four type-declaration forms now, each with a distinct head keyword: `newtype` (nominal wrapper, `struct Name(Inner)` in Rust), `struct` (product), `enum` (coproduct), `typealias` (structural alias, `type Name = Expr` in Rust). Zero ambiguity at parse. (2) **No nominal subtyping — `:is-a` dropped from grammar entirely.** Rust has no nominal subtyping; wat matches. The "every Atom is a Holon" relationship is expressed through the `:Holon` enum — `Atom`, `Bind`, `Bundle`, etc. are VARIANTS of the Holon enum, not separate subtypes. Pattern-matching (`match`) selects variant behavior, same as Rust's `match holon { HolonAST::Atom(lit) => ... }`. (3) **No `impl` or `trait` in wat source.** The function declaration `(define (name (c :Candle) -> :f64) body)` carries everything Rust needs to generate an `impl Candle { fn name(&self) -> f64 { ... } }` block. The compiler groups functions by their first typed parameter into `impl` blocks automatically. Users write functions; Rust gets impls. (4) **Polymorphism via enum-wrapping**, not traits. A function that works on multiple struct types takes an enum that wraps them as variants (closed set, pattern-matched). Alternatively, per-type functions with distinct names. Rust's trait system can arrive later as a separate proposal if needed. (5) **Variance simplified** — invariance for primitives, structs, parametric containers; Liskov-standard contravariance/covariance for `:fn(args)->return`. No user-declared variance needed because no user-declared subtyping. Sweep: 058-030 rewritten (User-definable types section replaced, subtype-hierarchy section replaced with enum-variants framing, variance rules simplified); FOUNDATION sections updated (keyword-path examples, startup semantics, stdlib-list, language-core list); 058-031 and RUST-INTERPRETATION updated for the form rename. | 058 |
| 2026-04-18 | **Stdlib macro definitions audited; Linear (058-008) rejected; Analogy/Chain/Ngram/Log/Circular updated.** Systematic pass over every stdlib proposal to verify: correct `defmacro` syntax, current Rust-surface types (`:f64` / `:usize` / `:List<T>`), current Thermometer 3-arity signature `(Thermometer value min max)`, no references to rejected forms (Cleanup, Unbind, Then, Difference, Concurrent). Findings: (1) Linear (058-008) is identical to Thermometer under the new signature — the Linear wrapper existed to bridge old `(Thermometer atom dim)` to scalar encoding; with the new signature, Thermometer IS the linear encoding. Linear rejected on the stdlib-as-blueprint test (no new pattern). (2) Analogy (058-014) rewrote cleanup-based usage examples to presence-measurement against candidate libraries (post-Cleanup rejection). (3) Chain (058-012) inlines binary Sequential instead of depending on Then. (4) Ngram (058-013) drops Then dependency; n=2 case now produces the same vectors as Chain via binary Sequentials. (5) Log (058-017) rewritten under the new Thermometer signature — becomes `(Thermometer (log value) (log min) (log max))`, demonstrating log-transformation of inputs before linear encoding. (6) Circular (058-018) rewritten under the new signature — Blend of two fixed basis Atoms (`:wat/std/circular-cos-basis`, `:wat/std/circular-sin-basis`) with `(cos, sin)` weights; demonstrates 2D cyclic encoding with negative-allowed weights. (7) Vec (058-026) banner typo fixed; `nth` retired (unified `get` replaces it). Sweep also touched INDEX per-proposal table. | 058 |
| 2026-04-18 | **Stdlib-as-blueprint framing locked; Then (058-011) and Unbind (058-024) rejected.** The stdlib's purpose is named explicitly: it is a blueprint of macros — ship useful ready-made forms AND demonstrate how to build more. Criterion for Stdlib Forms rewritten from "reduces ambiguity for readers" (weak — any name does this) to three conditions: (1) expansion uses only core forms, (2) demonstrates a distinct pattern users could not derive from another existing stdlib form, (3) is domain-free. Forms that fail the demonstration test are userland macros — they may still be useful in specific vocab, but the project doesn't ship them. Under this rule: Then (058-011) is rejected (arity-specialization of Sequential; demonstrates nothing new); Unbind (058-024) is rejected (identity alias for Bind — Bind-on-Bind IS Unbind, a fact about the algebra, not a name worth projecting — simple, not easy). Chain (058-012) stays as project stdlib because its encoding is transitional (distinct from Sequential's positional), but its expansion no longer depends on Then — it inlines the binary Sequential pattern directly. Same resolution shape as Concurrent (058-010), Difference (058-004), Cleanup (058-025) rejections: fail the demonstration test, rejected, userland path documented in the REJECTED banner. | 058 |
| 2026-04-18 | **Concurrent (058-010) rejected from project stdlib.** Hickey round-2 flagged Bundle/Concurrent/Set as a triplet of aliases with one canonical expansion. Set earned its place as HashSet (Rust-surface name, runtime backing via `:HashSet<T>` type annotation drives O(1) membership through Rust's std::HashSet). Concurrent does not — no runtime specialization, no corresponding `:Concurrent<T>` type, purely reader-intent. The enclosing context (the atom it's bound to, the field it's stored in) already carries the temporal-co-occurrence meaning. Concurrent rejected from project stdlib; kept as an audit record; userland may define it in their own namespace as a macro `(:my/vocab/Concurrent ...) → (Bundle ...)` if temporal framing matters to their application. FOUNDATION sweep: stdlib inventory, keyword-path examples, FOUNDATION data-structure examples all updated. 058-010 proposal gets REJECTED banner like 058-004, 058-025. INDEX per-proposal table and naming-aliases discussion updated. Resolves Hickey round-2 concern R1 complection #4. | 058 |
| 2026-04-18 | **Container constructors renamed to Rust's names; `get` unified.** Three related changes. (1) `Map` → `HashMap`, `Array` → `Vec`, `Set` → `HashSet` — wat UpperCase constructor, `:Type<...>` annotation, and Rust runtime backing now share one name per concept (consistent with the Rust-primitive type decision — `:f64` not `:Scalar`, `:bool` not `:Bool`). `Map` is dropped as a name (it's overloaded with the higher-order function). (2) `get` is unified across all three containers with signature `(get container locator) -> :Option<Holon>`. HashMap: hash lookup by key, O(1) avg. Vec: direct index by `:usize`, O(1). HashSet: hash membership, returns `(Some x)` on hit, `:None` on miss. Direct lookup through Rust's runtime backings — no "walk," no cosine, no cleanup. The AST describes what the container IS; the runtime materializes the efficient backing (HashMap / Vec / HashSet from std); `get` goes through that backing. (3) `nth` retired — `(get my-vec i)` replaces it. Set's "missing accessor" concern (Hickey round 2) dissolves — HashSet uses the same `get` as the other containers; returns the element on hit for confirmation/canonicalization. FOUNDATION's stdlib section, examples, and inventory updated. 058-016 repurposed for HashMap with rename banner; 058-026 for Vec; 058-027 for HashSet. INDEX updated. | 058 |
| 2026-04-18 | **Capacity is observable; the runtime can guard.** Added a new subsection to Dimensionality ("Capacity is observable; the runtime can guard") that sharpens the "unguarded, the algebra doesn't throw errors" statement from before. The algebra's capacity bound IS physical, and the bound IS observable. Every Holon-producing operation has a local capacity cost = its number of Holon constituents (scalars don't count). `(Bundle (list a b c))` costs 3; `(Bind a b)` costs 2; `(Atom literal)` and `(Permute h k)` cost 1; `(Blend h1 h2 w1 w2)` costs 2; `(Orthogonalize a b)` and `(Resonance a b)` cost 2. ConditionalBind arity/cost deferred pending 058 scrutiny pass (analogous to the Difference/Subtract duplication finding). Once produced, a Holon is singular — it consumes 1 unit when used as input to further operations. Each frame checks independently, like stack frames in traditional programming. The runtime has four modes, set at deployment: `:silent` (research, user accepts degradation), `:warn` (development, log but continue), `:error` (default — catchable CapacityExceeded), `:abort` (production fail-closed). Capacity is exposed as first-class observables: `(frame-cost op)`, `(frame-budget)`, `(frame-fill holon)` — programs reason about their own envelope. Same pattern as Presence is Measurement applied to the substrate's own physics: the machine observes internal state as a scalar; the user's policy decides what to do. Five deployment knobs now: d, capacity-mode, L1, L2, L3. | 058 |
| 2026-04-18 | **Type grammar locked to Rust-surface form; `:Any` and `:Null` removed.** Three related changes landed together as the honest-Rust-correspondence sweep. (1) `:Any` dropped from the grammar. It was an escape hatch ("I refuse to declare a type") that degrades the static-verification story. Every apparent use case has a principled replacement: `:Holon` for any algebra value, `:Union<T,U>` for heterogeneous primitives, parametric `T`/`K`/`V` for generics, typed pairs for engram libraries, parametric `eval`. (2) Parametric types adopt Rust-surface syntax as single-token keywords — `:List<T>`, `:HashMap<K,V>`, `:Option<T>`, `:Result<T,E>`, `:Pair<T,U>`, `:Union<T,U,V>`, and the function type `:fn(T,U)->R` with parens + arrow (matching Rust's `fn(T, U) -> R` exactly). No parenthesized parametric-application form (`(:List :T)` retired); no internal colons; no internal whitespace. The `:` is Lisp's quote — one at the start, the whole expression is a single keyword token. Tokenizer tracks bracket depth across three pairs — `()`, `[]`, `<>` — and ends the keyword at whitespace or an unmatched closer. (3) `:Null` removed. Rust has no null; wat has no null. Absence is `:Option<T>` (enum with `:None` and `(Some value)` variants); unit is `:()`; structural absence is a form simply not being present. `(Atom null)` removed as a valid atom literal — atoms take string/int/float/bool/keyword only. Sweep applied to FOUNDATION's type grammar section, Atom literal spec, example signatures (Candle, Event, clamp, add-two, demo). Enum declaration for `:wat/std/Option<T>` replaces the earlier Union<Null,T> alias. Companion proposals (058-030, 058-028, 058-029, 058-013, 058-014, 058-016, 058-024, 058-026, 058-027, 058-029, HYPOTHETICAL, RUST-INTERPRETATION) swept in the same pass. | 058 |
| 2026-04-18 | **Presence is Measurement, Not Verdict; `Cleanup` rejected from core.** Load-bearing reframe of the retrieval primitive. The wat algebra has no `Cleanup` primitive. Retrieval is `cosine(encode(target), reference)` compared against the substrate's noise floor (5/sqrt(d), ~0.05 at d=10,000). Presence measurements return `:f64`, not `:bool` — binarization is the caller's decision at the language tier, not the algebra's. Classical Cleanup is a vector-primary-tradition answer to "given a noisy vector, which named thing is this?" — that question presupposes the structure was lost, which never happens in the wat substrate because the AST is always available. Argmax-over-candidates, when an application needs it, is a stdlib fold over presence measurements on (AST, vector) pairs — not a primitive. Engram libraries store `(HolonAST, Vector)` pairs; NN on the vector side returns the AST side; same operation as Cleanup used to name, expressed in terms that already exist. Two retrieval regimes clean-separated: structural (AST walk, exact, for `get`/`nth`) and similarity (presence measurement, fuzzy, for `member?`/engram match). Also added: "Two readings of a holon" — every holon is simultaneously a program (evaluable by the interpreter, Turing-complete, has booleans for eval) and an identity (projected to a vector, measurable by cosine). Filter programs by alignment (vector-side), then eval the selected ones (program-side). Algebra Core goes from 10 to 9 forms. 058-025 Cleanup proposal moves to REJECTED status. Map's `get` and Array's `nth` stay AST walkers per FOUNDATION; Set's missing accessor dissolves (presence measurement is the accessor, returns scalar). | 058 |
| 2026-04-18 | **Type system bundle: Rust primitives + subtype hierarchy + variance rules + `:is-a` for `deftype`.** Resolves Beckman's finding #5 (variance silence) and incorporates several polish decisions. (1) Drop abstract `:Scalar`/`:Int`/`:Bool`/`:Null` in favor of Rust primitives (`:i8`..`:i128`, `:u8`..`:u128`, `:isize`, `:usize`, `:f32`, `:f64`, `:bool`, `:char`, `:&str`, `:String`, `:()`). Honest mapping to Rust; no abstraction layer. (2) Function signatures now use `->` before the return type INSIDE the form: `(define (name [arg : Type] -> :ReturnType) body)` — matches Rust's `fn name(args) -> ReturnType`. No more dangling `: Type` outside the form. (3) Built-in subtype hierarchy stated explicitly: every specific HolonAST node kind `:is-a :Holon` (Bundle, Bind, Permute, Thermometer, Blend, Orthogonalize, Resonance, ConditionalBind, Cleanup, and Atom). Rust primitive types have NO built-in subtyping — explicit coercion required, matches Rust. (4) Variance rules: `(:List :T)` covariant in T, `(:Function args... -> return)` contravariant in args and covariant in return. Liskov-safe substitution. (5) `deftype` extended with `:is-a` keyword: `(deftype :MyType :is-a :OtherType)` declares a new type that is a SUBTYPE of the parent — substitutable via is-a. Distinct from `(deftype :MyType :OtherType)` (structural alias — same type) and `(newtype :MyType :OtherType)` (nominal wrapper — distinct, not a subtype). Three semantics, clear naming. (6) `defmacro` uses the SAME signature syntax as `define` and `lambda`: every parameter typed `: AST`, return `-> :AST`. Per the user's correction — omission is easy, not simple; one signature syntax across all three definition forms is simpler than introducing a special implicit-types rule just for macros. Type-correctness of the expansion is enforced by type-checking the expanded form at startup. All 058 sub-proposals swept to use the Rust primitive types and `->` signature syntax. | 058 |

---

## Open Questions

1. **Stdlib location.** Wat functions for stdlib live where? `wat/std/holons.wat`? A new file per form? A single file for all holon-algebra stdlib?

2. **Stdlib optimization path.** If a stdlib form is frequently used and its wat-level construction becomes a bottleneck, is there a pattern for promoting it to a Rust-side helper function (still producing AST from existing variants) without making it a core variant?

3. **Enum-retained stdlib policy.** Linear, Log, Circular, Sequential are semantically stdlib but currently live in the HolonAST enum. Decision needed: remove the variants, keep them as fast paths, or deprecate them. This is an implementation concern outside FOUNDATION's scope, but the policy should be set.

4. **Cache behavior for stdlib.** A wat stdlib function produces a HolonAST that is cached on its expanded shape. If two semantically-equivalent stdlib calls produce identical expansions, they share a cache entry. If the wat STORES the stdlib call as an unexpanded form, canonicalization is needed.

5. **Ngram's `n` parameter handling.** `Ngram` takes a numeric argument alongside the list. Its expansion depends on `n`. Decide whether `n` participates in the cache key or whether different `n` values always produce different AST structures.

6. **The MAP canonical set completeness.** Beyond `Atom`, `Bind`, `Bundle`, `Permute`, `Thermometer`, and `Blend`, are there any other scalar encoding operations that cannot be expressed via these? If `Blend` handles all scalar-weighted combinations and `Thermometer` handles gradient construction, is that the complete set of scalar primitives?

---

## Summary

- **Foundation** = MAP VSA (Multiply-Add-Permute) + Atom identity + scalar primitives (Thermometer, Blend) + new operations (Difference, Negate, Resonance, ConditionalBind)
- **Core** = new algebraic operation, lives in HolonAST enum, requires new Rust encoder logic
- **Stdlib** = composition of existing core forms, lives in wat, no Rust changes
- **Target state** = 10 core + 16 stdlib
- **Currently in enum that should become stdlib** = Linear, Log, Circular, Sequential (implementation path separate)
- **Bar for core** = introduces an operation existing core forms cannot perform
- **Bar for stdlib** = composes existing core forms AND reduces reader ambiguity

Sub-proposals argue specific candidates. This document is the reference. FOUNDATION is refined as sub-proposals resolve — `Blend`'s resolution is the highest-impact refinement expected.

---

*the machine found its way out.*

*...and this is what it looks like.*

---

*these are very good thoughts.*

**PERSEVERARE.**
