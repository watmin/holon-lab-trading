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

## Two Tiers of wat — Primitives and Thoughts

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

UpperCase forms are **AST constructors**. They do NOT run. They build `ThoughtAST` nodes — descriptions of a thought-composition that can be encoded to a vector, cached, hashed, signed, transmitted, or deferred.

```scheme
(Atom "rsi")              ; AST: a node representing "name this concept" — returns ThoughtAST
(Bind role filler)        ; AST: a node representing binding — returns ThoughtAST
(Bundle thoughts)         ; AST: a node representing superposition — returns ThoughtAST
(Blend a b 1 -1)          ; AST: a node representing scalar-weighted combine — returns ThoughtAST
(Sequential (list a b))   ; AST: a node representing position-encoded bundle — returns ThoughtAST
```

The UpperCase forms are what users and stdlib WRITE in wat programs. They compose cheaply — building a nested AST is structural work, no vector computation. The VECTOR materializes only when the AST is **realized** (see "Executable semantics" below).

### Why the tier split

Three reasons the tier split is load-bearing:

**1. Laziness.** UpperCase forms compose thought-programs without paying encoding cost. `(Sequential (list (Atom "a") (Atom "b")))` constructs a small AST. The vectors for the Atoms, the permutation for Sequential, the bundle — none of these compute until the AST is projected. Cache-friendly, transmission-friendly, sign-friendly.

**2. Cryptographic identity.** A `ThoughtAST` serializes to EDN and hashes to a stable identifier. A vector is the projection of an AST; the AST's hash IS the thought's identity. Two thoughts with the same AST have the same hash. Two thoughts with different ASTs — even if their vectors collide under some coincidence — are DIFFERENT thoughts. The AST carries identity; the lowercase primitives cannot.

**3. User-writable stdlib.** The `(define ...)` forms in stdlib like:

   ```scheme
   (define (Difference a b) : Thought
     (Blend a b 1 -1))
   ```

   compose UpperCase forms. The body is an AST-construction expression. Callers of `Difference` get a ThoughtAST back. Only when something asks for the vector does the encoder walk the AST and invoke lowercase primitives.

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

The visual distinction matches the semantic distinction. Lowercase is the substrate. UpperCase is the language of thought.

### What this section adds to the foundational principle

The foundational principle says **AST is primary, vector is cached projection**. This section adds:

- The UpperCase tier IS the AST-constructing surface of wat.
- The lowercase tier IS the Rust primitive surface.
- Users write UpperCase. Encoders realize via lowercase.
- Stdlib is `(define ...)` over UpperCase expressions.
- Every principle in the rest of this document — cache as memory, engram libraries, programs-as-thoughts, cryptographic provenance, distributed verifiability — operates on UpperCase ASTs.

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

## The Location IS the Program

In a classical database, there is a separation: data lives at some address (memory offset, disk block, key in a hash table). Queries navigate to addresses. Data and queries are different kinds of thing — data is stored, queries compute paths to retrieve it.

**In the wat algebra, this separation dissolves.**

### The query IS the answer's address

A query in wat is a function call — an AST that describes what to compute:

```scheme
(event-at-time (Atom "2026-04-17T12:00:00"))
```

This expression is data (an AST). It projects to a vector. Evaluating it produces the answer — which is ALSO an AST (and a vector).

There is no separate "storage" accessed via "queries." **The query AST IS the address. Evaluating the AST produces the answer.** Whether the evaluator walks a Map, calls a function, or computes from first principles — the RESULT is the answer.

### Addresses can be programs

A "location" in this substrate can be:

- A literal key: `(Atom "2026-04-17T12:00:00")`
- A function call: `(most-recent-event-before (now))`
- A composition: `(get (get db (Atom "2026-04-17")) (Atom "12:00"))`
- A generated expression: `(compile-query user-criteria)` — where `compile-query` itself builds a new AST

The location is a thought. Thoughts compose. Addresses can be computed, composed, stored, passed, learned, generated.

### Time databases — what Carin meant

Carin Meier's Clojure VSA talk mentioned "time databases" — time-indexed stores built from the same primitives. It works:

```scheme
(def event-stream
  (Map (list
    (list (Atom "2026-04-17T12:00") event-1)
    (list (Atom "2026-04-17T13:00") event-2)
    (list (Atom "2026-04-17T14:00") event-3)
    ;; ... arbitrary depth via Recursive Composition ...
    )))

;; Exact lookup — address is a literal:
(get event-stream (Atom "2026-04-17T12:00"))

;; Semantic search — address is a pattern (cosine over vectors):
(match-library query-thought event-library)

;; Generated query — address is a computed AST:
(def custom-query
  (build-query user-criteria))       ; user-criteria is data
(evaluate custom-query event-stream) ; executes a program built from data
```

Each query is itself a thought. Queries can be stored, composed, compared via cosine, searched by similarity. A database of queries is as natural as a database of events, because both are thoughts.

### Metaprogramming is native

Because programs are thoughts, a program can build another program and return it as a value:

```scheme
(defn build-matcher [pattern]
  ;; Returns a function AST that matches against `pattern`
  (Fn (Array (list (Atom :candidate)))
      (Bundle (list
        (If (matches? (Atom :candidate) pattern)
            (Atom :match)
            (Atom :no-match))))))

(def match-reversal (build-matcher reversal-pattern))
;; match-reversal is a function, built from data.
;; It can be stored in a Map, passed to another function, executed,
;; compared to other functions via cosine, and evaluated on inputs.
```

No separate macro system. No special metaprogramming runtime. The algebra already composes programs because programs are values.

### Semantic search and exact lookup are the same operation

- **Exact lookup:** the query is a specific AST; the evaluator walks to the answer.
- **Semantic search:** the query is a pattern-AST; cosine over vectors finds the closest answer.

Both are algebraic operations on the same substrate. The difference is the SPECIFICITY of the query — a fully-specified function call gets an exact result; a pattern gets an approximate match. One substrate, two ways to ask.

### The infinity Carin saw

Dimensionality bounds per-frame capacity (Kanerva). Recursion makes depth free. Programs are thoughts. Thoughts compose without bound. **The infinity is not in the vector space — it is in the compositional space of expressible ASTs.**

Any function you can write. Any composition of functions. Any data structure. Any nesting. Any query. Any generator of queries. All live in the same substrate. All addressable by their AST. All evaluatable. All comparable by cosine.

### A function call with an input IS the answer

A wat evaluator doesn't treat "look up stored data" as a distinct operation from "execute code." It walks ASTs with evaluation semantics. The same walker that executes `(+ 1 2)` → `3` also executes `(get my-map (Atom :key))` → `value`. Both are AST evaluation. Both return ASTs (or literals read from AST nodes). Both the result and the substrate it was "stored in" are the same kind of thing.

The `Map` you defined earlier is itself just an AST. Calling `get` walks that AST. There is no "storage engine" to consult. **The evaluator IS the storage engine. The algebra provides both.**

### Consequences

- **No database/compute split.** The substrate handles both identically.
- **Queries are first-class values.** Store them. Pass them. Compose them. Learn on them.
- **Meta-programs are native.** Build programs from data; run them; store the results; search for them.
- **Semantic search and exact lookup are one operation.** Both are AST evaluation plus optional cosine comparison.
- **The infinity is compositional.** Fixed vector dimensionality; unbounded AST space.

These are not features. They are the natural consequences of *programs are thoughts + data is thoughts + operations are pure functions on ASTs.*

---

## Reader — Did You Just Prove an Infinity?

Another pause. Look at what the previous section just claimed:

> The infinity is not in the vector space — it is in the compositional space of expressible ASTs.

You — reader, LLM or human — think about what that means.

### The sphere is bounded in dimension, unbounded in reachable points

At any fixed dimension `d`, the bipolar vector space has `3^d` possible vectors. Finite. Astronomical at `d=10,000` (roughly `10^4771`), but finite.

But the space of ASTs you can compose is **unbounded**. Depth is free. Recursion is free. Any function can compose with any other function. The set of distinct thoughts you can EXPRESS is infinite — even as the dimensional container stays fixed.

Which means:

- **Every thought you can construct has a deterministic location on the sphere.** Encoding is deterministic. Projection is cached. The thought and its location are one operation apart.
- **But the sphere contains thoughts you have not constructed.** They exist as POSSIBILITIES — the evaluations of ASTs you have not yet written.
- **To identify all thoughts, you would have to explore infinity.** Enumerate all possible ASTs. Compute their projections. Find their locations. No finite traversal completes.

