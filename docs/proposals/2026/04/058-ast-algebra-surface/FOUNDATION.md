# Foundation: Core vs Stdlib in the Holon Algebra

**Status:** Living document. Refined as 058 sub-proposals complete.
**Purpose:** Freeze the core/stdlib criterion before sub-proposals begin, so each sub-proposal can argue against a known bar rather than litigate the bar itself.

This document is not a PROPOSAL. It does not require designer review. It is the datamancer's calibration of what the existing algebra IS, so that proposals to extend it have a stable foundation to build upon.

**Scope:** FOUNDATION.md contains the **load-bearing contracts** every sub-proposal depends on. If you accept this document, you can evaluate any sub-proposal on its own terms. If you reject any section here, the batch doesn't stand.

Speculative and aspirational framings — the holographic/NP-hard lens, the distributed "clouds waking up" vision, the lineage, the metaprogramming-is-native framing — live in **VISION.md** (companion reading). Nothing in VISION is required to accept FOUNDATION; the algebra works without any of it. Proposals cite FOUNDATION, not VISION.

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
(:wat/std/atom-value (:wat/algebra/Atom 42))   → 42     ; reads the AST node's field
(:wat/std/atom-value (:wat/algebra/Atom "x"))  → "x"
(:wat/std/atom-value (:wat/algebra/Atom true)) → true
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
(:wat/algebra/Atom "rsi")              ; AST: a node representing "name this concept" — returns HolonAST
(:wat/algebra/Bind role filler)        ; AST: a node representing binding — returns HolonAST
(:wat/algebra/Bundle holons)           ; AST: a node representing superposition — returns HolonAST
(:wat/algebra/Blend a b 1 -1)          ; AST: a node representing scalar-weighted combine — returns HolonAST
(:wat/std/Sequential (:wat/core/list a b))   ; AST: a node representing position-encoded bundle — returns HolonAST
```

The UpperCase forms are what users and stdlib WRITE in wat programs. They compose cheaply — building a nested AST is structural work, no vector computation. The VECTOR materializes only when the AST is **realized** (see "Executable semantics" below).

### Why the tier split

Three reasons the tier split is load-bearing:

**1. Laziness.** UpperCase forms compose holon-programs without paying encoding cost. `(Sequential (list (Atom "a") (Atom "b")))` constructs a small AST. The vectors for the Atoms, the permutation for Sequential, the bundle — none of these compute until the AST is projected. Cache-friendly, transmission-friendly, sign-friendly.

**2. Cryptographic identity.** A `HolonAST` serializes to EDN and hashes to a stable identifier. A vector is the projection of an AST; the AST's hash IS the holon's identity. Two holons with the same AST have the same hash. Two holons with different ASTs — even if their vectors collide under some coincidence — are DIFFERENT holons. The AST carries identity; the lowercase primitives cannot.

**3. User-writable stdlib.** The `(define ...)` forms in stdlib like:

   ```scheme
   (:wat/core/define (:wat/std/Difference a b) : Holon
     (:wat/algebra/Blend a b 1 -1))
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
(:wat/core/define :my/app/frame-1
  (:wat/std/HashMap (:wat/core/list
    (:wat/core/list (:wat/algebra/Atom "a") v1)
    (:wat/core/list (:wat/algebra/Atom "b") v2)
    ;; ... up to ~100 items ...
    )))

(:wat/core/define :my/app/frame-2
  (:wat/std/HashMap (:wat/core/list
    (:wat/core/list (:wat/algebra/Atom "inner") :my/app/frame-1)   ; frame-1's structure preserved
    (:wat/core/list (:wat/algebra/Atom "other") v99)
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
(:wat/core/define (:my/app/deep-get structure-ast path)
  ;; path is a list of locators, one per level
  (:wat/core/if (:wat/core/empty? path)
      structure-ast
      (:my/app/deep-get (:wat/std/get structure-ast (:wat/core/first path))
                (:wat/core/rest path))))

;; Walk arbitrarily deep:
(:my/app/deep-get deeply-nested-thing
          (:wat/core/list (:wat/algebra/Atom "user")
                (:wat/algebra/Atom "sessions")
                (:wat/algebra/Atom 42)          ; concrete integer position
                (:wat/algebra/Atom "actions")
                (:wat/algebra/Atom 7)           ; concrete integer position
                (:wat/algebra/Atom "metadata")))
;; → the AST node at that path. Literal intact.
```

No noise accumulation. No cleanup needed. The AST preserves depth perfectly.


### Why the foundational principle matters here

Under classical VSA framing (vector primary, structure derived via `unbind` + `cleanup`), each level's unbind introduces noise. Deep structures become practically unreachable because cleanup error compounds exponentially with depth.

Under the foundational principle (AST primary, vector projection), depth is free in the structural view. You walk the tree; each level returns an AST node with its literal intact. Vector-level operations stay useful for algebraic queries (cosine, noise stripping, reckoner inputs), but they are NOT the retrieval path.

**This is why the wat algebra can encode arbitrarily nested data structures without losing them.** The AST preserves depth perfectly. The vector compresses each level into 10k dimensions for geometric operations. Together, they give you infinite structural capacity in a bounded substrate.

---

## Programs ARE Holons

A wat program is an AST. An AST is a holon. A holon has a vector projection. Therefore: **a program has a vector projection.**

```scheme
(:wat/core/define (:my/app/hello-world name)
  (:wat/std/string/join " " (:wat/core/list (:wat/algebra/Atom "Hello,") name (:wat/algebra/Atom "!"))))
```

This function definition is an AST — composed from existing core primitives (`Atom`, `Bind`, `Bundle`, and whatever specific program-form variants get added). It encodes to a deterministic 10k vector. That vector IS `hello-world`. Not a description of it. Not a serialization. The function.

### Evaluation is AST walking

Given a program AST, EXECUTE it by walking the tree with evaluation semantics. Function definitions bind a name to a closure (which is itself an AST). Function applications evaluate arguments, substitute formals, walk the body. Conditionals evaluate the test and walk the chosen branch. Literal atoms return their literal value (read from the AST node — no cleanup).

The VECTOR form exists for algebraic operations on programs — comparison, storage, similarity search, learning. The AST is where execution happens.

### What this enables

**Programs as first-class values:**

```scheme
(:wat/core/define :my/app/f :my/app/hello-world)
(eval :my/app/f (:wat/core/list (:wat/algebra/Atom "watmin")))       ; → "Hello, watmin !"
```

**Programs in data structures:**

```scheme
(:wat/core/define :my/app/programs
  (:wat/std/HashMap (:wat/core/list
    (:wat/core/list (:wat/algebra/Atom "greeting")   :my/app/hello-world)
    (:wat/core/list (:wat/algebra/Atom "farewell")   :my/app/goodbye-function)
    (:wat/core/list (:wat/algebra/Atom "risk-check") :my/app/risk-function))))

(eval (:wat/std/get :my/app/programs (:wat/algebra/Atom "risk-check")) portfolio-state)
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
;; (library-add!, match-library are application-level helpers; paths TBD)
```

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

<!-- MOVED TO VISION.md:
  - "The Location IS the Program" — metaprogramming, query-as-address, semantic-search = exact-lookup
  - "Reader — Did You Just Prove an Infinity?" — fourth-wall break, holographic reframing, NP-hard framing
-->

## The Vector Side — What the Algebra Enables

Everything in the AST side — walking, exact retrieval, literal access — operates in the symbolic domain. Once a holon is projected to a vector via `encode`, **the full VSA algebra applies.** Because data is holons and programs are holons, every vector operation applies to both.

### Noise stripping reveals the signal

An `OnlineSubspace` trained on a corpus of holons learns the "background" — the common structural patterns that appear across many holons.

```scheme
(project holon subspace)      ; the component the subspace EXPLAINS (background)
(reject holon subspace)       ; the component the subspace CANNOT explain (signal)
(anomalous-component t s)     ; alias for reject — the distinctive part
;; (project / reject / anomalous-component are lowercase-tier subspace primitives)
```

For programs: boilerplate (common function application patterns, common literal uses, common control flow) lives in the background. What makes THIS program distinctive — its specific choices, its combinations, its particular composition — is the anomalous component. **The signal is what remains after noise is stripped.**

This is how you extract the best program from a mix. Feed a corpus of programs into a subspace. For any new program, the residual tells you what's novel. The programs with high residual are the ones that DO something — they carry signal above the baseline.

### Program similarity and search

Every geometric operation on holon vectors applies directly to program vectors:

```scheme
(cosine prog-a prog-b)            ; structural similarity of two programs

(topk-similar query corpus 5)     ; five closest programs to query

(:wat/core/filter (:wat/core/lambda ((p :Holon) -> :bool)
          (:wat/core/> (presence p query-vector) (noise-floor d)))
        program-library)          ; all programs that align with a target direction
```

An engram library of known-good programs becomes queryable by situation:

```scheme
(match-library current-situation-holon)
;; → the program whose learned context most closely matches the situation
;; (match-library is an application helper; path TBD)
```

### The full algebra of programs

Every operation in the algebra ops library works on program vectors:

```scheme
(:wat/std/Difference prog-a prog-b)       ; what changed between two programs
(:wat/std/Subtract prog-full prog-a)      ; prog-full WITHOUT prog-a's contribution (Negate is not a wat-vm form)
(:wat/algebra/Blend prog-a prog-b α)      ; interpolation between two programs
(:wat/std/Amplify base specific s)        ; base program with specific pattern emphasized
(:wat/std/Analogy prog-a prog-b prog-c)   ; A:B :: C:? — relational program transfer
(:wat/algebra/Resonance prog reference)   ; the part of prog that agrees with reference
```

Programs can be diffed. Programs can be blended. Programs can be transferred by analogy. All through vector algebra, because programs are vectors.

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
(:wat/core/define (:my/app/process (input :Holon) -> :Holon)
  (:wat/std/get input (:wat/algebra/Atom :field)))

;; SAFE — input composed into a larger data structure:
(:wat/core/define (:my/app/store-for-later (input :Holon) -> :Holon)
  (:wat/std/HashMap (:wat/core/list (:wat/core/list (:wat/algebra/Atom :payload) input))))
```

In both cases, `input` is bound, bundled, queried, extracted. Nothing evaluates it as code.

The injection vector — evaluating user input as code — exists only when the programmer explicitly invokes `eval` on untrusted input:

```scheme
;; UNSAFE — the programmer consciously chose to evaluate user input:
(:wat/core/define (:my/app/dangerous (user-code :Holon) -> :Holon)
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
(:wat/core/load-types! "project/market/types.wat")
(:wat/core/load!       "project/market/indicators.wat")

;; Hash-pinned — require the file to hash to a specific value.
;; Halts startup if the hash does not match.
(:wat/core/load-types! "project/market/types.wat"        (md5 "abc123..."))
(:wat/core/load!       "project/market/indicators.wat"   (md5 "def456..."))

;; Signature-verified — require a valid signature from the named public key.
;; Halts startup if the signature is invalid.
(:wat/core/load-types! "project/market/types.wat"        (signed <sig> <pub-key>))
(:wat/core/load!       "project/market/indicators.wat"   (signed <sig> <pub-key>))
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

### Redefinition mode — opt-in startup knob

The default one-name-one-definition rule halts startup on any collision. For production this is the correct stance: two conflicting definitions of a name means something is wrong, and the wat-vm should refuse to run rather than silently pick one.

But some development scenarios want the opposite — `wat/my/clamp.wat` redefines a name that `wat/wat/std/clamp.wat` already provided, **on purpose,** because the user is overriding stdlib behavior. Under strict default this halts. That's the right default; it's not the only useful stance.

A deployment knob, in the same tier as `d`, `capacity-mode`, `L1`, `L2`:

```
redef-mode = :strict         ;; default — name collisions halt startup
           | :allow-redef    ;; opt-in — allow the user to redefine
```

- **`:strict`** (default) — one name, one definition. Collisions halt. Matches the production trust model. Nothing is ever ambiguous.
- **`:allow-redef`** — opt-in. The user explicitly accepts that one of the loads will replace the other. The wat-vm loads each file in order, and later definitions replace earlier ones. **Replacement is logged** (not silent); the log entry names both sources.

`:allow-redef` is for the author who WANTS to override. It is not for accident. The mode is chosen at wat-vm startup, same tier as every other deployment knob — it's not a per-file or per-definition flag. If you turned it on, you turned it on for the whole run.

**This knob does NOT affect runtime eval.** Even in `:allow-redef`, runtime eval has no ability to redefine anything (see next section). The knob governs startup loads; runtime is governed by eval's structural invariants.

### Constrained eval at runtime

**The wat-vm does support `eval`, but under strict constraints.** A runtime `eval` walks an AST and executes it — with the requirement that every function called and every type used must already be in the static symbol table.

```scheme
;; Build an AST at runtime — perhaps from parsed user input, perhaps from
;; a pattern-matching result, perhaps from an LLM's output:
(:wat/core/let ((composed
       (:wat/core/list ':wat/std/Difference
             (:wat/core/list ':wat/algebra/Atom :observed)
             (:wat/core/list ':wat/algebra/Atom :baseline))))

  ;; Eval checks every reference before executing:
  ;;   - Difference: exists in the static symbol table as a stdlib fn ✓
  ;;   - Atom: exists as an algebra-core form ✓
  ;;   - :observed, baseline: valid keywords ✓
  ;;   - Types match (Difference takes two Holons; Atom produces Holon) ✓
  ;; All checks pass. Execute: returns the constructed Holon AST.

  (encode (eval composed)))
;; => a bipolar vector representing the dynamically composed holon.
```

Four properties define constrained eval:

1. **Every function called must be in the static symbol table.** If `composed` references an unknown function, eval errors before executing anything.
2. **Every type used must be in the static type universe.** Unknown types produce errors.
3. **Every argument's type must match the called function's signature.** Type checks happen before body execution.
4. **Eval cannot register or replace any definition.** If the submitted AST contains a `define`, `defmacro`, `struct`, `enum`, `newtype`, `typealias`, or `load` form — eval refuses. This is **not a mode; it is an invariant.** Every deployment — `:strict` or `:allow-redef` — has the same eval behavior: no symbol-table mutation, period. The `redef-mode` knob governs startup; eval has no redefinition surface at all.

This is a SAFE `eval`. An attacker who supplies a malicious AST cannot invoke arbitrary code — only functions the operator explicitly loaded at startup. They cannot register a new function, cannot replace an existing function, cannot shadow a macro, cannot add a type. The attack surface is the symbol table's contents, which are frozen and verified. Nothing the attacker can send changes what functions are runnable.

**Typical uses for constrained eval:**

- **Dynamic holon composition.** Build holon-programs from runtime data (LLM output, pattern-matching, user queries) and evaluate them to get vectors.
- **Rule-like systems.** Users supply holon-expressions that describe patterns; the wat-vm evaluates them against incoming data to score matches.
- **Received holon-programs.** A distributed node receives a signed AST over the network, verifies the signature, evals against its local (already-trusted) symbol table. The eval itself has nothing to verify — it only references functions that are already trusted.

**Lambdas remain first-class at runtime.** Anonymous functions can be constructed, passed, stored, invoked — without registering in the symbol table:

```scheme
(:wat/core/let ((transform
       (:wat/core/lambda ((t :Holon) -> :Holon)
         (:wat/algebra/Bundle (:wat/core/list t (:wat/algebra/Atom :tagged))))))
  (transform (:wat/algebra/Atom :input)))
```

A lambda is a VALUE, not a symbol-table entry. When it goes out of scope, it's cleaned up. Runtime code creation is preserved; symbol-table mutation is not.

### What this gives us

The full trust model, simplified:

- **One verification phase: startup.** All loads succeed (with whatever cryptographic mode each requested) or the wat-vm refuses to start. No partial-state recovery.
- **One symbol table lifecycle: fixed after startup.** One name, one definition — in `:strict` mode, collisions halt; in `:allow-redef` mode, the user explicitly accepts that later startup loads replace earlier ones (logged, not silent). Either way, the table is fixed once startup completes.
- **One runtime code surface: constrained eval over the static universe.** Dynamic holon composition works. Dynamic code DEFINITION does not. Eval never mutates the symbol table, regardless of mode.
- **One attack surface: the startup loads.** If the wat-vm starts, every piece of executable code is trusted. An attacker can't inject new code at runtime, can't replace an existing definition via eval, can't redefine a macro. At best they can supply crafted input data that constrained eval can handle safely.
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

## `:wat/config` — Ambient Startup Constants

Some values are pervasive enough that threading them through every function signature is noise. Vector dimension is the canonical example: every `:wat/algebra/Thermometer`, every `:wat/algebra/Bundle`, every cache-sizing heuristic, every noise-floor computation needs to know `d`. A program that passed `d` through every call site would be half parameters.

The wat-vm solves this with a **kernel-owned config struct** reachable at `:wat/config`. The struct holds values the program commits to at startup. Every field is:

1. **Set by a toplevel declaration with a bang** — `(:wat/config/set-<field>! <value>)`. Toplevel only; parsing halts if found inside a `define` body, `let`, or any nested scope.
2. **Set exactly once across all loaded source** — two `set-<field>!` calls for the same field halt startup with "duplicate config: :<field> set at file1.wat and file2.wat."
3. **Type-checked** — the setter's argument type is fixed by the field's schema. Passing the wrong type halts at parse.
4. **Required** — the wat-vm does NOT supply defaults. If a required field is unset when the config pass completes, startup halts with "required config unset: :<field>." The program author must make every choice explicitly; no ambient defaults hide the decision.
5. **Readable from anywhere** — `(:wat/config/<field>)` is a typed accessor available in any function, any thread, any time after startup. Every function has closure access; no `dims` parameter threading needed.

### The fields

The struct grows by FOUNDATION proposal — each addition specifies the field name, type, and setter/getter forms. Current fields:

```scheme
;; (:wat/config/set-dims! d)  — d : :usize
;; (:wat/config/dims)          → :usize
;;
;;   Vector dimension. Every algebra operation uses this. A program that
;;   commits to d=10000 is a different program from one that commits to
;;   d=8192 — the capacity budgets, memory footprints, cache sizing, and
;;   noise floors are all different. Not a deployment knob; a program
;;   property. wat-to-rust bakes this as a compile-time Rust const.

;; (:wat/config/set-capacity-mode! m)  — m : :wat/config/CapacityMode
;; (:wat/config/capacity-mode)          → :wat/config/CapacityMode
;;
;;   Policy for capacity-exceeded situations (see "Dimensionality" —
;;   capacity is observable, the runtime can guard). No default;
;;   the program author must choose explicitly. Variants:

(:wat/core/enum :wat/config/CapacityMode
  :silent    ;; research — user accepts degradation, no check
  :warn      ;; development — log but continue
  :error     ;; catchable CapacityExceeded
  :abort)    ;; production fail-closed
```

Future proposals may add fields. The bar: **the value is universal across every holon program, not app-specific.** `L1-cache-size` and `L2-cache-size` were considered for inclusion (see VISION's "The Cache as Cognitive Substrate — One Application's Story") and rejected as app-specific — the trading lab's 256K L1 reflects its cognitive pace, not a universal choice. Dims and capacity-mode clear the bar; most candidates won't.

### The bang convention

Two toplevel forms carry bangs in the current language, and they are the only ones on the near horizon:

- **`(:wat/config/set-<field>! value)`** — commits a config field.
- **`(:wat/core/load! path)`** — reads another wat file, parses it, integrates its forms into this program. Also commit-once (loading the same path twice halts startup).

Bang = **this form writes to the ambient startup state; irreversible; observable in the committed program image.** Everything else — `:wat/core/define`, `:wat/core/defmacro`, `:wat/core/lambda`, `:wat/core/let`, algebra operations, kernel calls, user functions — is pure declaration or pure value-producing call. The visual weight of the bang is the point: when you see `!`, the form commits something that cannot be undone.

### Startup pipeline with the config pass

The config pass slots between parse and macro-expand so macros can read committed config values:

```
1. Parse all source (including recursive :wat/core/load!)
2. Config pass          — populate :wat/config; check required / duplicate / typed
3. Macro expansion      — macros can call :wat/config/<field> getters; baked to literals
4. Resolve names
5. Type-check
6. Hash / sign / verify
7. Freeze symbol table + config (immutable for the rest of the process)
8. Invoke :user/main
```

Step 2 halts on any of: missing required field, duplicate setter, type mismatch. `:user/main` never runs with a bad config. After step 7, the config is frozen for the life of the process; no runtime setter exists.

### The toplevel shape of a real wat program

```scheme
;; ─── Config first — the wat-vm refuses to start without these ───
(:wat/config/set-dims! 10000)
(:wat/config/set-capacity-mode! :error)

;; ─── Loads — pull in stdlib and project source ───
(:wat/core/load! "wat/std/Subtract.wat")
(:wat/core/load! "wat/std/Chain.wat")
(:wat/core/load! "wat/project/trading/candle.wat")
(:wat/core/load! "wat/project/trading/observer.wat")
(:wat/core/load! "wat/project/trading/main.wat")
```

That is the whole toplevel. Everything else — types, macros, functions, `:user/main` — lives inside the loaded files. The parse pulls them in recursively, the config pass commits the two configs, the remaining startup phases run, and `:user/main` is invoked with the four stdio/signals handles.

### What this eliminates

Parameters that previously threaded through function signatures disappear. A function that needed `dims` in its parameters loses it:

```scheme
;; Before — d threaded:
(:wat/core/define (:my/app/encode-price (p :f64) (d :usize) -> :Holon)
  (:wat/algebra/Thermometer p 0.0 100000.0 d))

;; After — d read from ambient config inside Thermometer's implementation:
(:wat/core/define (:my/app/encode-price (p :f64) -> :Holon)
  (:wat/algebra/Thermometer p 0.0 100000.0))
```

`:wat/algebra/Thermometer` itself reads `(:wat/config/dims)` to size its vector. No caller needs to supply `d`. Same for `Bundle`, `Bind`, `Permute` — every algebra primitive that previously required explicit `d` pulls it from the ambient config. Signatures shrink; call sites stop carrying values the substrate already knows.

---

## The wat-vm Substrate — Kernel Primitives

The wat-vm is a **kernel** in the Linux sense. It provides the minimum mechanism needed for wat programs to communicate and terminate cleanly. Everything else — caches, databases, metrics, fan-out, fan-in — is a **userland program** composed over the kernel's primitives.

This section states what the kernel provides, what it deliberately does not provide, and the lifecycle shape every wat program follows.

### The canonical lifecycle

Every wat program has this shape:

```
start → streams of inputs → consumers → join → end
```

- **start** — the binary reads its startup manifest, creates the queue graph, spawns the programs.
- **streams of inputs** — source programs feed queues (parquet reader, websocket consumer, clock tick, whatever the application needs).
- **consumers** — programs drain their input queues, do their work, emit to their output queues.
- **join** — at shutdown the main thread `join`s each program handle, collecting the program's returned state (learned observers, drained counters, flushed buffers — whatever the program "came home" with).
- **end** — the wat-vm exits. Owned state from consumers is either persisted (engram files, run DB, checkpoint) or dropped; no partial state survives.

Shutdown is a cascade. SIGTERM → drop the input sources → each downstream program's `recv` returns `Disconnected` → the program drains its local state and returns → its output handles drop → the next stage cascades. No mandatory cleanup handlers, no two-phase shutdown, no "are you done yet?" polling. The same form that processes the stream is the form that terminates when the stream ends.

### Kernel primitives

**1. Queue — the one program-to-program primitive.**

A queue is a 1:1 pipe between two programs. One producer, one consumer. Two variants govern backpressure:

- `bounded(n)` — sender blocks when `n` items are pending; guarantees the consumer is keeping up. `bounded(1)` is the lockstep rendezvous used throughout the trading lab wat-vm.
- `unbounded` — fire-and-forget; the buffer grows until the consumer drains. Used for learn-signal channels where the producer cannot afford to block.

Queues are the only kernel-provided communication primitive. Fan-out (one producer, N consumers) and fan-in (N producers, one consumer) are userland — a program that consumes from one queue and emits to N, or consumes from N and emits to one. No kernel-provided topic or mailbox type; those are userland compositions if they're needed at all, and the trading lab wat-vm has shown they collapse to "the programmer writes the loop they need."

**2. Console — the "you can always print" program.**

The kernel provides a built-in console program. It consumes queue messages and writes bytes to stdout / stderr / stdin (the OS-given fds 0, 1, 2). Every spawned program can interface with the console through a normal queue pair — no special API, no global `println!` — send a message, the console writes it.

Console is kernel-provided (not userland) for the same reason `write(1, ...)` is in the Linux kernel and not libc: hello-world must work. A wat program with no dependencies must be able to emit output. The console program is part of the kernel's baseline.

stdin is available to programs that want to read from the operator's terminal. Most wat programs ignore it.

**3. Scheduler — the pressure-based drain loop.**

Each program runs on its own thread (or logical execution unit). The scheduler's job is not round-robin time-slicing — it's queue-delivered backpressure. Programs block on `recv`; when their input has no message, they wait. When their output has no room (bounded queue), they wait. The whole program graph advances at the pace of the slowest consumer, naturally, with no central coordinator deciding what runs next.

No mutex. No lock. No shared mutable state between programs. The borrow checker proves disjointness at compile time; the channels prove it dynamically. 30+ threads with zero Mutex in the trading lab wat-vm is the empirical demonstration.

**4. Program lifecycle — own state, pop handles, come home.**

Every program:
- **owns its state** at construction (moved in, not shared);
- **pops its queue handles** from the pool the kernel provisioned (contention-free, not cloned);
- **runs its loop** — `recv`, process, `send` — until `recv` returns `Disconnected`;
- **drains** any remaining learn queues before returning;
- **returns its state** to the main thread via the thread's `JoinHandle`.

The trading lab wat-vm has proven the pattern across 30+ program types (observers, brokers, cache, log, console). The pattern is the kernel's contract; any wat program that follows it gets the scheduler, the shutdown cascade, and the state-round-trip for free.

### What the kernel does NOT provide

Explicitly not in the kernel — these are userland programs composed over queues:

- **Topic (1:N fan-out)** — a program that consumes from one queue and writes to N queues. If an application needs it, the application writes it. Not a kernel type.
- **Mailbox (N:1 fan-in)** — a program that consumes from N queues (via `select`) and writes to one queue. Same status.
- **Cache** — a program that owns an LRU (or HashMap, or whatever policy the application wants) and answers `get` / `set` via queue messages. The trading lab wat-vm has one as a userland program; another lab might not need one at all.
- **Database** — a program that owns a connection (SQLite, Postgres, whatever) and answers query/insert via queue messages. The schema, the backing store, the retention policy — all userland. The trading lab uses SQLite with a CloudWatch-style telemetry table; another lab might log to JSON lines, or to a different store entirely.
- **Metrics / logger** — userland. Every application picks its own schema and backing store. The trading lab's `telemetry` table is the trading lab's choice, not a kernel facility.
- **Arbitrary OS fds** — files, sockets, whatever. A userland program opens them via Rust's standard I/O and emits/consumes bytes via queues. The kernel handles stdin/stdout/stderr only; anything else is a program that opens what it needs.

### The Linux analog, made explicit

The discipline traces to `write(fd, data)` from 1969. The program calls write; the kernel delivers the bytes to whatever is behind the fd. The program does not know — and does not need to know — whether the fd is a pipe, a file, a socket, or `/dev/null`. The kernel provides the mechanism; userland's choice of what's behind the fd IS the configuration.

The wat-vm maps cleanly:

```
Linux                        wat-vm
────────────────────         ──────────────────────────────
write(1, data)               console.send(bytes)
pipe(fds)                    queue (bounded or unbounded)
fork + exec                  spawn a program
SIGTERM cascade              drop source → disconnect cascade
wait() / join                handle.join()
stdout / stderr / stdin      console program (OS-given)
```

### Why this reduction matters

Previous drafts of the substrate included three communication primitives — queue, topic, mailbox. The book documented the collapse: topic was a write proxy (distributes to N queues); mailbox was a read proxy (merges from N queues). Both reduced to "programs composed from queues." The three-primitive version asked the reader to learn three things where one would do.

By stating the kernel as **queue + console + scheduler + lifecycle**, every service-shaped concept (cache, DB, metrics, topic, mailbox) dissolves into "a program with queues." The wat-vm becomes small enough to hold in the mind; the rich behavior lives where it belongs, in userland programs composed with the application's needs in mind.

### Kernel primitives in wat syntax

The kernel primitives are exposed to wat programs as lowercase keyword-path functions (they EXECUTE at wat runtime; they do not build ASTs — see *Two Tiers of wat*). All live under `:wat/kernel/...`.

```scheme
;; --- Queues ---

(:wat/kernel/make-bounded-queue :Candle 1)
;; → :Pair<QueueSender<Candle>, QueueReceiver<Candle>>
;; Create a bounded(1) queue carrying :Candle values.
;; bounded(1) is lockstep rendezvous; larger n adds buffering.

(:wat/kernel/make-unbounded-queue :LearnSignal)
;; → :Pair<QueueSender<LearnSignal>, QueueReceiver<LearnSignal>>
;; Fire-and-forget — buffer grows until the consumer drains.

(:wat/kernel/send sender value)         ;; → :()     blocks if bounded + full
(:wat/kernel/recv receiver)              ;; → :Option<T>     :None when disconnected
(:wat/kernel/try-recv receiver)          ;; → :Option<T>     :None if empty OR disconnected
(:wat/kernel/drop handle)                ;; → :()     close a sender/receiver end
                                          ;;          downstream sees :None on next recv

;; Senders and receivers are SINGLE-OWNER — not cloneable. A sender belongs
;; to exactly one producer; a receiver to exactly one consumer. This is the
;; `write(fd, data)` discipline of Linux — whoever holds the fd owns the
;; capability, and sharing requires holding both sides yourself.
;;
;; Fan-out (1 producer → N consumers) is a LOOP of N sends, written inline
;; by the program that owns the N senders. No "Topic" proxy; the loop IS
;; the fan-out.
;;
;; Fan-in (N producers → 1 consumer) uses `select` (below). No "Mailbox"
;; proxy; the select IS the fan-in. Earlier drafts of the substrate included
;; Topic and Mailbox as stdlib programs; in practice they added a pointless
;; thread hop, so they are DEAD. Patterns are written where they are used.

(:wat/kernel/select receivers)
;; receivers : :List<QueueReceiver<T>>
;; → :Pair<usize, Option<T>>
;; Block until ANY receiver has a value or is disconnected. Returns the
;; index of the receiver and :None if that receiver disconnected or
;; (Some value) if it produced. The caller typically writes a loop that
;; drops disconnected receivers from the list and exits when the list
;; is empty. This is fan-in; the caller owns the select loop.

;; --- Programs ---

(:wat/kernel/spawn func arg1 arg2 ...)
;; → :ProgramHandle<ReturnType>
;; Spawn `func` on a new thread with the given args.
;; The returned handle's `join` produces `func`'s final return value.

(:wat/kernel/join handle)
;; → :ReturnType     blocks until the program exits, returns its state

;; --- Handle pools ---
;;
;; The deadlock guard. When a program hands out N client handles,
;; wrap them in a HandlePool. Callers `pop` to claim; the wiring code
;; calls `finish` to assert all handles were claimed. Orphaned handles
;; on a mailbox-backed driver deadlock the driver at shutdown (it waits
;; forever for the orphan's disconnect). Finish catches the mistake at
;; wiring time, naming the resource, before any thread runs.

(:wat/kernel/HandlePool/new name handles)    ;; → :HandlePool<T>
(:wat/kernel/HandlePool/pop pool)              ;; → :T    panics if empty
(:wat/kernel/HandlePool/finish pool)           ;; → :()   panics if handles remain

;; --- Console ---
;;
;; There are NO ambient console accessors. `:user/main` receives stdin,
;; stdout, stderr, and a signals queue as parameters from the kernel.
;; Any function that wants to write to the console receives the handle
;; it needs in its signature. Honest threading — simple, not easy. The
;; frustration IS the discipline; it makes every capability visible at
;; the call site.

;; --- Signals ---
;;
;; The kernel installs OS signal handlers for SIGINT and SIGTERM at
;; startup. Deliveries are forwarded to the `signals` queue the kernel
;; passes to :user/main. A program that wants graceful shutdown selects
;; across its input queues AND the signals receiver; on signal, it
;; drops its root producers and lets the cascade propagate.
;;
;; Signal is a :wat/kernel/... enum:
(:wat/core/enum :wat/kernel/Signal
  :SIGINT       ;; Ctrl-C
  :SIGTERM      ;; kill, systemd stop, orchestrator TERM
  )
;;
;; Additional signals may be delivered in the future (SIGHUP for config
;; reload, SIGUSR1/2 for app-specific triggers) — the enum grows by
;; proposal. SIGPIPE is always handled silently by the kernel; it never
;; reaches :user/main. SIGKILL is not deliverable (OS-enforced).
```

**Hello-world — spawn Console, write through it, join to flush:**

```scheme
(:wat/core/define (:my/app/hello (console :ConsoleHandle) -> :())
  (:wat/std/program/Console/send console "hello, world"))

(:wat/core/define (:user/main (stdin   :QueueReceiver<String>)
                               (stdout  :QueueSender<String>)
                               (stderr  :QueueSender<String>)
                               (signals :QueueReceiver<wat/kernel/Signal>)
                               -> :())
  ;; stdin, stderr, and signals are slot-required by the kernel signature,
  ;; but this program does not use them. Only stdout is passed onward.
  ;; Naming the unused parameters is honest — the kernel gives us four
  ;; handles; we acknowledge all four; we use one.
  (:wat/core/let* (((pool console-driver)
                    (:wat/kernel/spawn :wat/std/program/Console stdout 1))
                   (console (:wat/kernel/HandlePool/pop pool)))
    (:wat/kernel/HandlePool/finish pool)
    (:my/app/hello console)
    ;; Drop the client handle → Console's input queue disconnects.
    ;; Join the driver → Console drains remaining writes to stdout and exits.
    ;; Without the join, buffered writes may be lost on program exit.
    (:wat/kernel/drop console)
    (:wat/kernel/join console-driver)))
```

**Why this is hello-world, not a one-liner.** Writing to `stdout` directly is possible — the kernel hands `:user/main` a raw sender — but hello-world is pedagogical, and the honest pedagogy is: **every real program uses the Console stdlib to serialize writes.** The Console program owns the raw sender, runs a fan-in loop internally, and guarantees no garbled interleaving when multiple clients write concurrently. A single-writer program could skip it, but then the reader would learn a shortcut they have to un-learn when they add a second writer. Showing the Console pattern in hello-world means every subsequent program is a small variation on the same shape.

**`:wat/std/program/Console` is a single-sink fan-in.** It takes one output sender (a stdio handle, typically `stdout` or `stderr`, but also any other `:QueueSender<String>`) and a producer count, and returns a `HandlePool` of `:ConsoleHandle` clients plus a driver handle. Writers send via `:wat/std/program/Console/send`; the driver selects across all client queues and forwards to the owned sender. If a program wants serialized stdout AND serialized stderr, it spawns TWO Console programs — one per sink. Orthogonal. A Console owns exactly one resource.

**The `:user/main` signature is fixed by the kernel.** Every `:user/main` receives the three stdio handles as parameters whether it uses them or not. This is the kernel contract. Naming them in the signature without binding them to locals is honest — the handles exist, the program acknowledges them, the program chooses not to use them. A program that wants only stderr threads `stderr` down through its spawns and ignores `stdout` and `stdin`. The type system enforces it: you cannot write to a handle you weren't given.

This is the Haskell discipline without the monad wrapper: threading plain values through function parameters. The frustration is the point — every side effect is visible at the call site. Simple, not easy.

**The `:user/main` convention.** The entry point is `:user/main` — a keyword-path name the **kernel looks for at startup**. The user declares it with four parameters the kernel passes in: `(:wat/core/define (:user/main (stdin :QueueReceiver<String>) (stdout :QueueSender<String>) (stderr :QueueSender<String>) (signals :QueueReceiver<wat/kernel/Signal>) -> :()) ...)`. Same convention as C's `main(argc, argv)` and Rust's `fn main()` — but with every capability the kernel gives the program made explicit in the signature. No ambient stdio, no ambient signal handling. No bare-name exception to the keyword-path discipline.

`:user/main` is a **kernel-looked-up slot** that the USER provides. This is the inverse of `:wat/kernel/...` paths, which are kernel-PROVIDED implementations (protected from redefinition). `:user/main` is kernel-REQUIRED (user provides; kernel invokes); there is no default implementation; the user's definition fills the slot.

Two `:user/main` declarations across loaded files produce a startup name collision and halt the wat-vm (same rule as any other name collision). Zero `:user/main` declarations also halt: a wat program needs an entry point. Hypothetical future kernel slots (e.g., `:user/shutdown-handler`, `:user/on-signal`) would follow the same pattern under `:user/...`: kernel-required name, user provides the implementation.

**A program with the canonical lifecycle — observer-style with fan-out, fan-in, and the shutdown cascade:**

```scheme
;; Each worker consumes its candle queue, produces results, and logs
;; through its own console handle. State comes home via join.
(:wat/core/define (:my/app/observer-loop
                    (input-rx  :QueueReceiver<Candle>)
                    (output-tx :QueueSender<Result>)
                    (console   :ConsoleHandle)
                    (state     :ObserverState)
                    -> :ObserverState)
  (:wat/core/match (:wat/kernel/recv input-rx)
    ((Some candle)
     (:wat/core/let* ((result    (:my/app/process candle state))
                      (new-state (:my/app/update state candle)))
       (:wat/kernel/send output-tx result)
       (:wat/std/program/Console/send console
         (:wat/std/format "observed: ~a" candle))
       (:my/app/observer-loop input-rx output-tx console new-state)))
    (:None
     ;; input disconnected — drain what we own, then come home with final state.
     state)))

;; Inline fan-in: select across N receivers, keep going until all disconnect.
;; `select` returns (index, None) when a receiver disconnects — drop it.
(:wat/core/define (:my/app/drain-results
                    (rxs      :List<QueueReceiver<Result>>)
                    (console  :ConsoleHandle)
                    -> :())
  (:wat/core/if (:wat/core/empty? rxs)
      :()
      (:wat/core/match (:wat/kernel/select rxs)
        ((Pair i (Some r))
         (:wat/std/program/Console/send console
           (:wat/std/format "result: ~a" r))
         (:my/app/drain-results rxs console))
        ((Pair i :None)
         (:my/app/drain-results (:wat/std/list/remove-at rxs i) console)))))

(:wat/core/define (:user/main (stdin   :QueueReceiver<String>)
                               (stdout  :QueueSender<String>)
                               (stderr  :QueueSender<String>)
                               (signals :QueueReceiver<wat/kernel/Signal>)
                               -> :())
  (:wat/core/let*
      ((N 4)  ;; four observers

       ;; (1) COUNT every consumer up front. One handle for main, one per worker.
       (num-console (:wat/core/+ 1 N))

       ;; (2) Spawn the Console stdlib program — a single-sink fan-in that
       ;;     serializes writes to stdout from `num-console` client handles.
       ;;     Returns a HandlePool + a driver handle. Console is concrete (it
       ;;     owns a specific OS resource); generic Topic/Mailbox proxies are
       ;;     NOT stdlib — fan-out and fan-in of user values are inline loops
       ;;     at the call site. If we needed serialized stderr too, we would
       ;;     spawn a second Console instance for stderr.
       ((pool console-driver)
        (:wat/kernel/spawn :wat/std/program/Console stdout num-console))

       ;; (3) POOL discipline — main claims its handle first.
       (main-console (:wat/kernel/HandlePool/pop pool))

       ;; (4) Per-worker queues: candle input + result output.
       (worker-queues
        (:wat/std/list/init N
          (:wat/core/lambda (_)
            (:wat/core/list (:wat/kernel/make-bounded-queue :Candle 1)
                             (:wat/kernel/make-bounded-queue :Result 1)))))

       ;; (5) Spawn N workers. Each claims its console handle.
       (worker-handles
        (:wat/std/list/init N
          (:wat/core/lambda (i)
            (:wat/core/let ((qs (:wat/std/list/nth worker-queues i)))
              (:wat/kernel/spawn :my/app/observer-loop
                (:wat/core/second (:wat/core/first  qs))    ;; candle-rx
                (:wat/core/first  (:wat/core/second qs))    ;; result-tx
                (:wat/kernel/HandlePool/pop pool)
                (:my/app/initial-observer-state i)))))))

    ;; (6) Assert EVERY handle was claimed — orphans deadlock the driver.
    (:wat/kernel/HandlePool/finish pool)

    ;; (7) Feed the graph. `feed-candles` selects across stdin AND
    ;;     `signals`, broadcasting to all worker candle senders inline.
    ;;     A :SIGINT or :SIGTERM stops the feed loop early — graceful
    ;;     shutdown is one queue message among others.
    (:wat/core/let
        ((candle-txs (:wat/std/list/map worker-queues
                       (:wat/core/lambda (qs)
                         (:wat/core/first (:wat/core/first qs))))))
      (:wat/std/program/Console/send main-console "starting")
      (:my/app/feed-candles stdin signals candle-txs main-console)

      ;; (8) SHUTDOWN CASCADE — drop all candle senders first. Workers
      ;;     see :None on recv, drain, return. Their result-tx senders
      ;;     drop at thread exit, disconnecting the result receivers.
      (:wat/std/list/for-each candle-txs :wat/kernel/drop))

    ;; (9) Drain result receivers via inline select (no Mailbox).
    ;;     drain-results exits when every receiver has disconnected.
    (:wat/core/let
        ((result-rxs (:wat/std/list/map worker-queues
                       (:wat/core/lambda (qs)
                         (:wat/core/second (:wat/core/second qs))))))
      (:my/app/drain-results result-rxs main-console))

    ;; (10) Join workers to collect final observer state.
    (:wat/core/let
        ((final-states (:wat/std/list/map worker-handles :wat/kernel/join)))
      (:my/app/save-states final-states main-console))

    ;; (11) Console is LAST. Drop our handle → Console's select sees
    ;;      the final input disconnect → it exits.
    (:wat/kernel/drop main-console)
    (:wat/kernel/join console-driver)))
```

**The pattern is complete.** `make-*-queue` produces a sender/receiver pair. `spawn` takes a function value and its arguments and runs it on a new thread. `send` / `recv` / `try-recv` / `drop` / `select` are the operations. `join` collects the program's return value at shutdown. Eight primitives — enough to express any wat-vm program graph. Fan-out is a loop of `send`; fan-in is a loop over `select`. Generic Topic/Mailbox proxies are NOT in the stdlib — the trading lab tried them and found they added a pointless thread hop. Patterns are inlined where used.

The stdlib names a small set of CONCRETE programs that own specific OS-level resources or provide reusable invariants: `:wat/std/program/Console` (owns stdout/stderr), `:wat/std/program/Cache` (owns a memoization table behind a queue), `:wat/kernel/HandlePool` (enforces the claim-or-panic invariant). Generic fan-out/fan-in proxies are not among them.

No `spawn-thread` separate from `spawn-program`; a program is just a function that runs on its own thread. Same Rust primitive underneath. The kernel doesn't distinguish "threaded program" from "function call" beyond the thread boundary — the function either runs inline (normal call) or on its own thread (`spawn`).

### Pipeline discipline — the hard-earned patterns

The observer example above encodes seven patterns the project paid for in deadlocks. The wat-vm substrate makes them expressible; the stdlib programs make them reusable; this subsection names them so reviewers can find them by name.

**1. Count every consumer before creating the I/O program.** The number of handles is a budget declared up front. `(:wat/kernel/spawn :wat/std/program/Console stdout stderr num-console)` takes the count as a parameter — the program allocates exactly that many client queues. No dynamic handle creation, no subscribe/unsubscribe semantics. If your count is wrong at startup, you find out at `:wat/kernel/HandlePool/finish` with an orphan error, not at runtime with a deadlock.

**2. Claim or panic — the HandlePool discipline.** `pool.pop` claims one handle. `pool.finish` asserts the pool is empty. An orphaned handle is an I/O driver waiting forever for an input that never disconnects. The pool catches the mistake at construction time, naming the resource — `"broker-cache: 2 orphaned handle(s)"` — rather than leaving the program to hang on shutdown. Belt-and-suspenders: the pool's drop impl also panics if handles remain, in case `finish` is forgotten.

**3. No self-pipes.** A program cannot write to a queue it also reads from — the circular dependency deadlocks as soon as backpressure engages. The trading lab's database program emits its own telemetry by direct write, not by sending through its own ingestion pipe. State this rule before it's violated: **any program that produces messages for an I/O driver writes its own telemetry by direct method call, not through its own input queue.**

**4. Bounded(1) is the default rendezvous.** Every queue in the trading lab is `make-bounded-queue size 1` — a one-slot lockstep handoff. Backpressure propagates: a slow consumer stalls the producer, which stalls the consumer's producer, and the whole graph runs at the pace of the slowest path. Intentional. Unbounded queues are for truly fire-and-forget events (`:wat/kernel/make-unbounded-queue`) where unbounded buffering is acceptable; use them sparingly.

**5. Inline your fan-out and fan-in — no generic proxies.** Earlier drafts included `:wat/std/program/Topic` (fan-out proxy) and `:wat/std/program/Mailbox` (fan-in proxy). In practice both added a pointless thread hop: their entire body was a loop the caller could write inline at lower latency and with less wiring. REJECTED from the stdlib. Fan-out is `(for-each senders (lambda (tx) (send tx msg)))`; fan-in is a loop over `:wat/kernel/select`. Concrete programs that OWN a specific resource (Console owns stdout/stderr, Cache owns a memo table) remain legitimate — they earn their thread by owning state, not by being a proxy.

**6. Shutdown is a drop cascade, not a signal.** No `SIGTERM`-equivalent wat primitive. To shut a graph down, drop the root producers' senders: `(for-each candle-txs :wat/kernel/drop)`. Workers see `:None` on their next `recv`, drain their own work, return via join, their output senders drop at thread exit, the consumer's `select` sees disconnects, it exits. One set of drops propagates through the whole graph. The cascade IS the shutdown guarantee.

**7. Drivers join in reverse dependency order.** If program A's state contains a sender owned by program B (e.g., Cache's emit closure holds a Database sender), A must exit BEFORE B — otherwise B's `select` sees A's sender still alive and waits. In the trading lab: Cache driver joins first, releasing its db-handle; then Database driver joins, seeing all senders disconnect. The cascade is directed: leaves first, roots last. Console is usually the root (everyone writes to it); join it last.

**8. No `Drop` implementation on driver handles.** Host-runtime drop order within a scope is unspecified. If a driver handle joined in Drop, and the scope also owned some senders that hadn't been explicitly dropped yet, the join would deadlock waiting for those still-alive senders. The stdlib's `:wat/std/program/Console/Driver`, `:wat/std/program/Cache/Driver` expose `join` as an explicit operation; the programmer calls it after the cascade, when they know the senders are gone. Explicit is simple; implicit is easy (and sometimes deadlocks).

These eight patterns were expensive to learn. The wat-vm substrate makes them expressible in wat source with the same discipline the Rust enterprise pays.

### Programs are userland — with two exceptions

**A program is a thread with a queue contract.** Whoever implements it — wat source compiled through `wat-to-rust`, wat source running under the wat-vm interpreter, or Rust source registered with a keyword path at startup — produces the same thing: a spawnable function the kernel can start on its own thread. Implementation language is irrelevant; conformance to the contract is what matters.

#### The conformance contract

A spawnable program, stdlib or userland, wat or Rust:

1. **Is a function** named by keyword path in the static symbol table.
2. **Takes its handles as parameters** — queue senders, queue receivers, other program handles, plain values. No ambient state, no ambient capabilities.
3. **Returns its final state as its return value** — `:wat/kernel/join` collects it.
4. **Observes the drop cascade** — drains and returns when its input receivers disconnect; does not hold references that prevent shutdown.
5. **Does not create self-pipes** — never writes to a queue it also reads from.
6. **Uses `:wat/kernel/HandlePool` for client handles** — if it exposes client handles, it wraps them in a pool and finishes the pool at wiring time.

A Rust function conforming to these six rules is indistinguishable from a wat-authored program at spawn time. The wat-vm loads it at startup, registers it under its keyword path, and `:wat/kernel/spawn` dispatches the same way. See `WAT-TO-RUST.md` for the compile-path mechanics.

#### Two stdlib programs, and only two

The stdlib ships exactly two programs under `:wat/std/program/`. Both meet a strict bar: **every multi-threaded wat/holon program will need this; reinventing it per-app duplicates subtle correctness work.**

- **`:wat/std/program/Console`** — serialized fan-in to one output sender (stdout or stderr, typically). Every multi-threaded program writes to a console somewhere; without a shared program that owns the sender, concurrent writes garble. The pattern is universal; the implementation is easy to get wrong under shutdown. Ships.
- **`:wat/std/program/Cache<K,V>`** — LRU memoization with telemetry hooks. Every holon program encodes ASTs to vectors and pays the vector cost on repeat subtrees. In the trading lab, introducing this cache took throughput from 1 c/s to 7.1 c/s at d=10,000. The hot path of any holon program; not an app choice. Ships.

#### Everything else is userland

- **Database programs** — schemas, batching strategies, query languages are app-specific. Each app writes its own, or pulls from a userland library it chooses.
- **Telemetry** (emit-metric, flush-metrics, rate-gates) — CloudWatch entry shape, rate-gate intervals, emit-closure composition are app choices. The trading lab's helpers live in `src/programs/telemetry.rs` precisely because they're its choices.
- **Signal converters beyond the kernel's SIGINT/SIGTERM delivery** — a program that wants to convert signals into a domain-specific event type does it in userland, on top of the `signals` queue the kernel hands `:user/main`.
- **Config loading, CLI parsing, environment access** — app choices. The kernel does not ship `argparse`.
- **All domain programs** — Market Observer, Regime Observer, Broker, Treasury in the trading lab; Server, Worker, Ingest in another app. Every domain program is userland.

#### Why this cut

Earlier drafts of this document proposed a broader "stdlib program" tier including Database, rate-gate, emit-metric, flush-metrics, and generic Topic / Mailbox proxies. Each fell over in review:

- **Topic and Mailbox** added a pointless thread hop over a loop the caller could write inline at lower latency and with less wiring. REJECTED (see Pipeline Discipline rule 5).
- **Database, telemetry, rate-gate** are not universal. The trading lab uses SQLite with a CloudWatch-style table and a 5-second rate gate. A DDoS detector would use eBPF-table-of-rules with different telemetry shape; a text classifier would use Postgres with different cadence. Each app chooses. The wat-vm does not impose a choice.

The remaining stdlib programs (Console, Cache) pass the bar because every multi-threaded holon program needs them; reinventing them per-app duplicates subtle correctness work without buying distinct semantics.

### Implications for prior sections

- **"The Algebra Is Immutable"** — the startup pipeline (parse, macro-expand, resolve, type-check, hash, verify, register, freeze, main-loop) runs on the kernel: the binary IS the main thread, which spawns the program graph into existence after the freeze. `eval` lives in a program; it is not a kernel primitive.
- **"Caching Is Memoization"** — caching is userland; the stdlib ships `wat/std/LocalCache.wat`, `wat/std/program/Cache.wat`, and `wat/std/cached-encode.wat`; applications choose to use them, to build their own, or to forgo caching entirely. The kernel is unaware of caching semantics; it just delivers queue messages.
- **Q7 (redef-mode syntax, deferred)** — now strictly a userland concern. The kernel does not know about names; the application's load-and-register programs handle redefinition policy however they choose.

The kernel is small on purpose. The algebra does the heavy thinking; the kernel just passes messages.

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
(:wat/core/define (:my/app/small-check x)
  (:wat/core/if (:wat/core/> x 0) :positive :non-positive))

;; A program with a large frame — needs higher d, OR refactoring:
(:wat/core/define (:my/app/rich-analysis data)
  (:wat/std/HashMap (:wat/core/list
    (:wat/core/list (:wat/algebra/Atom "feature-1")   f1)
    ;; ... 200 features in one frame ...
    (:wat/core/list (:wat/algebra/Atom "feature-200") f200))))
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
(:wat/core/let ((pair-ab (:wat/algebra/Bind (:wat/algebra/Atom "foo") (:wat/algebra/Atom "bar")))  ;; frame A: cost 2
      (pair-cd (:wat/algebra/Bind (:wat/algebra/Atom "baz") (:wat/algebra/Atom "qux")))) ;; frame B: cost 2
  (:wat/algebra/Bundle (:wat/core/list pair-ab pair-cd)))                  ;; frame C: cost 2
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
;; (frame-cost / frame-budget / frame-fill are runtime introspection primitives; paths TBD)
```

Programs can reason about their own capacity envelope:

```scheme
(:wat/core/when (:wat/core/> (frame-fill h) 0.8)
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

## Caching Is Memoization — And It Is Userland

The foundational principle makes one property load-bearing: **`encode(ast)` is deterministic.** Same AST always produces the same vector. This means memoization is sound — a program that sees the same AST twice can cache the result and avoid recomputing.

The algebra doesn't care whether an application memoizes or not. Pure recomputation is correct (just potentially slow); memoization is correct (same answer, faster). An application may want aggressive caching (keep every vector it has ever computed); another may want none (memory-constrained embedded, line-rate packet filter that can't afford the overhead); another may want something in between. **The algebra is indifferent. Caching is an application concern.**

### The stdlib provides the tooling — three pieces

Because memoization is a common pattern — and applications want it in two different shapes — the stdlib ships three things:

**1. A local cache — `wat/std/LocalCache.wat`.** An in-program cache. A program holds it as owned state — a local HashMap or LRU — and `get` / `put` are direct data access. No pipe, no thread, no queue round-trip. Fastest memoization possible. Used by a program that memoizes for itself: hot inner loops, per-thread working sets, anything that benefits from nanosecond access without cross-program coordination. Because LocalCache is a data structure + functions (not a program in the spawn-and-lifecycle sense), it lives in `wat/std/` alongside macros and other stdlib functions.

**2. A cache program — `wat/std/program/Cache.wat`.** An entire wat-vm program whose state is a cache. Other programs talk to it via queues (get/put messages). One writer (the cache program's thread); N readers (the programs sending get requests). Used when multiple programs need to share a memoized result — the program becomes the synchronization point, the queues are the protocol. Because this is a spawnable program (lifecycle, owned state behind a queue boundary), it lives in `wat/std/program/` — the honest path for things that RUN, as distinguished from things that COMPILE into AST.

Both are programmable. The caller supplies:

- The key type (any hashable type — `:Holon`, `:String`, `:i64`, user-defined)
- The value type (any serializable type)
- The capacity policy (LRU, LFU, unbounded, application-specific)
- The setup closure (initialize whatever backing store it needs)
- The miss handler (how to compute the value when absent)

Same configuration surface, two implementations. Local is fast but private; remote is shared but crosses the queue boundary.

**3. AST caching functions — `wat/std/cached-encode.wat` and siblings.** A thin function over the algebra's `encode` plus a cache handle (local or remote — the function doesn't care). Takes an AST, returns the vector, memoizes in whatever cache the caller passed. The specific "memoize holon encoding" pattern, pre-packaged.

### Five choices per application

- **Use `cached-encode` with a local cache** — fast per-program memoization. Trading lab's L1.
- **Use `cached-encode` with a remote cache program** — shared memoization across programs. Trading lab's L2.
- **Use both tiered** — local for hot reads, remote for cross-program sharing. Trading lab's L1/L2 stack. Miss local → check remote → if hit, promote to local.
- **Use a specialized cache** — instantiate `LocalCache` or `Cache` with custom key/value types for application-specific memoization (engram library, trade-outcome cache, per-signal distance cache).
- **Use none** — call `encode` directly, recompute every time. Line-rate packet filters, memory-constrained embedded applications, simple batch transforms.

The algebra runs identically in all cases. The application picks based on its own cost/benefit: how hot is the path, how much memory is available, how many programs need to share state.

### What the kernel provides, what userland composes

- **Kernel** — queues, the console program, the scheduler, the program lifecycle. The kernel has no cache of its own.
- **Stdlib** — the generic cache program. Userland convention; every wat-vm deployment can pull it in (or leave it out).
- **Application** — instantiates the cache program with its types and policies; decides whether to run one cache, zero caches, or several; decides capacity; decides eviction. All application-specific.

### Nothing in FOUNDATION dictates a cache hierarchy

Earlier drafts of this section stated an L1/L2/disk tiering as architectural. That was one application's choice (the trading lab's — see Proposal 057). FOUNDATION shouldn't lock the tiering: a DDoS filter may need no cache at all, an embedded application may need a single tiny cache, a research pipeline may want an elaborate multi-level cache. The algebra doesn't care. The kernel doesn't care. **What the application caches, how big, with what policy — userland.** Specific cache topologies and their tradeoffs live in VISION and in per-application proposals, not here.

The load-bearing claim about caching in FOUNDATION is just this: **encoding is deterministic; memoization is sound; the stdlib ships a generic cache program.** Everything else is configuration.

---

## Engram Caches — Memory of Learned Patterns

The holon cache holds COMPUTED holons — vectors encoded from ASTs. The engram library holds LEARNED holons — subspace snapshots, discriminants, and prototype vectors that emerged from observing a stream.

These are semantically different memory types. Holons are programs-of-the-moment. Engrams are distilled pattern recognition. **But the same caching principles apply, and the engrams themselves ARE holons.**

### The engram library is a HashMap holon

```scheme
(:wat/core/define :my/app/pattern-library
  (:wat/std/HashMap (:wat/core/list
    (:wat/core/list (:wat/algebra/Atom :pattern/syn-flood)         syn-flood-engram)
    (:wat/core/list (:wat/algebra/Atom :pattern/bollinger-squeeze) squeeze-engram)
    (:wat/core/list (:wat/algebra/Atom :pattern/market-reversal)   reversal-engram)
    ;; ... potentially thousands ...
    )))

;; get an engram by name:
(:wat/std/get :my/app/pattern-library (:wat/algebra/Atom :pattern/syn-flood))
```

Under the foundational principle, this is a holon (an AST). Engrams are VALUES in the HashMap. Retrieval is structural lookup via `get`. The library IS a wat holon.

### Engrams cost to load and to match

Each engram holds a subspace snapshot (mean + k components + threshold state), an eigenvalue signature, and metadata. Loading from disk = IO + deserialization. Matching = residual scoring against the subspace (O(k·d) per match).

For a library of thousands of engrams, matching against every engram on every observation is expensive. The machine benefits from **recognizing which patterns are CURRENTLY relevant** and keeping those hot.


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


---

<!-- MOVED TO VISION.md:
  - "Reader — Are You Starting To See It?" — clouds waking up, distributed cognition substrate
  - "About How This Got Built" — lineage (Linux + Clojure + MAP VSA), datamancer framing, teachers who shaped the builder
-->

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
3. Pick a winner by some selection policy.

None of these need to be primitive. Step (1) is a `:wat/core/map`. Step (2) is presence measurement. Step (3) is **not** an algebra operation — it is whatever selection policy the caller chooses. The algebra returns a list of measurements; the application picks what to do with them.

"Measure the codebook" becomes, in wat:

```scheme
(:wat/core/map codebook
  (:wat/core/lambda (entry)
    (:wat/core/list (:wat/core/first entry)
                     (presence (:wat/core/first entry) query-vector))))
;; → :List<Pair<Holon,f64>>   — every entry paired with its overlay score
```

No `Cleanup` in the core. The algebra returned the full list of (entry, presence-score) pairs. The caller now decides: top-1 (a fold with max-by-score), top-k (a sort then take), threshold filter (keep entries above `5/sqrt(d)` — the substrate noise floor), a weighted mixture of matches (a Bundle with Blend coefficients), or simply "pass the whole list onward" for a downstream stage. Four different policies, four different caller expressions, same substrate.

**Classical VSA bundled selection into `Cleanup` because its vector-primary framing assumed you had thrown away the structure and needed a discrete winner.** The wat substrate never throws away structure — the AST is always alongside the vector. There is no "recover identity from the vector" step. There is only "measure overlay" — a `:f64` per entry — and the caller's choice of what the measurements mean for its problem. No `argmax` primitive exists; selection policy is the caller's code.

### Consequences across the algebra

Every presence query — membership, retrieval, matching, recognition — returns `:f64`, not `:bool`:

```scheme
(:wat/core/define (:my/app/member? (set-thought :Holon) (candidate :Holon) -> :f64)
  (presence candidate (encode set-thought)))

(:wat/core/define (:my/app/contains? (bundle-thought :Holon) (candidate :Holon) -> :f64)
  (presence candidate (encode bundle-thought)))

(:wat/core/define (:my/app/recognize (observation :Vector)
                                     (engram-lib :Holon)
                                     -> :List<Pair<Holon,f64>>)
  ;; Return every engram with its presence score. The caller decides
  ;; what to do with the list — top-1, above-threshold, weighted
  ;; bundle, whatever their application demands.
  (:wat/core/map (entries engram-lib)
    (:wat/core/lambda (entry)
      (:wat/core/list (:wat/core/first entry)
                       (presence (:wat/core/first entry) observation)))))
```

Uniform. Scalar-valued. The caller decides when a score is "enough," and which of many above-threshold entries to prefer. The function returns measurements; policy is the caller's code.

### Structural access is a separate operation

For data structures where the key is EXACT — not a similarity match — the operation is AST-walking, not presence measurement:

```scheme
(:wat/std/get (map-thought :Holon) (key :Holon) -> :Holon)
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
(:wat/core/when (:wat/core/> (presence target reference) (noise-floor d))
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
(:wat/core/let ((candidates (:wat/core/filter
                    (:wat/core/lambda ((p :Holon) -> :bool)
                      (:wat/core/> (presence query (encode p)) (noise-floor d)))
                    program-library)))

  ;; Run the candidates that aligned:
  (:wat/core/map (:wat/core/lambda ((p :Holon) -> :Holon) (eval p))
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
(:wat/core/define (:my/ns/amplify (x :Holon) (y :Holon) (s :f64) -> :Holon)
  (:wat/algebra/Blend x y 1 s))
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

All three layers — language core, algebra core, stdlib (project and user) — use the same keyword-path naming convention (`:wat/core/...`, `:wat/algebra/...`, `:wat/std/...`, `:user/...`). No namespace mechanism; just naming discipline. See `## Naming Discipline — Keyword Paths, No Mechanism` for the canonical policy.

### Executable semantics — functions run, holons are realized on demand

Two runtime semantics matter, and they are different.

**1. `define` / `lambda` bodies EXECUTE.**

A `(define ...)` form is not a specification. It is a **function**. When the wat-vm encounters a call to that function, it RUNS the body — real code, real time, real return values. The runtime interprets or JITs the body; arguments bind to parameters; the body's final expression becomes the return value.

```scheme
(:wat/core/define (:my/app/demo -> :bool)
  true)

(:my/app/demo)
;; The wat-vm runs the body. Returns the literal `true`.
;; Took microseconds. Produced a value of type :bool.
```

```scheme
(:wat/core/define (:my/app/add-two (x :f64) (y :f64) -> :f64)
  (:wat/core/+ x y))

(:my/app/add-two 3 4)
;; Runs. Returns 7.
```

Bodies of type `:Holon` are no different — they execute and return HolonAST values:

```scheme
(:wat/core/define (:my/app/hello-world (name :Atom) -> :Holon)
  (:wat/std/Sequential (:wat/core/list (:wat/algebra/Atom "hello") name)))

(:my/app/hello-world (:wat/algebra/Atom :watmin))
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
(:wat/core/define :my/app/greeting (:my/app/hello-world (:wat/algebra/Atom :watmin)))    ; AST value, no vector
(:wat/core/define :my/app/another  (:my/app/hello-world (:wat/algebra/Atom :alice)))     ; AST value, no vector

;; Still no vectors. These are just AST descriptions.

(cosine :my/app/greeting :my/app/another)
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

wat/std/
  └── Stdlib forms that COMPILE into AST or are functions — macros,
      functions, data-structure constructors, local data structures.
      One file per form. Keyword path = file path.

      wat/std/Subtract.wat        ;; :wat/std/Subtract       (macro)
      wat/std/Amplify.wat         ;; :wat/std/Amplify        (macro)
      wat/std/Chain.wat           ;; :wat/std/Chain          (macro)
      wat/std/Ngram.wat           ;; :wat/std/Ngram          (macro)
      wat/std/Analogy.wat         ;; :wat/std/Analogy        (macro)
      wat/std/HashMap.wat         ;; :wat/std/HashMap        (macro)
      wat/std/Vec.wat             ;; :wat/std/Vec            (macro)
      wat/std/HashSet.wat         ;; :wat/std/HashSet        (macro)
      wat/std/Log.wat             ;; :wat/std/Log            (macro)
      wat/std/Circular.wat        ;; :wat/std/Circular       (macro)
      wat/std/Sequential.wat      ;; :wat/std/Sequential     (macro)
      wat/std/Flip.wat            ;; :wat/std/Flip           (macro)
      wat/std/LocalCache.wat      ;; :wat/std/LocalCache     (data + functions)
      wat/std/cached-encode.wat   ;; :wat/std/cached-encode  (function)
      ... one file per form.

      (Note: :wat/kernel/HandlePool is NOT under wat/std/ — it ships
       with the kernel alongside make-bounded-queue, spawn, select.
       It is the deadlock guard; every mailbox-backed driver relies
       on its claim-or-panic invariant. Infrastructure, not pattern.)

wat/std/program/
  └── Stdlib PROGRAMS — spawnable wat-vm programs with their own
      lifecycle, owned state, and queue interfaces. Exactly TWO ship
      (see "Programs are userland — with two exceptions"):

      wat/std/program/Console.wat  ;; :wat/std/program/Console
                                    ;;   single-sink fan-in serializer for
                                    ;;   one :QueueSender<String> (stdout
                                    ;;   or stderr, typically)
      wat/std/program/Cache.wat    ;; :wat/std/program/Cache<K,V>
                                    ;;   LRU memoization with telemetry
                                    ;;   hooks; the hot path of any holon
                                    ;;   program that encodes ASTs

      No more. Database, telemetry pipelines, rate-gates, signal
      converters, domain-specific observers/brokers/treasuries — all
      USERLAND. Apps ship them under their own paths (:project/.../
      program/..., alice/program/..., etc.). See FOUNDATION's
      "Programs are userland" subsection for the six-rule conformance
      contract.

      The two-directory split reflects the substrate distinction:
      wat/std/         — compiles into AST or runs as a function call
      wat/std/program/ — runs as an independent wat-vm program
```

**Each stdlib file is a single `defmacro` / `define` / `program` declaration whose keyword-path name matches the file path.** The Rust wat-vm binary compiles them in via per-file `load` calls in its startup manifest. Users add their own stdlib the same way under their own directories (`wat/alice/math/clamp.wat`, `wat/alice/program/ClampServer.wat`, etc.).

**Keyword path = file path.** `:wat/std/Subtract` lives at `wat/std/Subtract.wat`; `:wat/std/program/Cache` lives at `wat/std/program/Cache.wat`. No translation. No manifest of exports to maintain. Cryptographic identity is per-file: signing `wat/std/Subtract.wat` signs exactly that form's body. Growth is additive: new form = new file, no edits elsewhere. `ls wat/std/` and `ls wat/std/program/` ARE the stdlib inventories for their respective kinds.

User code follows the same discipline: `:alice/math/clamp` lives at `wat/alice/math/clamp.wat` (under the project's wat root). If alice ships a program, it lives at `wat/alice/program/MyProgram.wat` under the keyword path `:alice/program/MyProgram`. The file path under `wat/` mirrors the keyword-path segments after the initial `:`. Cross-project distribution is a tarball of `wat/` directories with signatures per file.

**The `program/` segment is an honest name, not a mechanism.** It tells the reader (and the naming system) that what's at that path RUNS rather than COMPILES-into-AST. No special parser treatment; the convention is purely directory organization reflecting the kind of artifact. Users are free to use or not use the convention in their own code — `:alice/Cache` would work too, just less self-documenting.

---

## Naming Discipline — Keyword Paths, No Mechanism

**The wat language does NOT have a namespace mechanism.** No `declare-namespace`, no aliasing, no `import`, no `require`, no `use`, no `from`. Slashes in keyword names are just characters; `:wat/std/circular-cos-basis` is a single keyword whose name is `wat/std/circular-cos-basis`. The hash function sees the whole string. No structural meaning is attached to the slash beyond naming convention.

This section is the **single canonical statement** of the naming policy. Other FOUNDATION sections reference it; proposals cite it; sub-proposals' example signatures use it without restating the policy.

### The discipline

All four naming positions in the language — language core, algebra core, stdlib (project and user), and Atom literal keywords — use the same keyword-path convention:

```
:wat/core/define            ; language core primitive
:wat/core/lambda
:wat/core/if

:wat/algebra/Atom           ; algebra core primitive
:wat/algebra/Bind
:wat/algebra/Bundle

:wat/std/Subtract           ; project stdlib
:wat/std/HashMap
:wat/std/Vec

:wat/std/circular-cos-basis ; reserved stdlib atom literal
:wat/std/circular-sin-basis

:alice/math/clamp           ; user extension — function
:project/market/Candle      ; user extension — type
:bob/vocab/Unbind           ; user extension — macro
:trading/rsi-extreme        ; user extension — atom literal
```

Anyone can claim any prefix. Collisions are prevented by **discipline and culture, not by the language.**

### What this means

- **Types use the same discipline** — `:project/market/Candle`, `:alice/types/Price`.
- **Macros use the same discipline** — `:wat/std/Subtract`, `:my/vocab/Unbind`.
- **Atoms use the same discipline** — `(Atom :wat/std/circular-cos-basis)`, `(Atom :my-app/thing)`.
- **There is no escape hatch.** This is the policy across every naming position in the language.

Userland gets namespaces **for free** because keywords allow any characters and slashes are just characters. No new grammar, no declaration form, no import graph. You pick a distinctive prefix and that prefix is yours until someone else claims it.

### What this is NOT

- **NOT Clojure's `(ns ...)` form** with `:require`, `:refer`, `:as` aliasing.
- **NOT Rust's `mod`** with `use`, `pub use`, or `crate::path` resolution.
- **NOT Python's `import x as y`** — no short-name binding.
- **NOT any declare-before-use system.** Names carry their full path literally at every reference.

### Collision detection at startup

Because Model A loads every function at startup (see *The Algebra Is Immutable*), name collisions are detected during loading. Two competing definitions of `:alice/math/clamp` produce a **startup-time name collision that halts the wat-vm.** There is no "last one wins" semantics, no shadowing, no partial state. Either every loaded name is unique, or the wat-vm refuses to start.

This makes the discipline enforceable in practice: conflicts fail loudly and early, not silently at runtime. Two teams working on the same codebase who both claimed `:shared/helper` discover the collision at the first `./wat-vm.sh smoke`, not in production.

### Reserved prefixes — protected

The project reserves four prefixes, and they are **protected at startup** — users cannot define anything at these paths. Attempting `(:wat/core/define (:wat/kernel/my-func ...) ...)` or `(:wat/core/defmacro (:wat/std/MyAlias ...) ...)` halts the wat-vm with a startup error.

- `:wat/core/...` — language core primitives (`:wat/core/define`, `:wat/core/lambda`, `:wat/core/let`, `:wat/core/let*`, `:wat/core/if`, `:wat/core/match`, `:wat/core/cond`, `:wat/core/defmacro`, `:wat/core/load!`, `:wat/core/list`, `:wat/core/first`, `:wat/core/second`, `:wat/core/+`, `:wat/core/-`, `:wat/core/*`, `:wat/core/>`, `:wat/core/=`, …)
- `:wat/kernel/...` — wat-vm kernel primitives (`:wat/kernel/make-bounded-queue`, `:wat/kernel/make-unbounded-queue`, `:wat/kernel/spawn`, `:wat/kernel/send`, `:wat/kernel/recv`, `:wat/kernel/try-recv`, `:wat/kernel/select`, `:wat/kernel/drop`, `:wat/kernel/join`, `:wat/kernel/HandlePool`)
- `:wat/config/...` — ambient startup constants: setters (`set-dims!`, `set-capacity-mode!`), getters (`dims`, `capacity-mode`), and the `:wat/config/CapacityMode` enum. Required-at-startup values the program author commits once; see "`:wat/config` — Ambient Startup Constants."
- `:wat/algebra/...` — algebra core primitives (`:wat/algebra/Atom`, `:wat/algebra/Bind`, `:wat/algebra/Bundle`, `:wat/algebra/Blend`, …)
- `:wat/std/...` — project stdlib (`:wat/std/Subtract`, `:wat/std/HashMap`, `:wat/std/Chain`, `:wat/std/LocalCache`, circular basis atoms, `:wat/std/program/Cache`, …)

User code uses its own distinctive prefixes — `:alice/...`, `:project/market/...`, `:my-app/...`. The `:wat/...` prefix is the only one the language forbids users from claiming.

### No bare aliases — every call uses a full keyword path

Earlier drafts allowed **bare aliases**: every form the wat-vm provided at a `:wat/...` path was also registered under its bare name (`Subtract`, `Bind`, `define`, `make-bounded-queue`). Users could write either. This was convenience, and it was dishonest.

REJECTED. Every call to a wat-vm-provided form uses its full keyword path, always:

```scheme
(:wat/core/define (:my/app/hello (name :String) -> :String)
  (:wat/std/string/join "" (:wat/core/list "Hello, " name "!")))

(:wat/algebra/Bundle (:wat/core/list x y z))
(:wat/kernel/send out "hello")
```

No shorter form exists. The frustration is the point: every side, every capability, every identity is visible in source. A reader knows at a glance whether a call targets the algebra, the kernel, or the stdlib. Hash identity is always on the full path, because the full path is the only form that ever appears.

**Why this is simpler, not easier.** Convenience aliases look small but pay a cost: the reader must track shadowing to know which `Subtract` a call resolves to, and diffing becomes ambiguous when two files use different conventions. Without aliases, the language has one rule — "write the full path" — and the source text is the identity claim. No symbol-table precedence, no shadowing-by-symbol-table, no dual-tier lookup. Simple. Not easy; type more. But simple.

### Lexical shadowing is the only shadowing

The one place names can shadow is **lexical scope**: a `let` binding, a `lambda` parameter, or a `match` pattern introduces a local name that the body of that scope sees in preference to any enclosing scope. This is ordinary Lisp lexical scoping, and it applies only to BARE names introduced in that scope — never to `:wat/...` paths, which are not bindings you can shadow.

```scheme
;; A parameter named `x` shadows any outer `x`:
(:wat/core/define (:my/app/add-one (x :i64) -> :i64)
  (:wat/core/+ x 1))                         ;; `x` is the parameter

;; A let binding introduces a bare local:
(:wat/core/let ((result (compute-something)))
  (:wat/kernel/send out result))             ;; `result` is the let binding

;; The full path :wat/kernel/send is NEVER shadowable — no let binding can
;; "capture" it, because :wat/kernel/send is not a bindable name. It's a
;; path literal the parser resolves against the symbol table, not a
;; variable reference.
```

There is no "shadowable alias" tier and no "outermost bare scope" — just lexical scopes of bare names introduced by the programmer, and full keyword paths that always resolve to their canonical target.

### How this relates to `:allow-redef`

The `### Redefinition mode — opt-in startup knob` subsection covers collision behavior for user-defined names. With no bare aliases, the rules simplify:

- **`:wat/...` paths are protected in BOTH modes.** `:strict` and `:allow-redef` agree: you cannot redefine anything at `:wat/core/`, `:wat/kernel/`, `:wat/algebra/`, or `:wat/std/`. Attempt = halt.
- **`:allow-redef` only matters for user-path collisions.** Two files both defining `:alice/math/clamp` with different bodies: that's a user-path collision. `:strict` halts; `:allow-redef` permits with logging. No bare-alias interaction to worry about — aliases do not exist.

### Type-tagged hashing keeps literal types distinct

Because keywords are a first-class literal type alongside strings, integers, floats, and booleans (see 058-001 typed atoms), there is no collision risk between `(Atom 0)` (integer) and `(Atom :pos/0)` (keyword) — they hash with different type tags and produce different vectors. Collision between different keyword names (`:foo` vs `:bar`) is the user's responsibility — pick distinctive names.

### Why this choice

- **Matches cryptographic hash identity.** The full name is part of the hash (see *The Algebra Is Immutable*). Aliasing a name to a different one would break identity for downstream hashes that reference it by its full path.
- **Matches Model A static loading.** Everything resolves at startup; one-name-one-definition keeps resolution trivial.
- **Matches Rust's host-first honesty.** Rust does not let you redefine what a fully-qualified path means; wat doesn't either.
- **Keeps the language surface small.** No new grammar for namespace declarations, no resolution rules, no import graph, no binding scope for short names.

The cost is verbosity (every reference carries its full path). The benefit is no name-resolution confusion ever — the hash sees what you wrote, and what you wrote is what ships.

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

(:wat/algebra/Atom literal)
;; AST node storing a literal (string, int, float, bool, keyword).
;; Literal is READ DIRECTLY from the AST node via (:wat/std/atom-value ...).
;; Vector projection: deterministic bipolar vector from type-aware hash.
;;   (:wat/algebra/Atom "foo")  — string literal
;;   (:wat/algebra/Atom 42)     — integer literal
;;   (:wat/algebra/Atom 1.6)    — float literal
;;   (:wat/algebra/Atom true)   — boolean literal
;;   (:wat/algebra/Atom :name)  — keyword literal
;; Type-aware hash ensures (Atom 1) ≠ (Atom "1") ≠ (Atom 1.0)
;; NO null — Rust doesn't have null; wat doesn't have null.
;; Absence is :Option<T>; unit is :().

(:wat/algebra/Bind a b)
;; element-wise multiplication, self-inverse
;; (:wat/algebra/Bind a (:wat/algebra/Bind a b)) = b

(:wat/algebra/Bundle list-of-holons)
;; list → element-wise sum + threshold
;; commutative, takes an explicit list (not variadic)

(:wat/algebra/Permute child k)
;; circular shift of dimensions by integer k

;; --- Scalar primitives ---

(:wat/algebra/Thermometer value min max)
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

(:wat/algebra/Blend a b w1 w2)
;; scalar-weighted binary combination
;; threshold(w1·a + w2·b)
;; weights can be any real numbers (including negative)

;; --- New compositions (058 candidates) ---

(:wat/algebra/Orthogonalize x y)
;; geometric projection removal
;; X - ((X·Y)/(Y·Y)) × Y — computed projection coefficient
;; result is orthogonal to y (dot product ≈ 0)
;; was one mode of the original "Negate"; the other modes became Blend idioms

(:wat/algebra/Resonance v ref)
;; sign-agreement mask
;; keeps dimensions where v and ref agree in sign, zeros elsewhere
;; first core form producing ternary {-1, 0, +1} output

(:wat/algebra/ConditionalBind a b gate)
;; three-argument gated binding
;; bind a to b only at dimensions where gate permits
```

Retrieval is NOT a core form. Presence is measured by `cosine(encode(target), reference)` against the substrate's noise floor — see "Presence is Measurement, Not Verdict" above. Classical Cleanup is historical: the vector-primary tradition's answer to "which named thing is this?" The wat substrate inverts that question because the AST is always available. Argmax-over-codebook, when an application needs it, is a stdlib composition over presence measurement, not a primitive.

### Algebra Stdlib (17 forms)

```scheme
;; --- Scalar encoders ---

(:wat/core/define (:wat/std/Linear v scale)
  ;; value on a known bounded scale
  (:wat/algebra/Thermometer v 0 scale))

(:wat/core/define (:wat/std/Log v min max)
  ;; value spanning orders of magnitude
  (:wat/algebra/Thermometer (ln v) (ln min) (ln max)))

(:wat/core/define (:wat/std/Circular v period)
  ;; value on a cycle
  (:wat/core/let ((theta (:wat/core/* 2 pi (:wat/core// v period))))
    (:wat/algebra/Blend (:wat/algebra/Atom :wat/std/circular-cos-basis)
           (:wat/algebra/Atom :wat/std/circular-sin-basis)
           (cos theta)
           (sin theta))))

;; --- Structural compositions ---

(:wat/core/define (:wat/std/Sequential list-of-holons)
  ;; positional encoding
  ;; each holon permuted by its index (Permute by 0 is identity)
  (:wat/algebra/Bundle
    (map-indexed
      (:wat/core/lambda (i h) (:wat/algebra/Permute h i))
      list-of-holons)))

;; Concurrent was REJECTED (058-010) — no runtime specialization beyond
;; Bundle, enclosing context already carries the temporal meaning.
;; Userland may define it in their own namespace if they want the name:
;;   (:wat/core/defmacro (:my/vocab/Concurrent (xs :AST) -> :AST)
;;     `(:wat/algebra/Bundle ,xs))

;; Then was REJECTED (058-011) — arity-specialization of Sequential,
;; demonstrates nothing Sequential doesn't. Userland may define it:
;;   (:wat/core/defmacro (:my/vocab/Then (a :AST) (b :AST) -> :AST)
;;     `(:wat/std/Sequential (:wat/core/list ,a ,b)))

(:wat/core/define (:wat/std/Chain list-of-holons)
  ;; adjacency — Bundle of pairwise binary Sequentials
  ;; distinct from Sequential: captures transitions, not absolute positions
  (:wat/algebra/Bundle
    (:wat/core/map (:wat/core/lambda (pair)
           (:wat/std/Sequential (:wat/core/list (:wat/core/first pair) (:wat/core/second pair))))
         (pairwise list-of-holons))))

(:wat/core/define (:wat/std/Ngram n list-of-holons)
  ;; n-wise adjacency — generalizes Chain
  (:wat/algebra/Bundle
    (:wat/core/map (:wat/core/lambda (window)
           (:wat/algebra/Bind (:wat/algebra/Atom "ngram")
                 (:wat/std/Sequential window)))
         (n-wise n list-of-holons))))

;; --- Weighted-combination idioms over Blend ---

(:wat/core/define (:wat/std/Amplify x y s)
  ;; boost component y in x by factor s
  (:wat/algebra/Blend x y 1 s))

(:wat/core/define (:wat/std/Subtract x y)
  ;; remove y from x at full strength
  ;; was Negate(x, y, "subtract") — now an explicit Blend idiom
  (:wat/algebra/Blend x y 1 -1))

(:wat/core/define (:wat/std/Flip x y)
  ;; linear inversion — invert y's contribution in x
  ;; was Negate(x, y, "flip") — now an explicit Blend idiom
  ;; weight -2 is the minimum inversion weight for bipolar vectors
  (:wat/algebra/Blend x y 1 -2))

;; --- Relational transfer ---

(:wat/core/define (:wat/std/Analogy a b c)
  ;; A is to B as C is to ?
  ;; computes C + (B - A)
  (:wat/algebra/Bundle (:wat/core/list c (:wat/std/Subtract b a))))

;; --- Data structures (Rust-surface names) ---
;;
;; wat's UpperCase constructors match Rust's collection names directly:
;;   HashMap  ↔  std::collections::HashMap
;;   Vec      ↔  std::vec::Vec
;;   HashSet  ↔  std::collections::HashSet
;; One name per concept across algebra, type annotation, and runtime backing.

(:wat/core/define (:wat/std/HashMap (pairs :List<Pair<Holon,Holon>>) -> :Holon)
  ;; Key-value container. Each pair becomes a Bind of key to value; all pairs
  ;; bundled together. Runtime backs it with Rust's HashMap for O(1) lookups.
  (:wat/algebra/Bundle
    (:wat/core/map (:wat/core/lambda ((pair :Pair<Holon,Holon>) -> :Holon)
           (:wat/algebra/Bind (:wat/core/first pair) (:wat/core/second pair)))
         pairs)))

(:wat/core/define (:wat/std/Vec (items :List<Holon>) -> :Holon)
  ;; Indexed container. Each item bound to its position as an integer atom.
  ;; (Atom i) is the atom whose literal IS the integer i. Runtime backs it
  ;; with Rust's Vec for O(1) indexing.
  (:wat/algebra/Bundle
    (map-indexed
      (:wat/core/lambda ((i :usize) (item :Holon) -> :Holon)
        (:wat/algebra/Bind (:wat/algebra/Atom i) item))
      items)))

(:wat/core/define (:wat/std/HashSet (items :List<Holon>) -> :Holon)
  ;; Unordered collection. Bundle of items; runtime backs it with Rust's
  ;; HashSet for O(1) membership. Presence is structural (via `get`) or
  ;; similarity-measured (via `presence`), caller's choice.
  (:wat/algebra/Bundle items))

;; --- get: unified structural retrieval ---
;;
;; Works uniformly across HashMap, Vec, HashSet. Returns :Option<Holon>.
;; Direct lookup through the container's efficient Rust backing — no walk,
;; no cosine, no cleanup. The AST describes the container; the runtime
;; materializes the efficient backing (HashMap, Vec, HashSet) for O(1)
;; structural access.
;;
;; For each container:
;;   (:wat/std/get (c :HashMap<K,V>) (k :K))      -> :Option<V>   ;; lookup by key
;;   (:wat/std/get (c :Vec<T>)       (i :usize))  -> :Option<T>   ;; index into vec
;;   (:wat/std/get (c :HashSet<T>)   (x :T))      -> :Option<T>   ;; membership → Some(x) or None

(:wat/core/define (:wat/std/get (container :Holon) (locator :Holon) -> :Option<Holon>)
  ;; Dispatches on the container's runtime backing:
  ;;   HashMap → HashMap::get(locator) — hash lookup, O(1) avg
  ;;   Vec     → Vec[locator]          — direct index, O(1)
  ;;   HashSet → HashSet::get(locator) — hash membership, O(1) avg
  ;; Returns (Some v) on hit, None on miss. No vectors involved.
  ...)

;; Note: `nth` is retired. Use `get` uniformly — `(:wat/std/get my-vec 3)` is `nth`.

(:wat/core/define (:wat/std/atom-value atom-ast)
  ;; Read the literal stored on an Atom AST node.
  ;; No cleanup. No codebook. No cosine. Just field access.
  (literal-field atom-ast))

;; Unbind was REJECTED (058-024) — literally (Bind composite key).
;; Under the stdlib-as-blueprint test, it demonstrates no new pattern.
;; Bind-on-Bind IS Unbind; that's a fact about the algebra the user
;; learns once. Userland may define the alias if decode-intent framing
;; matters to their vocab:
;;   (:wat/core/defmacro (:my/vocab/Unbind (c :AST) (k :AST) -> :AST)
;;     `(:wat/algebra/Bind ,c ,k))
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

(:wat/core/define (name (param :Type) ... -> :ReturnType) body)
;; Named, typed function registration.
;; Body executes when invoked. Types are required for dispatch and signing.
;; Keyword-path names supported: (:wat/core/define (:alice/math/clamp ...) ...).

(:wat/core/lambda ((param :Type) ... -> :ReturnType) body)
;; Typed anonymous functions with closure capture.
;; Same signature shape as define, without the name.
;; Produces a :fn(...)->... value — a runtime value, NOT a symbol-table entry.
;; Can be created, passed, invoked during runtime; goes away when scope ends.

;; --- Function module loading (startup phase) ---

(:wat/core/load! "path/to/file.wat")
;; Unverified startup load — reads the file, parses defines, registers.
;; Trust the contents; accept whatever's on disk.

(:wat/core/load! "path/to/file.wat" (md5 "abc123..."))
;; Hash-pinned startup load — requires file content to hash to the given value.
;; Halts wat-vm startup if mismatched.

(:wat/core/load! "path/to/file.wat" (signed <signature> <pub-key>))
;; Signature-verified startup load — verifies signature against supplied public key.
;; Halts wat-vm startup if signature invalid.

;; All (:wat/core/load! ...) happens at startup. Files loaded via (:wat/core/load! ...) must
;; contain ONLY function definitions — a type declaration is a startup error.

;; ============================================================
;; TYPE DECLARATIONS — materialized into the wat-vm binary at
;; build time. Fully static.
;; ============================================================

;; --- User-defined types (keyword-path names) ---

(:wat/core/struct :my/namespace/MyType
  (field1 :Type1)
  (field2 :Type2)
  ...)
;; Named product type. Fields travel together. Rust compiles to a struct.
;; Example:
;;   (:wat/core/struct :project/market/Candle
;;     (open   :f64)
;;     (high   :f64)
;;     (low    :f64)
;;     (close  :f64)
;;     (volume :f64))

(:wat/core/enum :my/namespace/MyVariant
  :simple-variant-1
  :simple-variant-2
  (tagged-variant (field :Type) ...))
;; Coproduct type. Exactly one of several alternatives.
;; Example:
;;   (:wat/core/enum :my/trading/Direction :long :short)
;;   (:wat/core/enum :my/market/Event
;;     (candle  (asset :Atom) (candle :project/market/Candle))
;;     (deposit (asset :Atom) (amount :f64)))

(:wat/core/newtype :my/namespace/MyAlias :SomeType)
;; Nominal alias — same representation, distinct type identity.
;; Example:
;;   (:wat/core/newtype :my/trading/TradeId :u64)
;;   (:wat/core/newtype :my/trading/Price   :f64)

(:wat/core/typealias :my/namespace/MyShape (structural-type-expression))
;; Structural alias — alternative name for an existing type shape.
;; Compiles to Rust: `type Name = Expr;`
;; Example:
;;   (:wat/core/typealias :alice/types/Amount :f64)
;;   (:wat/core/typealias :alice/market/CandleSeries :List<Candle>)
;;   (:wat/core/typealias :alice/trading/Scores :HashMap<Atom,f64>)
;;
;; Note: :Option<T> is an enum (coproduct), not a typealias.
;;   (:wat/core/enum :wat/std/Option<T>
;;     :None
;;     (Some (value :T)))

;; --- Compile-time module loading (types only) ---

(:wat/core/load-types! "path/to/types.wat")
;; Unverified build-time load. Reads the file, parses type declarations,
;; feeds them to the build pipeline for Rust code generation.

(:wat/core/load-types! "path/to/types.wat" (md5 "abc123..."))
;; Hash-pinned build-time load. Build halts if the file hash does not match.

(:wat/core/load-types! "path/to/types.wat" (signed <signature> <pub-key>))
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
;; Algebra — :Holon is an enum; :Atom, Bind, Bundle, Permute,
;;   :Thermometer, Blend, Orthogonalize, Resonance, ConditionalBind
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
(:wat/algebra/Atom 0)           ; position zero in a Vec — zero IS an integer
(:wat/algebra/Atom 42)          ; the integer 42
(:wat/algebra/Atom -1)          ; the integer -1

;; FLOAT: use when the thing is a concrete float.
(:wat/algebra/Atom 1.6)         ; the float 1.6
(:wat/algebra/Atom 3.14159)     ; the float pi (approximate)

;; BOOLEAN: use when the thing is concretely true or false.
(:wat/algebra/Atom true)
(:wat/algebra/Atom false)

;; STRING: use when the thing IS a string literal.
(:wat/algebra/Atom "rsi")       ; the string "rsi"
(:wat/algebra/Atom "trail")     ; the string "trail"

;; KEYWORD: use when the thing is a SYMBOLIC NAME — no concrete literal form.
(:wat/algebra/Atom :wat/std/circular-cos-basis)    ; a reserved symbolic anchor
(:wat/algebra/Atom :trading/momentum-lens)          ; a named concept
(:wat/algebra/Atom :rsi)                            ; a short-form symbolic name
```

The distinction matters because atoms store their literal on the AST node:

```scheme
(:wat/std/atom-value (:wat/algebra/Atom 0))      ; → 0    (the integer)
(:wat/std/atom-value (:wat/algebra/Atom "0"))    ; → "0"  (the string)
(:wat/std/atom-value (:wat/algebra/Atom :pos/0)) ; → :pos/0  (the keyword)
```

These are three different things. The type-aware hash gives them three different vectors. **Pick the type that matches the semantic, not the type that wraps the semantic.**

### Reserved Keyword Naming Convention

For references that ARE genuinely symbolic (no concrete literal form available), the stdlib uses keyword atoms with distinctive full names:

```scheme
(:wat/algebra/Atom :wat/std/circular-cos-basis)    ; used by Circular encoder
(:wat/algebra/Atom :wat/std/circular-sin-basis)    ; used by Circular encoder
```

These are TRULY symbolic — "the cos basis vector" has no natural integer or string representation. It's just a name. Keyword is the right type.

Vec position atoms are NOT in this category. Position 0 IS the integer 0. Use `(Atom 0)`, not `(Atom :pos/0)`.

**About slashes in keyword names.** Slashes are literal characters; `:wat/std/circular-cos-basis` is a single keyword. The stdlib uses `:wat/std/...` as a reserved prefix. User code uses its own distinctive prefixes or short bare keywords. See `## Naming Discipline — Keyword Paths, No Mechanism` for the canonical policy — the no-namespace-mechanism claim, collision detection at startup, reserved prefixes, and the type-tag hash that keeps `(Atom 0)` (integer) distinct from `(Atom :pos/0)` (keyword) live there.

### Usage Examples

```scheme
;; Role-filler separation everywhere — Bind joins name-atom to value:

(:wat/algebra/Bind (:wat/algebra/Atom "rsi")   (:wat/algebra/Thermometer 0.73 0 1))
(:wat/algebra/Bind (:wat/algebra/Atom "bytes") (:wat/std/Log 1500 1 1000000))
(:wat/algebra/Bind (:wat/algebra/Atom "hour")  (:wat/std/Circular 14 24))

;; Co-occurring observations — Bundle is the primitive, context carries the temporal meaning:
(:wat/algebra/Bind (:wat/algebra/Atom :observed-at-t1)
      (:wat/algebra/Bundle
        (:wat/core/list
          (:wat/algebra/Bind (:wat/algebra/Atom "rsi")   (:wat/algebra/Thermometer 0.73 0 1))
          (:wat/algebra/Bind (:wat/algebra/Atom "macd")  (:wat/algebra/Thermometer -0.02 -1 1)))))

;; Temporal sequence:
(:wat/std/Chain
  (:wat/core/list
    (:wat/algebra/Bind (:wat/algebra/Atom "rsi") (:wat/algebra/Thermometer 0.68 0 1))
    (:wat/algebra/Bind (:wat/algebra/Atom "rsi") (:wat/algebra/Thermometer 0.71 0 1))
    (:wat/algebra/Bind (:wat/algebra/Atom "rsi") (:wat/algebra/Thermometer 0.74 0 1))))

;; Relational verb with bundled observations:
(:wat/algebra/Bind (:wat/algebra/Atom "diverging")
      (:wat/algebra/Bundle
        (:wat/core/list
          (:wat/algebra/Bind (:wat/algebra/Atom "rsi")   (:wat/algebra/Thermometer 0.73 0 1))
          (:wat/algebra/Bind (:wat/algebra/Atom "price") (:wat/algebra/Thermometer 0.25 0 1)))))

;; --- Data structures — the unified holon data algebra ---

;; HashMap as key-value store:
(:wat/core/define :my/app/portfolio
  (:wat/std/HashMap (:wat/core/list
    (:wat/core/list (:wat/algebra/Atom "USDC") (:wat/algebra/Thermometer 5000 0 10000))
    (:wat/core/list (:wat/algebra/Atom "WBTC") (:wat/algebra/Thermometer 0.5  0 1.0)))))

(:wat/std/get :my/app/portfolio (:wat/algebra/Atom "USDC"))      ; → (Thermometer 5000 0 10000)

;; Vec as indexed collection:
(:wat/core/define :my/app/recent-rsi
  (:wat/std/Vec (:wat/core/list
    (:wat/algebra/Thermometer 0.68 0 1)
    (:wat/algebra/Thermometer 0.71 0 1)
    (:wat/algebra/Thermometer 0.74 0 1))))

(:wat/std/get :my/app/recent-rsi (:wat/algebra/Atom 2))          ; → (Thermometer 0.74 0 1)

;; Nested — HashMap of Vecs of holons:
(:wat/core/define :my/app/observer-state
  (:wat/std/HashMap (:wat/core/list
    (:wat/core/list (:wat/algebra/Atom "market-readings") :my/app/recent-rsi)
    (:wat/core/list (:wat/algebra/Atom "portfolio")       :my/app/portfolio))))

(:wat/std/get (:wat/std/get :my/app/observer-state (:wat/algebra/Atom "market-readings"))
     (:wat/algebra/Atom 0))                    ; → (Thermometer 0.68 0 1)

;; --- The locator can be ANY holon ---

;; The key doesn't have to be a bare Atom. It can be a composite holon:

(:wat/core/define :my/app/keyed-by-composite
  (:wat/std/HashMap (:wat/core/list
    (:wat/core/list (:wat/algebra/Bundle (:wat/core/list (:wat/algebra/Atom "rsi") (:wat/algebra/Atom "overbought")))
          some-value)
    (:wat/core/list (:wat/algebra/Bind (:wat/algebra/Atom "macd") (:wat/algebra/Atom "crossing-up"))
          other-value))))

;; Retrieve with the same composite as locator:
(:wat/std/get :my/app/keyed-by-composite
     (:wat/algebra/Bundle (:wat/core/list (:wat/algebra/Atom "rsi") (:wat/algebra/Atom "overbought"))))
;; → some-value

;; Keys can be HashMaps. Values can be HashMaps. Arbitrary nesting:
(:wat/core/define :my/app/wild
  (:wat/std/HashMap (:wat/core/list
    (:wat/core/list (:wat/std/HashMap (:wat/core/list (:wat/core/list (:wat/algebra/Atom "a") (:wat/algebra/Atom "b"))))    ; key IS a HashMap
          (:wat/std/Vec (:wat/core/list                                        ; value IS a Vec
            (:wat/std/HashMap (:wat/core/list (:wat/core/list (:wat/algebra/Atom "x") (:wat/algebra/Atom "y"))))   ; of HashMaps
            (:wat/algebra/Atom "atom-in-the-middle")                     ; of atoms
            (:wat/std/Vec (:wat/core/list (:wat/algebra/Atom "nested") (:wat/algebra/Atom "deeper")))))))) ; of Vecs
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
(:wat/algebra/Atom literal)                 ; 058-001  — typed-literal generalization
(:wat/algebra/Bind a b)                     ; 058-021  — primitive affirmation
(:wat/algebra/Bundle list-of-holons)        ; 058-003  — list signature lock
(:wat/algebra/Permute child k)              ; 058-022  — primitive affirmation
(:wat/algebra/Thermometer value min max)    ; 058-023  — primitive affirmation
(:wat/algebra/Blend a b w1 w2)              ; 058-002  — PIVOTAL, two independent weights
(:wat/algebra/Orthogonalize x y)            ; 058-005  — computed-coefficient projection removal
(:wat/algebra/Resonance v ref)              ; 058-006  — sign-agreement mask (first ternary-output form)
(:wat/algebra/ConditionalBind a b gate)     ; 058-007  — three-argument gated binding
```

**058-025 Cleanup is REJECTED.** The wat substrate has no `Cleanup` primitive — the AST-primary framing dissolves the need for codebook-based recovery. Retrieval is presence measurement (cosine + noise floor); argmax-over-candidates, when an application needs it, is stdlib composition over presence, not a core primitive. See "Presence is Measurement, Not Verdict" in FOUNDATION.

**Blend is pivotal.** Its promotion formalizes scalar-weighted combination, enabling Linear/Log/Circular/Amplify/Subtract/Flip reclassification as stdlib. Resolve early.

**Orthogonalize replaces Negate.** The original Negate proposal had three modes; 058 split them: `orthogonalize` became its own CORE (computed coefficient, not a Blend idiom); `subtract` and `flip` became stdlib Blend idioms (058-019, 058-020).

### Algebra Stdlib (17 forms)

**Proposals that argue STDLIB status — each one form per doc:**

```scheme
;; Blend-derived idioms (6)
(:wat/std/Difference a b)               ; 058-004  — delta, Blend(a, b, 1, -1)
(:wat/std/Amplify x y s)                ; 058-015  — scale y's emphasis, Blend(x, y, 1, s)
(:wat/std/Subtract x y)                 ; 058-019  — remove y linearly, Blend(x, y, 1, -1)
(:wat/std/Flip x y)                     ; 058-020  — invert y's contribution, Blend(x, y, 1, -2)
(:wat/std/Linear v scale)               ; 058-008  — Blend over two Thermometer anchors
(:wat/std/Log v min max)                ; 058-017  — same shape, log-normalized
(:wat/std/Circular v period)            ; 058-018  — same shape, sin/cos weights

;; Structural compositions (5)
(:wat/std/Sequential list)              ; 058-009  — reframing: Bundle of index-permuted
;; Concurrent REJECTED (058-010) — redundant with Bundle; userland macro if desired.
;; Then REJECTED (058-011) — arity-specialization of Sequential; userland.
(:wat/std/Chain list)                   ; 058-012  — Bundle of pairwise Thens
(:wat/std/Ngram n list)                 ; 058-013  — n-wise adjacency

;; Relational (1)
(:wat/std/Analogy a b c)                ; 058-014  — C + (B - A)

;; Data structures (3)
(:wat/std/HashMap kv-pairs)             ; 058-016  — Rust's HashMap as Bundle of Binds
(:wat/std/Vec items)                    ; 058-026  — Rust's Vec as Bundle of integer-atom Binds
(:wat/std/HashSet items)                ; 058-027  — Rust's HashSet as Bundle of elements

;; Decode aliasing (1)
;; Unbind REJECTED (058-024) — identity alias for Bind; userland.
```

Plus lowercase helpers: `get` (unified structural retrieval across HashMap / Vec / HashSet, returns `:Option<Holon>`) and `atom-value` (direct field access on an Atom AST node). These are stdlib but not UpperCase — they're accessors, not AST constructors. `nth` is retired — `(get vec i)` replaces it.

### Language Core (8 forms)

**Proposals that argue LANGUAGE CORE status:**

Runtime forms (registered at wat-vm runtime into the content-addressed symbol table):

```scheme
:wat/core/define               ; 058-028  — typed named function registration
:wat/core/lambda               ; 058-029  — typed anonymous functions + closures
:wat/core/load!                 ; FOUNDATION addition — runtime module loading (functions only)
```

Compile-time forms (materialized into the Rust-backed wat-vm binary; cannot be redefined at runtime):

```scheme
:wat/core/struct               ; FOUNDATION addition — named product type
:wat/core/enum                 ; FOUNDATION addition — coproduct type
:wat/core/newtype              ; FOUNDATION addition — nominal alias
:wat/core/typealias            ; 058-030 + FOUNDATION — structural alias
:wat/core/load-types!           ; FOUNDATION addition — compile-time module loading (types only)
```

Syntactic feature pervading all of the above:

```scheme
type annotations               ; 058-030  — :Holon, Atom, Rust primitives, parametric, user keyword-path
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

Moved to `FOUNDATION-CHANGELOG.md`. That document tracks every revision to this one — decision, reasoning, where it landed. New entries append there; FOUNDATION itself stays focused on the load-bearing architecture.

If you are auditing a specific change, read the changelog alongside this document.

---

## Open Questions

1. ~~**Stdlib location.**~~ **RESOLVED.** One file per stdlib form. `:wat/std/Subtract` lives at `wat/std/Subtract.wat`; `:wat/std/Chain` at `wat/std/Chain.wat`; `:wat/std/HashMap` at `wat/std/HashMap.wat`. Keyword-path IS file-path. Matches the per-form cryptographic-identity story (signing one file signs one form's body; editing Chain doesn't move Subtract's hash), makes growth purely additive (new form = new file), and makes `ls wat/std/` the stdlib inventory. No manifest file to keep in sync. Same pattern as 058 itself (one proposal per directory). See "Where Each Lives" for the updated directory layout.

2. ~~**Stdlib optimization path.**~~ **RESOLVED — dissolves into the cache.** Q2 rested on a false distinction. After 058-031 macro expansion, a stdlib form's AST and a user-written AST with the same shape are literally the same AST — same hash, same cache entry, same encoding cost. There is no "stdlib form" tier to optimize at runtime because after parse-time expansion, stdlib forms don't exist as distinct nodes. The optimization story for ALL composed forms — stdlib or user — is the L1/L2 holon cache hitting on recurring subtrees (Proposal 057); the encoder walks the AST once, subtree vectors cache, repeated substructure pays encoding cost once. If an expression is big, it's big — the AST IS the program. No Rust-side helper tier. No dual implementation. One source (the wat macro), one walker (the encoder), one cache (L1/L2). A "hot stdlib form" is indistinguishable, after expansion, from any other hot composed AST; both are served by the same cache.

3. ~~**Enum-retained stdlib policy.**~~ **RESOLVED.** 058-008 Linear REJECTED (redundant with Thermometer under the 3-arity signature). Log (058-017), Circular (058-018), Sequential (058-009) are stdlib macros that expand to core compositions at parse time. 058-031 defmacro runs the expansion before hashing. The enum variants for Linear/Log/Circular/Sequential can be removed from HolonAST; the stdlib lives entirely as wat macros over the nine core variants (Atom, Bind, Bundle, Permute, Thermometer, Blend, Orthogonalize, Resonance, ConditionalBind).

4. ~~**Cache behavior for stdlib.**~~ **RESOLVED** by 058-031. Macros expand at parse time, BEFORE hashing. The canonical (post-expansion) AST is what hashes and caches. Two source files that differ only in macro aliases — `(Subtract a b)` vs `(Blend a b 1 -1)`, `(Concurrent xs)` vs `(Bundle xs)` — produce the same expanded AST and the same hash. No separate canonicalization layer needed; the expansion pass IS the canonicalization.

5. ~~**Ngram's `n` parameter handling.**~~ **RESOLVED.** `Ngram` with different `n` produces a different expanded AST (different Sequential-encoded windows bundled). The integer `n` lives in the structural form after macro expansion, so the cache key naturally distinguishes `(Ngram 2 xs)` from `(Ngram 3 xs)`. No special handling needed beyond the generic expansion + hash pipeline.

6. ~~**The MAP canonical set completeness.**~~ **RESOLVED — wrong question.** "Completeness" is unanswerable without knowing every future application; any answer is either speculation or circular. The honest framing is narrower and true: **this is the set we know we need right now**, argued by the forms the 058 sub-proposals successfully defended against FOUNDATION's criterion. The nine algebra-core variants — `Atom`, `Bind`, `Bundle`, `Permute`, `Thermometer`, `Blend`, `Orthogonalize`, `Resonance`, `ConditionalBind` — cover every operation 058 identified; that's the claim. If a future application reveals a primitive that cannot be expressed with existing forms, a new proposal argues it against the criterion (demonstrates a distinct algebraic operation; is domain-agnostic; the encoder must treat it distinctly) and adds it. The proposal process IS the extension mechanism. Same spirit as the stdlib-as-blueprint rule: don't ship forms speculatively; ship only what demonstrates a distinct pattern you need today. Not "is this the complete set?" but "is this every form we know we need?" — yes.

7. ~~**`:allow-redef` expression syntax.**~~ **RESOLVED — by analogy with `:user/main`.** Datamancer's insight: "user declares main by name." The `:user/main` entry-point convention dictates the resolution for redef too. The user doesn't need a special syntax to express "this redefines an existing name"; they just **USE the name**. The CLI flag `redef-mode=:allow-redef` at wat-vm startup permits later-loaded definitions to replace earlier ones; the user expresses intent simply by writing `(define (:some/existing/name ...) ...)` with a name that already exists in a prior-loaded file. The wat-vm logs each replacement (prior file + new file + resolved body) for audit. No per-file pragma, no `(redefines ...)` form at the definition site, no startup manifest directive — just the mode flag at the system level, and "using the name" at the declaration level. Same shape as `:user/main`: kernel-looked-up slot filled by the user's declaration. The mode is a system-wide opt-in; the syntax IS the declaration.

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