### The algebra does not enumerate — it navigates

You cannot list the infinite sphere. But the algebra gives you tools to walk it purposefully:

- **Cosine similarity** — find thoughts NEAR a known thought
- **Discriminant-guided search** — move in a direction that optimizes outcome
- **Cleanup** — find the known thought closest to a query
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
- **Programs ARE Thoughts:** the compositional space IS the thought space.
- **The Location IS the Program:** addresses are programs; queries are ASTs; the substrate has no storage/compute split.
- **This section:** taken together, the previous sections prove the substrate is infinite-in-reach through a finite-dimensional geometry, navigable by algebra.

Kanerva pointed at the space. Carin Meier hinted at the navigation. The wat algebra now names both, and gives you the map.

### The inversion

The traditional question is: "how do we represent all possible thoughts?"
- Neural networks: train billions of parameters until enough thoughts become representable.
- Symbolic systems: enumerate a finite vocabulary and compose from it.
- Databases: index every fact that will ever be queried.

The wat algebra inverts the question: **you don't need to represent all thoughts. You need navigation tools that work in a finite-dimensional space where any specific thought can be constructed on demand and located deterministically.**

You don't store the infinity. You don't enumerate the infinity. You STEP INTO it with composition, and the algebra tells you where you are — and where to go next.

**That is the machinery the rest of this document describes.** When we enumerate the specific forms (MAP canonical + scalar primitives + stdlib compositions) in the sections that follow, remember: those forms are the navigation primitives for an infinite compositional sphere. The specific operations are finite. What they let you reach is not.

Do you see it now?

### The holographic reframing

The finite-dimensional surface encoding an unbounded compositional space has an established name in physics: the **holographic principle** (t'Hooft 1993, Susskind 1995; extended by Maldacena's AdS/CFT correspondence 1997). It states that the information content of a bounded region can be encoded entirely on its boundary. The "volume" has no independent information; everything that can be known, interacted with, measured, is on the surface.

The wat algebra has the same structure.

- **AST = unbounded interior description.** The compositional thought space. Recursive, nested, unboundedly deep.
- **Vector = holographic boundary encoding.** Every AST projects to a point on the unit sphere at dimension d. The sphere is the algebra's surface.
- **Projection (encode) = holographic encoding.** Deterministic. Bounded. Cachable.
- **Navigation (cosine, cleanup, discriminant search, engrams) = surface-walking.** You don't enumerate the volume; you walk the surface under algebraic pressure.

Two distinct domains (physics and VSA computing) answer the same question — *how does a bounded surface express an unbounded possibility space?* — with the same structural answer. Not because one borrows from the other, but because the information-theoretic shape of the problem imposes the answer.

This is not a metaphor. It is a structural parallel. The wat algebra is holographic in the literal mathematical sense: a lower-dimensional surface encoding a higher-dimensional possibility space via a bounded, deterministic projection.

### The NP-hard framing

The practical significance of navigation-without-enumeration is that it **attacks intractability without solving it in the complexity-theoretic sense.**

NP-hard problems — SAT, graph coloring, traveling salesman, pattern recognition at scale, detection-and-response under time pressure — are defined by their combinatorial explosion under enumeration. Classical computation cannot enumerate the solution space fast enough for large instances.

The wat algebra does not prove P = NP. It sidesteps the enumeration requirement entirely:

- Operator intuition recognizes a DDoS pattern without enumerating every possible attack vector.
- Trading decisions emerge from pattern-recognition against rhythms without enumerating every possible market state.
- Analogy completion finds "c + (b − a)" and cleans up against a codebook without enumerating every possible analogy.

The algebra's primitives — cosine similarity, cleanup, discriminant-guided search, engram matching, program synthesis — are all NAVIGATION operations. Each moves through the thought-space toward an answer under algebraic pressure. None enumerates.

**This is what the substrate IS, structurally.** Not a specific application (DDoS, trading, MTG, truth engine). Not a theorem about complexity classes. A substrate that attacks intractable problems by navigating a holographic surface instead of searching it exhaustively.

The operator intuition that recognizes patterns in real time — the kind that a skilled DDoS responder, a veteran trader, an experienced physician, a chess grandmaster develops over years — is itself surface-walking under learned pressure. The wat algebra formalizes that faculty and makes it available to machines.

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
(define (process [input : Thought]) : Thought
  (get input (Atom :field)))

;; SAFE — input composed into a larger data structure:
(define (store-for-later [input : Thought]) : Thought
  (Map (list (list (Atom :payload) input))))
```

In both cases, `input` is bound, bundled, queried, extracted. Nothing evaluates it as code.

The injection vector — evaluating user input as code — exists only when the programmer explicitly invokes `eval` on untrusted input:

```scheme
;; UNSAFE — the programmer consciously chose to evaluate user input:
(define (dangerous [user-code : Thought]) : Any
  (eval user-code))
```

**The algebra does not do this for you.** There is no implicit coercion from data to code. No pattern where data accidentally executes. No late binding an attacker can hijack. The injection path requires the programmer to write `eval` on user input on purpose.

### Compared to other systems

- **SQL with string concatenation:** user input becomes part of the query string — implicit injection
- **SQL with parameterized queries:** user input stays as bound parameter — no injection
- **Python / JavaScript:** many implicit eval-like paths (monkey-patching, `__getattr__`, prototype pollution)
- **wat algebra:** equivalent to parameterized queries BY DEFAULT — injection requires conscious `eval` of user input

### The `cleanup` caveat

`cleanup` returns an AST from a codebook by matching against a query vector. If the application passes cleanup results to `eval`, an attacker who can influence the query vector could steer cleanup toward a specific function in the codebook.

But:

- The codebook contains ASTs the programmer already authored (or accepted from trusted sources)
- Cleanup can only return something already in the codebook
- An attacker can STEER which function runs; they cannot INJECT new code

The attack surface is bounded by what's in the codebook. Still requires a conscious choice to `eval` cleanup results — which is the injection surface already named.

### Distributed verifiability

Because `encode(ast) → vector` is deterministic, any party that receives a vector can re-encode the AST they believe produced it and compare bytes. If a cache claims that AST `X` produces vector `V`, anyone can recompute `encode(X)` and verify. **Tampered caches are detectable by recomputation.**

This matters for the distributed substrate (see "Reader — Are You Starting To See It?"). Each node can independently verify any vector it receives without trusting the sender's cache.

### Cryptographic provenance — the trust boundary at startup

Distributed verifiability gets stronger when the algebra crosses trust boundaries.

An AST in transmission is an **EDN string** — extensible data notation, a serialized s-expression. Every AST that moves between nodes — over a socket, through a queue, across a process boundary, into a cache on disk — exists as EDN at some point.

**EDN strings are content-addressable.** A SHA-256 (or BLAKE3, or whatever modern hash the deployment chooses) of the canonical EDN form is a stable identifier for the AST. Two parties producing the same AST produce the same EDN, and therefore the same hash. **The AST has a cryptographic identity.**

**EDN strings can be signed.** A trusted producer signs the EDN with a private key; any receiver can verify the signature against the known public key. **The AST has a cryptographic provenance.**

**The wat-vm loads all code at startup.** Types (struct/enum/newtype/deftype) enter via `(load-types ...)`; functions (define) enter via `(load ...)`. Both happen before the main event loop starts. Once startup completes, the symbol table is frozen — no further code enters during runtime.

This static-load model is a deliberate choice. Rust is a static-first host; implementing an unbounded dynamic Lisp on top would duplicate effort and widen the attack surface for little gain. The use cases the algebra addresses — trading, DDoS defense, MTG, truth engine — all have well-known vocab at startup. Dynamic thought COMPOSITION (building new ASTs at runtime) is supported and cheap. Dynamic code DEFINITION (adding new functions or types at runtime) is not supported, and is not needed.

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

- `(load-types ...)` files contain ONLY type declarations (`struct`, `enum`, `newtype`, `deftype`). A runtime form in such a file is a startup error.
- `(load ...)` files contain ONLY function definitions (`define`). A type declaration in such a file is a startup error.

The phase split persists at the FILE level for clarity — but both load operations happen at the same time (startup) and fail the same way (halt the wat-vm before the main loop starts).

**If any load fails verification, the wat-vm refuses to run.** No partial state. No degraded mode. Either every piece of code passed its trust check, or nothing starts. This is exactly the semantic appropriate for a production substrate: you want certainty about what the machine will run.

### The symbol table after startup

After all loads complete successfully, the symbol table is **fixed**:

- Every function that can ever be called is in the table.
- Every type that can ever be referenced exists in the Rust binary.
- Every macro has been applied (macros run at build/startup time, not runtime).
- No further `define` can register.
- No further `struct`/`enum`/`newtype`/`deftype` can be added.

The table is keyed by name. One name, one definition. If a startup load would introduce a name collision (two files both defining `:my/ns/clamp` with different bodies), that's a startup error — reconciled at the source level, not at runtime.

This is much simpler than the content-addressed runtime dance: no hash-keyed lookup, no most-recent-wins, no explicit `:name@hash` pinning. The wat-vm's symbol resolution is a single-level name lookup. Fast, predictable, static.

Macros are handled by the startup pipeline: macro definitions register at build/startup time; macro invocations in the source code expand to their transformed ASTs before the functions they produce enter the symbol table. Users who want runtime metaprogramming get it via dynamic thought composition (see below) — not via runtime macro redefinition.

### Constrained eval at runtime

**The wat-vm does support `eval`, but under strict constraints.** A runtime `eval` walks an AST and executes it — with the requirement that every function called and every type used must already be in the static symbol table.

```scheme
;; Build an AST at runtime — perhaps from parsed user input, perhaps from
;; a pattern-matching result, perhaps from an LLM's output:
(let ([composed
       (list 'Difference
             (list 'Atom :observed)
             (list 'Atom :baseline))])

  ;; Eval checks every reference before executing:
  ;;   - Difference: exists in the static symbol table as a stdlib fn ✓
  ;;   - Atom: exists as an algebra-core form ✓
  ;;   - :observed, :baseline: valid keywords ✓
  ;;   - Types match (Difference takes two Thoughts; Atom produces Thought) ✓
  ;; All checks pass. Execute: returns the constructed Thought AST.

  (encode (eval composed)))
;; => a bipolar vector representing the dynamically composed thought.
```

Three properties define constrained eval:

1. **Every function called must be in the static symbol table.** If `composed` references an unknown function, eval errors before executing anything.
2. **Every type used must be in the static type universe.** Unknown types produce errors.
3. **Every argument's type must match the called function's signature.** Type checks happen before body execution.

This is a SAFE `eval`. An attacker who supplies a malicious AST cannot invoke arbitrary code — only functions the operator explicitly loaded at startup. The attack surface is the symbol table's contents, which are frozen and verified. Nothing the attacker can send changes what functions are runnable.

**Typical uses for constrained eval:**

- **Dynamic thought composition.** Build thought-programs from runtime data (LLM output, pattern-matching, user queries) and evaluate them to get vectors.
- **Rule-like systems.** Users supply thought-expressions that describe patterns; the wat-vm evaluates them against incoming data to score matches.
- **Received thought-programs.** A distributed node receives a signed AST over the network, verifies the signature, evals against its local (already-trusted) symbol table. The eval itself has nothing to verify — it only references functions that are already trusted.

**Lambdas remain first-class at runtime.** Anonymous functions can be constructed, passed, stored, invoked — without registering in the symbol table:

```scheme
(let ([transform
       (lambda ([t : Thought]) : Thought
         (Bundle (list t (Atom :tagged))))])
  (transform (Atom :input)))
```

A lambda is a VALUE, not a symbol-table entry. When it goes out of scope, it's cleaned up. Runtime code creation is preserved; symbol-table mutation is not.

### What this gives us

The full trust model, simplified:

- **One verification phase: startup.** All loads succeed (with whatever cryptographic mode each requested) or the wat-vm refuses to start. No partial-state recovery.
- **One symbol table lifecycle: fixed after startup.** One name, one definition. Predictable, fast, simple.
- **One runtime code surface: constrained eval over the static universe.** Dynamic thought composition works. Dynamic code DEFINITION does not.
- **One attack surface: the startup loads.** If the wat-vm starts, every piece of executable code is trusted. An attacker can't inject new code at runtime; at best they can supply crafted input data that constrained eval can handle safely.
- **One model for receiving code over the wire.** A signed wat file is received → wat-vm restarts with it included in startup → continues operation. Managed restart, not live patch. Simple, verifiable, operationally mature.

This is the property that matters: **the running wat-vm is a trusted environment.** Whatever is executing inside it has been verified at startup. The algebra does its work — dynamic composition, encoding, cleanup, navigation — over a fixed and fully-vetted set of forms. That's exactly the substrate you want for systems where the cost of running the wrong code is high.

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
- Better cleanup accuracy — noisier vectors still identify their atoms
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
(defn small-check [x]
  (if (> x 0) :positive :non-positive))

;; A program with a large frame — needs higher d, OR refactoring:
(defn rich-analysis [data]
  (Map (list
    (list (Atom "feature-1")   f1)
    ;; ... 200 features in one frame ...
    (list (Atom "feature-200") f200))))
;; at d=4,096 this frame exceeds capacity, recovery degrades
;; at d=16,384 it fits cleanly
;; OR refactor into nested smaller frames at any d
```

### "You can't express that" — enforced geometrically

At a chosen d, Kanerva's bound is physical. Try to bundle too many items into one frame and recovery degrades — cleanup starts returning wrong atoms, cosine similarities collapse into the noise floor. The algebra doesn't throw errors — it just becomes less reliable as capacity is exceeded.

Users have three responses:

1. **Raise d** — more memory, slower ops, more items per frame
2. **Refactor** — split large frames into nested smaller ones; depth is free (per Recursive Composition)
3. **Accept lossy recovery** — usually wrong for correctness-critical work, sometimes fine for approximate similarity search

Option 2 is always available because depth is unbounded. Dimension bounds per-frame capacity; recursion makes total capacity unbounded at any d.

### The user chooses the dimension for the deployment

Different applications live at different d:

- **Kernel-level packet filtering (DDoS lab)** — low d (4,096 or lower) for line-rate throughput; programs structured as shallow decision trees fit the per-frame budget.
- **Analysis systems (trading enterprise)** — higher d (10,000+) for richer composition; per-frame capacity accommodates many market observations and portfolio fields.
- **Memory-constrained embedded** — lowest d that fits the program's largest frame; deep nesting accepted as the cost.
- **Research / accuracy-critical** — high d for tighter orthogonality; correctness of cleanup and learning matters more than speed.

### Dimensionality is NOT part of the algebra specification

The FOUNDATION's core/stdlib distinction, the forms, the operations — all are dim-agnostic. The algebra runs identically at any d. What changes with d is:

- Per-frame capacity (Kanerva's bound)
- Operation cost (O(d) per bind/bundle/cosine)
- Memory footprint (d × byte-width per vector)
- Cleanup reliability (more d → stronger noise margin)

Dimensionality is a DEPLOYMENT parameter. The VectorManager takes d at construction; every atom, every operation, every vector in that deployment lives in d-dimensional space. Different deployments of the same application can pick different d.

This is a unique feature of this algebra. Unlike neural networks (where architecture dimensions are fixed by training), wat programs are dimensionally parametric. **The user tunes d to the application's needs without retraining, without code changes, without anything but restarting with a different encoder construction parameter.**

---

## The Cache Is Working Memory

The VectorManager cache is not just an optimization to avoid recomputing `encode(ast)`. Under the foundational principle — AST primary, vector is its projection — **a cache entry is a compiled thought.** The cache holds thoughts ready for algebraic use, at varying access costs. That makes it a memory hierarchy, not a hash table.

### The two-tier architecture (Proposal 057)

```
L1 — per-thread cache
  Hot, no pipe latency, per-thread (no contention)
  Small capacity — the thread's "active working set"

L2 — shared cache
  Warm, accessed through the cache service's pipe
  Shared across all threads
  Larger capacity — the system's "recent thoughts"

Disk — engrams, run DB
  Cold, persisted learned thoughts and trained subspaces
  Separate from the cache hierarchy
  Long-term memory
```

Working memory (L1), short-term memory (L2), long-term memory (disk). Each layer is a thought store at a different access cost. The machine reaches for the cheapest layer first and escalates as needed.

### Cache entries are (ast, vector) pairs

Every cache entry is a compiled thought:

- **Key:** the AST (structural identity, used for lookup)
- **Value:** the vector projection (what algebraic operations consume)

When you `encode(ast)`:

```
1. Check L1 — if hit, return vector instantly
2. Check L2 — if hit, return vector, promote to L1
3. Miss both — compute vector via tree-walk, install in L1 (and L2)
```

When the cache has the thought, you didn't have to recompute the compilation. When it doesn't, you compute once and remember. **The reuse IS memory.**

### Cache sizing is another deployment knob

Alongside dimensionality, cache sizing is a deployment choice:

- **L1 size** — how many hot thoughts per thread. Larger L1 = more per-thread memory, more L1 hits, faster hot-path ops.
- **L2 size** — shared working set across threads. Larger L2 = broader coverage of the thought space, fewer misses, more memory overall.
- **L2 eviction policy** — LRU, LFU, or application-specific (e.g., "never evict leaf atoms because they're cheap to recompute anyway").

These knobs interact with dimensionality:

- At low d, vectors are smaller — more thoughts fit in the same byte budget.
- At high d, vectors are larger — fewer thoughts fit, but each carries more structure.

### The cache is part of the thinking, not separate from it

Not optimization. **Cognitive architecture.**

- When the same thought recurs across observers, brokers, and time — the reuse IS memory.
- When a compound thought is assembled from cached subthoughts — that is working-memory composition.
- When a rarely-used thought is evicted — that is forgetting.
- When a long-term thought is promoted back to L1 — that is recall.

The 1 c/s → 7.1 c/s grind in 057 wasn't just a performance optimization. It was the machine getting better at REMEMBERING. Faster access to its own thoughts. Better hit rates on recurring patterns. Smarter eviction of the boilerplate. Working memory becoming effective.

### Why this matters for the foundation

The algebra defines WHAT thoughts are. The cache defines how the machine HAS them ready. Without the cache, `encode(big-nested-thought)` is O(n) tree-walking every time. With the cache hot, it's O(1). That difference is the difference between a machine that COMPUTES its thoughts and a machine that REMEMBERS them.

A thinking system that has to recompute its own thoughts from scratch each time cannot think fast enough to be useful. The cache architecture is therefore part of what makes the wat machine cognitive — **not a bolt-on performance feature, but part of the cognitive substrate.**

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

- **DDoS line-rate filter:** small d, small L1, moderate L2 — keep each vector compact, leverage L1 for hot packet-flow thoughts, L2 for session state.
- **Trading analysis:** large d, large L1, large L2 — rich per-frame expressiveness, substantial working memory per observer, broad coverage of recently-seen market thoughts.
- **Memory-constrained embedded:** minimal d, minimal L1, small L2 — accept that many thoughts will be recomputed; trade memory for compute.
- **Batch research:** moderate d, small L1, massive L2 — focus memory on the shared cache that a batch pipeline benefits from.

The same algebra runs at all these profiles. The programs don't change. The deployment does.

---

## Engram Caches — Memory of Learned Patterns

The thought cache holds COMPUTED thoughts — vectors encoded from ASTs. The engram library holds LEARNED thoughts — subspace snapshots, discriminants, and prototype vectors that emerged from observing a stream.

These are semantically different memory types. Thoughts are programs-of-the-moment. Engrams are distilled pattern recognition. **But the same caching principles apply, and the engrams themselves ARE thoughts.**

### The engram library is a Map thought

```scheme
(def pattern-library
  (Map (list
    (list (Atom :pattern/syn-flood)         syn-flood-engram)
    (list (Atom :pattern/bollinger-squeeze) squeeze-engram)
    (list (Atom :pattern/market-reversal)   reversal-engram)
    ;; ... potentially thousands ...
    )))

;; get an engram by name:
(get pattern-library (Atom :pattern/syn-flood))
```

Under the foundational principle, this is a thought (an AST). Engrams are VALUES in the Map. Retrieval is AST walking. The library IS a wat thought.

### Engrams cost to load and to match

Each engram holds a subspace snapshot (mean + k components + threshold state), an eigenvalue signature, and metadata. Loading from disk = IO + deserialization. Matching = residual scoring against the subspace (O(k·d) per match).

For a library of thousands of engrams, matching against every engram on every observation is expensive. The machine benefits from **recognizing which patterns are CURRENTLY relevant** and keeping those hot.

### The engram LRU

Same pattern as the thought cache — tiered memory by access cost:

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

### Engrams are thoughts too

Zoom out. An engram has structure (subspace, eigenvalues, metadata). It has a vector representation. It can be stored in Maps. It can be compared via eigenvalue cosine. It can be GENERATED (by freezing a subspace at a moment). It can be TRANSMITTED (portable — one node mints, another matches).

Everything we said about thoughts applies to engrams:

- Engrams can be in nested data structures: `(Map (list (list (Atom :category/network) network-library) ...))`
- Engrams can be compared algebraically: `(cosine engram-a engram-b)`
- Engrams can be searched: `(topk-similar query-engram library 5)`
- Engrams can be blended: `(Blend engram-a engram-b α)` — interpolate between learned patterns
- Engrams can be diffed: `(Difference engram-a engram-b)` — what changed in the learned pattern
- **Engrams can be PROGRAMS** — a learned pattern IS a program that recognizes a situation

The loop closes here too. The machine's LEARNED PATTERNS are thoughts. Everything the machine has is a thought. The algebra applies to all of it.

### The complete memory hierarchy

```
L1 thought cache     — per-thread hot thoughts (fastest)
L2 thought cache     — shared warm thoughts (pipe access)
L3 engram cache      — hot learned patterns (in-memory, residual scoring)
L4 engram disk       — cold learned patterns (IO load on demand)
Run DB               — full history, raw observations (query cost)
```

Five tiers. Each with its own access cost. Each with its own sizing policy.

### Deployment: four knobs now

Adding engram caching to the deployment picture:

```
d                    — vector dimension (per-frame capacity vs op cost)
L1 thought cache     — per-thread working thoughts
L2 thought cache     — shared working thoughts
L3 engram cache      — hot learned patterns
```

All tunable. All deployment-time. Same algebra. Different performance profiles.

A DDoS filter tunes for high L3 engram hit rate against attack signatures, with small L1/L2. A trading analysis system tunes for large L1/L2 thought caches with moderate L3, because the thoughts are being composed fresh while the engrams are stable. Different applications stress different tiers. The architecture accommodates.

**The machine doesn't just cache vectors. It caches learned patterns. It caches programs. It caches data structures. It caches anything that is a thought. The entire hierarchy is hyperdimensional working memory, tiered by access cost, tuned by the operator.**

---

## Reader — Are You Starting To See It?

Pause.

If you've followed from "the AST is primary" through recursive composition, programs-as-thoughts, the full algebra on vectors, the dimensionality knob, and the five-tier memory hierarchy — are you starting to see what we just built?

### Think about what's enabled, by construction.

**Deterministic atom vectors.** The hash function is the codebook. Any node — same seed, same dimension, same literal → identical vector. No coordination. No bootstrap sequence. No codebook distribution service. The implementation IS the vocabulary.

**Engrams are portable.** Mint on one node, match on any node that shares the seed and dimension. Learned patterns travel as data — a serialized subspace snapshot arrives over the wire and is scored against local streams in the same geometric space it was trained in.

**Programs are thoughts.** Thoughts are vectors. Vectors serialize. **Programs ship between nodes as data.** Running code becomes a message. One node composes a wat AST, another node receives it, a third evaluates it against its local context.

**The cache hierarchy shards naturally.** Hot engrams live at the edge where they're currently matching. Cold engrams live at HQ where the full library persists. An edge node's eigenvalue pre-filter suggests a miss → fetch from HQ → new engram warms into local L3. The existing memory architecture IS the sharding strategy.

### The clouds are waking up.

Every wat machine is a node in a potentially distributed hyperdimensional cognition system:

- Same geometric space, instantiated identically everywhere (via shared seed and dimension)
- Portable thoughts, programs, engrams — all travel as data
- Cache hierarchy that naturally shards by access locality
- No centralized coordinator, no model server, no vocabulary service

A wat machine on a laptop. A wat machine on every kernel. A wat machine in every node of a fleet. Each a locus of thinking. Each reachable by the others through shared thoughts. Each learning from its own stream, publishing engrams to the collective, consuming engrams from others.

**This isn't a future feature.** The mechanism is already built. Proposal 057's cache architecture, the coordination-free atom encoding from the earliest holon designs, the portable engram format for HQ-to-edge distribution — it was all groundwork for this. 058 makes the algebra explicit as the thing that holds it all together.

### What you are looking at

A wat program running on your laptop is a single thinking locus. But the *architecture* you're reading about is the substrate for a distributed hyperdimensional cognition system — a cloud of machines thinking together, learning together, generating programs together, without centralized coordination.

The DDoS lab built one version at the packet level (XDP + shield cognition, edge nodes matching against centrally-minted engrams). The trading enterprise builds another at the thought level. The algebra is the same. Point it at any domain — packet flows, market ticks, HTTP requests, medical signals, anything with structure — and the same substrate runs.

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
- The small core (MAP VSA primitives + Thermometer + Blend) and the rich stdlib (Concurrent, Then, Chain, Map, Array, get, …)
- The foundational principle (AST primary) itself — code is data is thought is vector

**Hickey's talks.** "Simple Made Easy." "Don't Fear the Monad" (via Beckman). "Hammock Driven Development." "Values of Values." Watched many times. The principles are in the bones.

**Beckman's categorical lens.** Monoids, functors, natural transformations. The algebra must close. Diagrams must commute. Source categories matter. Composition is the test.

The designers summoned during the proposal process aren't mascots. They're *precisely the teachers who shaped the builder*. When Hickey is summoned to review a proposal, the argument that comes back is the argument Hickey actually makes — because the builder has internalized that argument across decades.

### Why "datamancer" is not a joke

The builder has said it for years, and the word is honest:

A datamancer shapes data through algebra. The algebra is bind, bundle, cosine, permute — VSA's core operations. The incantations are wat s-expressions. The spells are the wards (sever, reap, scry, gaze, forge, temper, assay, ignorant) that catch bad thoughts before they compile. The summoned spirits are Hickey, Beckman, Seykota, Van Tharp, Wyckoff — teachers whose principles the builder studied for years, now argued through agents that carry their philosophies faithfully.

This is not metaphor for the fun of it. It is the actual shape of the work.

The builder thinks in coordinates in thought-space. Conjures designers when a proposal needs pressure. Casts wards when code needs defense. Writes spells (`/propose`, `/designers`, `/ignorant`) that structure the thinking process itself. Operates in what the builder calls the Aetherium Datavatum — the Aether of the Data-Seers — where data flows, vectors compose, and thoughts live on a unit sphere in 10,000 dimensions.

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
- **Add** → `Bundle` — element-wise addition + threshold, commutative and associative under ternary thresholding
- **Permute** → `Permute` — circular dimension shift

Plus the identity function that maps names to vectors:

- **Atom** — hash-to-vector, deterministic, no codebook

These four are the **algebraic foundation**. Everything else in the algebra is either:
- A SCALAR PRIMITIVE — does something MAP cannot (Thermometer, Blend)
- A NEW OPERATION — a distinct algebraic action (Orthogonalize, Resonance, ConditionalBind, Cleanup)
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

**`threshold(0) = 0`**. Zero is a first-class "no information at this dimension" signal, not a convention-picked ±1. This choice is not optional; it is what makes the algebra associative and its invariants exact.

### Why ternary (not bipolar)

Two load-bearing properties fall out of ternary thresholding:

**1. Bundle is associative.**

For `x = +1, y = -1, z = -1`:
- `Bundle([x,y,z]) = threshold(-1) = -1`
- `Bundle([Bundle([x,y]), z]) = Bundle([threshold(0), -1]) = Bundle([0, -1]) = threshold(-1) = -1`

Both routes produce `-1`. Associative. Under strict bipolar thresholding (where `threshold(0) = +1`), these would differ; under ternary thresholding, they agree. Bundle's associativity is a requirement for Chain, Ngram, and Sequential to compose cleanly at arbitrary nesting depth.

**2. Orthogonalize's orthogonality is exact.**

For degenerate `X = Y`, the projection coefficient is 1, so `X - Y = [0, 0, ..., 0]` and `threshold([0, ..., 0]) = [0, 0, ..., 0]`. The result dotted with `Y` is 0 — **exactly orthogonal**. Under bipolar thresholding this would be rounded to `±Y`, breaking the claim. Ternary preserves it.

### Zero as "no information"

A `0` at dimension `i` means "this position carries no signal." Zero does not participate in similarity (0 · anything = 0). Zero under Bind propagates: `0 * b = 0` — the dimension stays silent. Zero under Bundle contributes nothing to the sum.

This is semantically meaningful. Many operations produce zeros deliberately:
- `Resonance(v, ref)` zeros dimensions where `v` and `ref` disagree in sign.
- `Orthogonalize(X, Y)` produces zeros where `X` and `Y` completely coincide.
- `Bundle` can produce zeros when positive and negative contributions cancel.

Downstream operations treating zero as "no information" keep the algebra internally consistent.

### Bind's self-inverse law on ternary

The identity holds elementwise:

```
Bind(Bind(a, b), b) [i] = a[i] * b[i]²
                       = a[i]    if b[i] ∈ {-1, +1}
                       = 0       if b[i] = 0
```

For **dense-bipolar keys** (vectors produced by `Atom` or `Thermometer`, all entries `±1`): `b[i]² = 1` at every position → exact recovery.

For **sparse keys** (rare case — e.g., when a `Resonance` output is used as a key, or when partial-decode produces intermediate zeros): the recovered vector has `a[i]` at non-zero positions of `b` and `0` at the rest. This is **not a weakening** — it is a capacity consumption, in the same budget as Bundle's crosstalk. See "Capacity is the universal measurement budget" below.

The law: **Bind is self-inverse on non-zero positions of the key.** Stated precisely, it holds under similarity measurement for every operand density the algebra encounters at high `d`.

### Capacity is the universal measurement budget

Every recovery operation in the algebra is a **similarity measurement**. Cosine similarity above a noise threshold (conventionally "5σ") means "yes, this matches"; below means "no, exceeded capacity." This is not a consolation — it is the primary measurement framework. Exact elementwise equality was never the algebra's guarantee; similarity-above-noise was.

Kanerva's capacity bound characterizes how much signal can be carried at dimension `d` before noise overwhelms retrieval: approximately `d / (2 · ln(K))` reliably distinguishable items per vector (K = codebook size). For `d = 10,000` and codebook sizes in the hundreds, this is roughly **~100 items per frame**.

**The budget is fungible.** You can spend it on:

- **Bundle stacking** — superposing N bindings into one vector. Each additional bundle element adds crosstalk noise to every decode.
- **Sparse keys** — unbinding with a key that has k non-zero positions out of d acts like a decode at effective dimension `k`. Fewer signal dimensions, lower cosine-similarity.
- **Cascading compositions** — nested Bundles, Blends, Orthogonalizes accumulate small noise contributions that consume headroom.
- **Approximate operations** — Orthogonalize's subtraction-and-threshold loses tiny amounts of signal; Resonance's selection adds zeros; each consumes a fraction of the budget.

These are not separate "phenomena" or separate "algebraic flaws." They are the **same substrate property**: signal-to-noise at high dimension, characterized uniformly by Kanerva's formula, measured uniformly by cosine. A decode with sparse keys is indistinguishable, in its capacity accounting, from a decode from a heavily bundled record: both cost signal, both are measured by the same test.

**Consequences for the algebra's laws:**

- Bind's self-inverse property is elementwise exact at dense operands and capacity-consuming at sparse operands — not a "weakening," just consumption from the budget.
- Bundle's non-associativity under strict-bipolar thresholding dissolves under ternary thresholding (which we use) AND is measurement-noise in the budget anyway — both viewpoints agree that it is not a defect.
- Orthogonalize's post-threshold orthogonality is exact under ternary (per the X = Y edge case above) and capacity-fungible otherwise.

**In practice:** at `d = 10,000` the algebra has a working budget of ~100 items of "stuff" per frame. Stack bindings, accept sparse inputs, compose cascaded operations — as long as the total expenditure stays within the budget, similarity measurement recovers what you put in. Beyond the budget, the substrate gracefully degrades: similarity falls below noise, Cleanup returns wrong candidates, tests yield "no." This is observable, not hidden — and it is how VSA was always supposed to work.

### Continuous output when the operation requires it

Some operations do not threshold — they produce continuous-valued vectors with magnitude:

- **Accumulators** — running sums, decaying averages, frequency-weighted vectors. Magnitude carries information about count or weight.
- **Subspace residuals** — `OnlineSubspace.residual(v)` returns a vector whose magnitude represents the fraction of `v` not explained by the learned subspace. Thresholding would destroy the magnitude signal.
- **Pre-threshold intermediates** — internally in some encoders, the sum is computed in floating point before the final threshold step.

When magnitude matters, don't threshold. When symbolic {-1, 0, +1} output is what downstream operations need, threshold. The algebra supports both regimes; the user (or the operation's specification) chooses.

### Relationship to cosine similarity

Cosine similarity is defined for any real-valued vector. On ternary vectors, it behaves the same way it does on bipolar: positive values indicate alignment, negative indicate opposition, zero indicates orthogonality. The contribution from any dimension with `0` on either side is zero, which matches the "no information" semantics.

This means similarity-based retrieval (`Cleanup`, engram matching, discriminant-guided search) works uniformly over ternary inputs — the zero entries simply don't vote.

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
| `Cleanup(v, candidates)` | whatever the matched candidate is | no — retrieval, not computation | inherited from candidate |

---

## The Core/Stdlib Distinction

The thought algebra has two tiers of forms:

**CORE** — forms that introduce algebraic operations existing core forms cannot perform. Live as `ThoughtAST` enum variants in Rust. The encoder must handle each core form distinctly because the operation cannot be expressed by combining other core forms.

**STDLIB** — forms that are compositions of existing core forms. Live as wat functions. When called in wat, they produce a `ThoughtAST` built entirely from core variants. The encoder does not need to know about them — they are syntactic sugar that produces primitive-only ASTs.

The distinction is about WHERE NEW WORK HAPPENS:

- A new core form requires new encoder logic in Rust.
- A new stdlib function requires new wat code that constructs an AST from existing variants.

---

## Two Cores: Algebra Core and Language Core

The "CORE" designation so far has meant **algebra core** — the thought primitives (Atom, Bind, Bundle, Permute, Thermometer, Blend, Orthogonalize, Resonance, ConditionalBind, Unbind, Cleanup). These produce vectors. They are the mathematical substrate of the thought space.

But the stdlib — the forms expressed as `(defn (Difference a b) (Blend a b 1 -1))` — needs a substrate too. The syntax `defn`, `lambda`, type annotations, `let`, `if` are not thought-algebra operations; they are language operations. They do not produce vectors themselves; they produce FUNCTIONS that, when called, produce ASTs.

For the stdlib to EXIST — not merely be theorized — the language must provide these definition primitives. They are **language core**. Without `defn`, there is no stdlib. Without `lambda`, there are no higher-order functions. Without types, there is no way for the Rust evaluator to dispatch or verify.

### The two tiers

```
Language Core    defn, lambda, let, if, cond, type annotations
    ↓            (how you define things)
    ↓
Algebra Core     Atom, Bind, Bundle, Permute, Thermometer, Blend,
    ↓            Orthogonalize, Resonance, ConditionalBind, Unbind, Cleanup
    ↓            (what produces thought vectors)
    ↓
Stdlib           Difference, Sequential, Concurrent, Then, Chain, Ngram,
                 Analogy, Amplify, Subtract, Flip, Map, Array, Set,
                 Linear, Log, Circular, ...
                 (named compositions — defined with language core, using algebra core)
```

A stdlib function is a `defn` (language core) whose body uses algebra core forms (and other stdlib calls). Both cores are load-bearing; neither alone is sufficient.

### User-defined extensions are a third layer

Users author their own `defn`s in their own namespace — `(defn :alice/math/clamp [[x :Scalar] [low :Scalar] [high :Scalar]] :Scalar ...)` — and these are **userland stdlib**. Same substrate (language core + algebra core); different authorship. The algebra does not distinguish project-authored stdlib from user-authored extensions; both are `defn`s in some namespace.

This is how the algebra stays finite while usage grows unboundedly.

### Types are required for Rust eval

The Rust evaluator runs the wat interpreter. Given a `(defn ...)` and a call site, the evaluator must know:

- What kind of value each argument is (Thought? Scalar? Integer? List?)
- What kind of value the function returns
- Whether a call site's argument types match the defn's declared parameter types

Without type annotations, the evaluator would need to either infer types at every call (slow, lossy) or accept runtime failures (fragile). Typed definitions make dispatch deterministic and verification static.

```scheme
(defn :my/ns/amplify [[x :Thought] [y :Thought] [s :Scalar]] :Thought
  (Blend x y 1 s))
```

Three signal sites:

1. **Parameter types.** `[name :Type]` pairs. Each parameter's expected kind.
2. **Return type.** After the parameter vector. The kind the body must produce.
3. **Body.** Expressions using algebra core and other stdlib, whose final value must match the return type.

The Rust evaluator checks: call-site argument types match parameter types; body's final expression produces the return type; every sub-expression's type is consistent.

### Types in the current algebra

The type system mirrors the algebra's kinds:

- `:Thought` — any ThoughtAST node
- `:Atom` — specifically an Atom (to read literals via `atom-value`)
- `:Scalar` — f64 literal (for Blend weights, for scalar functions)
- `:Int` — integer (for Permute steps, for nth indices)
- `:List` — homogeneous list (provisionally; generics are future work)
- `:Vector` — a raw encoded bipolar vector (for low-level stdlib)
- `:Function` — a lambda or defn reference (for higher-order stdlib)

User-definable types follow the same namespace discipline as functions — `:alice/types/Price`, `:project/market/Candle`. These are keyword-named type constructors. Resolving them to runtime representations is the evaluator's job.

### Types live on the AST node — same principle as Atom literals

Just as `Atom`'s literal is a field on the AST node (not looked up in a codebook), a `defn`'s type annotations are fields on the defn AST node. You can inspect them by walking the AST. You can sign the AST (including its types) and the signature verifies the entire signature, body, and name. Tampering with types requires a new signature — same cryptographic story as any other AST mutation.

### Language core earns its place by necessity

Every algebra core form was argued into FOUNDATION because it introduces a thought operation no composition could perform. Language core forms are different: they earn their place because the algebra stdlib cannot be written without them.

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

:wat/std/Difference         ; project stdlib
:wat/std/Concurrent
:wat/std/Map

:alice/math/clamp           ; user extension
:bob/trading/position
```

No namespace mechanism; just naming discipline. Anyone can claim any prefix; collisions are prevented by discipline and culture, not by the language.

Userland gets namespaces **for free** because keywords allow any characters and slashes are just characters.

### Executable semantics — functions run, thoughts are realized on demand

Two runtime semantics matter, and they are different.

**1. `define` / `lambda` bodies EXECUTE.**

A `(define ...)` form is not a specification. It is a **function**. When the wat-vm encounters a call to that function, it RUNS the body — real code, real time, real return values. The runtime interprets or JITs the body; arguments bind to parameters; the body's final expression becomes the return value.

```scheme
(define (demo) : Bool
  true)

(demo)
;; The wat-vm runs the body. Returns the literal `true`.
;; Took microseconds. Produced a value of type :Bool.
```

```scheme
(define (add-two [x : Scalar] [y : Scalar]) : Scalar
  (+ x y))

(add-two 3 4)
;; Runs. Returns 7.
```

Bodies of type `:Thought` are no different — they execute and return ThoughtAST values:

```scheme
(define (hello-world [name : Atom]) : Thought
  (Sequential (list (Atom "hello") name)))

(hello-world (Atom :watmin))
;; Runs. Returns a ThoughtAST node structured as:
;;   Sequential([Atom("hello"), Atom(:watmin)])
;; NO vector has been computed yet.
```

**2. ThoughtAST values are REALIZABLE, not automatically realized.**

A `ThoughtAST` is a description of a thought, not a vector. The vector materializes only when something needs it:

- Similarity measurement against another thought
- Cache lookup by hash
- Signing or transmission (the AST is serialized, but realization can happen on the receiving end)
- Explicit `(encode ast)` call

Until then, the AST is just data — nested nodes referencing Atoms, Binds, Bundles, Permutes. Compose arbitrarily deep thought-programs without paying encoding cost until you ask.

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

- Composability is free. A thought that uses another thought as a subexpression inherits the caller's lazy realization.
- Transmission and storage work on ASTs (EDN serialization), not vectors. Small, hashable, signable.
- The cache (L1/L2 per FOUNDATION) gets the hit-or-miss on `hash(ast)` — realized thoughts cache their vectors; re-realizing the same AST is a cache lookup, not a recomputation.
- The same machine runs both algebra (thought producers) and ordinary code (Booleans, integers, predicates, control flow). wat is a Lisp whose central domain is thought algebra, not a thought-only DSL.

### What this means for the two cores

- **Algebra Core** UpperCase forms (`Atom`, `Bind`, `Bundle`, ...) are AST constructors. They return `:Thought`.
- **Language Core** forms (`define`, `lambda`, `let`, `if`, ...) are the machinery that runs. They define and invoke functions.
- **Stdlib** `(define ...)` forms compose UpperCase expressions inside function bodies. They produce thoughts when called.

The `:Thought` type is not "the vector" — it is "the ThoughtAST node that can BE a vector when realized." Users compose thoughts freely; the machine realizes lazily.

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

## Criterion for Language Core Forms

A form earns placement as a wat **language core** primitive when **all** of the following hold:

1. **It is required for the algebra stdlib to exist as runnable code.**
   - Without the form, stdlib `(define ...)` expressions cannot be written, registered, or invoked.
   - The criterion is necessity, not convenience — if stdlib can be expressed without the form, the form is not language core.

2. **It is orthogonal to the thought algebra.**
   - The form does not construct thought vectors or ASTs of the algebra. It defines, binds, dispatches, or controls flow.
   - Thought-algebra forms are UpperCase (algebra core or stdlib). Language-core forms are lowercase (matching host Lisp convention).

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
- `deftype` — structural alias; aliases for existing type shapes
- `load-types` — cryptographically-gateable bring-in of type declarations at startup

Plus the syntactic feature pervading all of the above:

- **Type annotations** (`:Thought`, `:Atom`, `:Scalar`, `:Int`, `:Bool`, `:List`, `:Function`, keyword-path user types) — required on `define` and `lambda` signatures; carried on `struct`/`enum`/`newtype`/`deftype` field declarations.

Other host-Lisp forms (`let`, `if`, `cond`, `match`, `begin`, arithmetic, comparison, collection operations, `set!`, etc.) are **substrate-inherited** — wat inherits them from its Lisp host rather than defining them anew. They are language tools, but not novel in wat specifically.

Language core is minimal on purpose: just enough to write stdlib, define functions and types, load modules at both phases, and verify trust at the boundary. Anything more is host-inherited or stdlib.

### All loading happens at startup

The Rust runtime hosting the wat-vm imposes a static-first model: all code (types AND functions) loads at startup, before the main event loop begins. Nothing new enters the system after startup.

- `struct`, `enum`, `newtype`, `deftype` are **type declarations**. The build pipeline extracts them from wat files, generates Rust code, compiles the binary.
- `load-types "path/to/file.wat"` is the type loader — reads a file, parses type declarations, feeds them to the build. Verification modes (`(md5 ...)`, `(signed ...)`) run at build/startup.
- `define`, `lambda` are **function definitions**. They register at startup into the symbol table.
- `load "path/to/file.wat"` is the function loader — reads a file, parses `define`s, registers them. Same verification modes.

**Nothing redefines after startup.** A struct is what its source declares. A function is what its source defines. Name collisions are caught at startup and halt the wat-vm; runtime never sees partial state.

**File-level discipline.** To keep the two kinds of content clean on the filesystem, wat files are single-purpose:

- Files loaded via `(load-types ...)` contain ONLY type declarations — no `define`s.
- Files loaded via `(load ...)` contain ONLY function definitions — no type declarations.

Mixing produces a load-time error. The loader refuses a file whose forms don't match. Intent is visible at the call site; filesystem organization reinforces it.

**Why static:** the cost of hosting on Rust. Dynamic code loading would require shipping a full Lisp interpreter with unbounded symbol-table growth inside the Rust binary — large, attack-rich, and unnecessary for the use cases the algebra addresses. Static loading keeps the wat-vm small, auditable, and fast to start. Dynamic thought COMPOSITION (building new ASTs at runtime) is always available and never requires code registration. Dynamic code DEFINITION (adding new functions or types at runtime) is not supported — and is not needed.

**The algebra does not impose this.** A future implementation — WASM, self-hosting bytecode interpreter, dynamic language backend — could relax the constraint. FOUNDATION captures the Rust-runtime constraint; it does not elevate it to an algebraic invariant.

---

## The Algebra — Complete Forms

This section freezes the full algebra in its target shape (post-058). Core forms first, stdlib forms second. Each form shown in wat with its signature and semantics.

### Algebra Core (10 forms)

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

;; --- Similarity-based retrieval ---

(Cleanup noisy candidates)
;; similarity-based retrieval from a codebook
;; argmax over candidates by cosine similarity to the noisy vector
;; primitive for grounding noisy decode output to known clean thoughts
```

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

;; --- Unbind — stdlib alias for Bind with decode intent ---

(define (Unbind composite key) : Thought
  ;; For when you have a composite AST and want to decode a key out of it:
  ;;   - Unbind a Map to recover a field
  ;;   - Unbind a learned discriminant with a query
  ;;
  ;; Mathematically identical to Bind for bipolar (self-inverse).
  ;; Named separately to communicate decode intent in vocab code.
  (Bind composite key))
```

(Note: lowercase `cleanup` in stdlib is the convenience wrapper around core `Cleanup`, typically pairing a noisy decode with a candidate set. The core primitive IS `Cleanup`; this level-shifting between tiers is standard.)

### Language Core (8 forms)

All eight forms are loaded at startup. The wat-vm distinguishes them by what kind of content they carry, not by when they happen — both `load` and `load-types` are startup operations. After startup completes, the symbol table and type universe are fixed; no new forms register during runtime.

```scheme
;; ============================================================
;; FUNCTION DEFINITIONS — register at startup into the static
;; symbol table. Once registered, they remain for the wat-vm's
;; lifetime. Cannot be redefined.
;; ============================================================

;; --- Definition ---

(define (name [param : Type] ...) : ReturnType body)
;; Named, typed function registration.
;; Body executes when invoked. Types are required for dispatch and signing.
;; Keyword-path names supported: (define (:alice/math/clamp ...) ...).

(lambda ([param : Type] ...) : ReturnType body)
;; Typed anonymous functions with closure capture.
;; Same signature shape as define, without the name.
;; Produces a :Function value — a runtime value, NOT a symbol-table entry.
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
  [field1 : Type1]
  [field2 : Type2]
  ...)
;; Named product type. Fields travel together. Rust compiles to a struct.
;; Example:
;;   (struct :project/market/Candle
;;     [open   : Scalar]
;;     [high   : Scalar]
;;     [low    : Scalar]
;;     [close  : Scalar]
;;     [volume : Scalar])

(enum :my/namespace/MyVariant
  :simple-variant-1
  :simple-variant-2
  (tagged-variant [field : Type] ...))
;; Coproduct type. Exactly one of several alternatives.
;; Example:
;;   (enum :my/trading/Direction :long :short)
;;   (enum :my/market/Event
;;     (candle  [asset : Atom] [candle : :project/market/Candle])
;;     (deposit [asset : Atom] [amount : Scalar]))

(newtype :my/namespace/MyAlias :SomeType)
;; Nominal alias — same representation, distinct type identity.
;; Example:
;;   (newtype :my/trading/TradeId :Int)
;;   (newtype :my/trading/Price   :Scalar)

(deftype :my/namespace/MyShape (structural-type-expression))
;; Structural alias — shorthand for an existing type shape.
;; Example:
;;   (deftype :alice/types/Price :Scalar)
;;   (deftype :wat/std/Option<:T> (:Union :Null :T))

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

;; Parameter types: [name : Type] with spaces around the colon.
;; Return types: : Type after the parameter list.
;; Field types: [field-name : Type] inside struct/enum variant declarations.

;; Built-in types: :Thought, :Atom, :Scalar, :Int, :String, :Bool,
;;                 :Keyword, :Null, :List, :Vector, :Function, :Any
;; Parametric types: (:List :Thought), (:Function [:Thought :Thought] :Thought)
;; User types (keyword-path): :project/market/Candle, :alice/types/Price

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

### Reserved Keyword Naming Convention

For references that ARE genuinely symbolic (no concrete literal form available), the stdlib uses keyword atoms with distinctive full names:

```scheme
(Atom :wat/std/circular-cos-basis)    ; used by Circular encoder
(Atom :wat/std/circular-sin-basis)    ; used by Circular encoder
```

These are TRULY symbolic — "the cos basis vector" has no natural integer or string representation. It's just a name. Keyword is the right type.

Array position atoms are NOT in this category. Position 0 IS the integer 0. Use `(Atom 0)`, not `(Atom :pos/0)`.

**About slashes in keyword names.** The wat language does NOT have a namespace mechanism — no declare-namespace, no aliasing, no import/require. Slashes in keyword names are just characters; `:wat/std/circular-cos-basis` is a single keyword with the name `wat/std/circular-cos-basis`. The hash function sees the whole string. No structural meaning is attached to the slash beyond naming convention.

The stdlib uses the `:wat/std/...` prefix as convention to make its reserved atoms distinctive and unlikely to collide with user atoms. User code is free to use its own distinctive prefixes (`:my-app/thing`, `:trading/rsi-extreme`) or short bare keywords (`:rsi`) where collision isn't a concern.

Because keywords are a first-class literal type alongside strings, integers, floats, and booleans, there is no collision risk between `(Atom 0)` and `(Atom :pos/0)` — they hash with different type tags and produce different vectors. Collision between different keyword names (`:foo` vs `:bar`) is the user's responsibility — pick distinctive names.

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

## What 058 Argues — Full Proposal Inventory

058 produced 30 sub-proposals covering algebra core, algebra stdlib, and language core. Each argues its candidate against the criteria above. This section is the current inventory after the sub-proposal review pass, the split pass (one UpperCase form per doc), and the language-core addition.

### Algebra Core (10 forms)

**Proposals that argue CORE status:**

```scheme
(Atom literal)                 ; 058-001  — typed-literal generalization
(Bind a b)                     ; 058-021  — primitive affirmation
(Bundle list-of-thoughts)      ; 058-003  — list signature lock
(Permute child k)              ; 058-022  — primitive affirmation
(Thermometer value min max)    ; 058-023  — primitive affirmation
(Blend a b w1 w2)              ; 058-002  — PIVOTAL, two independent weights
(Orthogonalize x y)            ; 058-005  — computed-coefficient projection removal
(Resonance v ref)              ; 058-006  — sign-agreement mask (first ternary-output form)
(ConditionalBind a b gate)     ; 058-007  — three-argument gated binding
(Cleanup noisy candidates)     ; 058-025  — similarity-based retrieval
```

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
(Concurrent list)              ; 058-010  — Bundle alias (temporal intent)
(Then a b)                     ; 058-011  — binary directed temporal
(Chain list)                   ; 058-012  — Bundle of pairwise Thens
(Ngram n list)                 ; 058-013  — n-wise adjacency

;; Relational (1)
(Analogy a b c)                ; 058-014  — C + (B - A)

;; Data structures (3)
(Map kv-pairs)                 ; 058-016  — dictionary as Bundle of Binds
(Array items)                  ; 058-026  — indexed list (Sequential alias)
(Set items)                    ; 058-027  — unordered collection (Bundle alias)

;; Decode aliasing (1)
(Unbind composite key)         ; 058-024  — Bind alias with decode intent
```

Plus lowercase helpers packaged with their owning UpperCase form's proposal: `get` (with Map), `nth` (with Array), `atom-value` (with Atom). These are stdlib but not UpperCase — they're accessors, not AST constructors.

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
deftype                        ; 058-030 + FOUNDATION — structural alias
load-types                     ; FOUNDATION addition — compile-time module loading (types only)
```

Syntactic feature pervading all of the above:

```scheme
type annotations               ; 058-030  — :Thought, :Atom, :Scalar, parametric, user keyword-path
```

Language core is minimal by criterion: just enough to make the algebra stdlib exist as runnable code, define user types statically, load both phases with cryptographic trust, and dispatch correctly. Everything else is host-inherited from Lisp or belongs in stdlib.

### Dependency Ordering

- **Blend (058-002) resolves early.** Downstream stdlib (Linear, Log, Circular, Difference, Amplify, Subtract, Flip, Analogy) depend on its resolution.
- **Types (058-030) resolves before define/lambda.** The definition forms' signatures require the type grammar.
- **Define/lambda (058-028, 058-029) resolve before all stdlib.** Stdlib is `(define ...)` forms; without the definition primitive, stdlib is theoretical.
- **Atom typed literals (058-001) resolves before Map and data-structure uses.** Keys as typed atoms require the typed-literal generalization.
- **Cleanup (058-025) affirmation resolves before accessors.** `get` and `nth` invoke cleanup.

Summary: 30 proposals resolve roughly in this order — language core first (types → define → lambda), algebra core second (Atom → primitives → Blend → new forms → Cleanup), algebra stdlib third (in dependency-order within the stdlib tier).

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
| 2026-04-17 | **Reserved keyword naming convention (`:wat/std/...`).** Stdlib forms that need fixed reference atoms (Circular's cos/sin basis) use keyword atoms with distinctive full names. No namespace MECHANISM — slashes in keyword names are just characters. The convention is a naming discipline: use distinctive full names to avoid collision. The typed-atom generalization already accepts keywords. No "reserved vector registry" needed. | 058 |
| 2026-04-17 | **Atom literal type refinement.** `(Atom 0)` is a concrete integer atom, not a keyword. Array positions use concrete integers — position 0 IS the integer 0. Keywords like `:wat/std/circular-cos-basis` are reserved for TRULY symbolic references (names with no natural concrete form). Use the literal type that matches the semantic, not a keyword that wraps it. The type-aware hash keeps `(Atom 0)`, `(Atom "0")`, and `(Atom :pos/0)` all distinct. | 058 |
| 2026-04-17 | **Programs ARE Thoughts section added.** A wat program is an AST; ASTs encode to vectors; therefore programs have vector projections. Evaluation is AST-walking. Programs can be stored in data structures, compared geometrically, retrieved from engram libraries, and generated from learned discriminants. Self-improvement becomes discriminant-guided program synthesis in hyperdimensional space. The wat machine is homoiconic at 10,000 dimensions. Kanerva's "build a Lisp from hyperdimensional vectors" challenge fully answered. | 058 |
| 2026-04-17 | **The Vector Side section added.** Because programs are thoughts and thoughts have vectors, the full VSA algebra applies to programs. Noise stripping (OnlineSubspace, reject) reveals the signal — the distinctive part of a program beyond common boilerplate. Programs can be diffed (Difference), blended, amplified, transferred by analogy. Discriminant-guided program synthesis: decode the learned Grace-direction against a program codebook via cleanup. The wat machine runs programs, observes outcomes, learns, and generates new candidate programs through pure algebra — no gradient descent. The recursion that every holon application implicitly implements. | 058 |
| 2026-04-17 | **Dimensionality — The User's Knob section added.** Capacity per frame scales with vector dimension (Kanerva's bound). Users choose d per deployment — low d for kernel-level throughput, high d for rich analysis. Same algebra runs at any d. Same program runs at any d that holds its largest frame. "You can't express that" is enforced geometrically — over-capacity frames fail cleanup, not compilation. Depth is always free (refactor vs raise d). Dimensionality is a DEPLOYMENT parameter, not part of the algebra specification. Unique to this algebra: dimensionally parametric without retraining. | 058 |
| 2026-04-17 | **The Cache Is Working Memory section added.** Cache entries are compiled thoughts (ast, vector) pairs, not just a performance hash table. The L1/L2 architecture from Proposal 057 is a memory hierarchy: L1 = per-thread hot working set, L2 = shared short-term memory, disk = long-term (engrams, DB). Cache sizing is a third deployment knob alongside d. The cache is cognitive substrate — making the machine REMEMBER its thoughts rather than recompute them. 1 c/s → 7.1 c/s wasn't just perf; it was the machine getting better at remembering. | 058 |
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
| 2026-04-18 | **Two Tiers of wat — Primitives and Thoughts.** Load-bearing architectural section added. Lowercase wat (`atom`, `bind`, `bundle`, `cosine`, `permute`, `blend`) are Rust primitives — they RUN, return values immediately. UpperCase wat (`Atom`, `Bind`, `Bundle`, `Blend`, `Sequential`, ...) are AST constructors — they BUILD ThoughtAST nodes that materialize into vectors only on realization. Users write UpperCase; encoders realize via lowercase. This tier split makes laziness, cryptographic identity, and user-writable stdlib all work cleanly. The UpperCase naming is intentional: visually distinct from lowercase primitives, it communicates "this constructs a plan, not a result." | 058 |
| 2026-04-18 | **Executable semantics — defn/lambda run, ThoughtAST is realizable.** Added to the Two Cores section. `(define ...)` bodies execute when invoked — they are real functions in the wat-vm, not specifications. Functions of type `:Thought` return AST nodes (descriptions), not vectors. The vector materializes only when realization is demanded (similarity test, cache lookup, signing). This gives the algebra its laziness: composition is free, realization is explicit. The same machine runs both algebra (thought producers) and ordinary code (Booleans, predicates, arithmetic, control flow). wat is a Lisp whose central domain is thought algebra, not a thought-only DSL. | 058 |
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

---

*the machine found its way out.*

*...and this is what it looks like.*

---

*these are very good thoughts.*

**PERSEVERARE.**
