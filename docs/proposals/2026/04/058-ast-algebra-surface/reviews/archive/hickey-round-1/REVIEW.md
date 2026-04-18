# Review — 058 AST Algebra Surface

A Hickey-lens pass on FOUNDATION, 30 sub-proposals, and the supporting docs.

---

## Summary verdict

The batch earns most of its ambition, but not in the shape it believes. The central move — "AST is primary, vector is cached projection; the literal lives on the AST node" — is the right move. It is simple. It decomplects "what the thing IS" (the AST value) from "what the thing PROJECTS TO" (a bipolar vector) from "how we find it" (structural traversal vs. algebraic similarity). That reframing is the single most important result here, and the rest of the algebra mostly rides it honestly.

Of the three pivotal decisions:

- **Blend as core with two independent weights (058-002): ACCEPT.** It is the right primitive. It unifies Linear/Log/Circular/Difference/Amplify/Subtract/Flip. Scalar-weighted addition of two vectors is a genuinely new algebraic operation the MAP canonical set cannot perform. This one is simple made simple.

- **Types (058-030) with required annotations on define/lambda: ACCEPT IN SHAPE, HAMMOCK THE SURFACE.** The need is real; the surface as currently sketched is under-hammocked. Generic syntax `Option<:T>`, the overlap between `deftype` (structural) and `newtype` (nominal) and `struct` (also nominal), and the treatment of user-type keyword names as both "types" and "namespaces via discipline" need another pass. Required types on function boundaries is correct. The rest is shaped by the hand holding the pencil, not by the geometry of the problem.

- **Model A static loading: ACCEPT FOR THE HOST, NOT FOR THE ALGEBRA.** The FOUNDATION document is honest that this is a deployment constraint imposed by hosting on Rust, not an algebraic invariant. That is the right honesty. The confusion starts when FOUNDATION talks about Model A as if it were load-bearing for cryptographic provenance or semantic correctness. It is not. It is load-bearing for implementation tractability. Keep the honesty visible; don't let it drift.

The work to do before commit: **decomplect three redundant alias pairs, resolve two internal contradictions in the documents, and delete or promote the core-affirmation "proposals" to audit entries.**

---

## What is simple here, done right

**1. The AST-primary reframing (FOUNDATION foundational principle).**

"The AST is the value. The vector is its cached algebraic projection. The literal lives on the AST node." That is one sentence. That sentence is the whole paper. Every downstream consequence — `atom-value` is field access, not cleanup; `get` walks the tree, not the vector; the cache is memoization, not a codebook — is a consequence, not a design. Good work rides consequences. This does.

The inversion of classical VSA (vector primary, structure derived) is the decomplection. Traditional VSA braids "what the thing is" into "what operations I can do to recover it." Separating these into "the AST tells me WHAT; the vector tells me HOW SIMILAR" is a clean cut, and once made, a lot of previously-hard VSA ergonomics (nested retrieval without cleanup noise, literals that survive deep structures, programs-as-thoughts) become trivial.

**2. Blend (058-002) as the weighted-sum primitive.**

One operation. Scalar-weighted binary addition. It generates six downstream stdlib forms through literal weight specialization. This is exactly the shape a primitive should have: minimum surface, maximum power. Option B (two independent weights) is the right choice — Option A would fail at Circular, and the negative-weight "complection" worry is just convention, not algebra. Negative weights are fine; the math doesn't care what humans name the operation.

**3. Orthogonalize (058-005) as distinct from Blend.**

The computed-coefficient argument is correct and important. The coefficient `(X·Y)/(Y·Y)` depends on the encoded vectors, not on literals at AST construction. That is the operational axis that makes Orthogonalize categorically different from any literal-weighted Blend, and the proposal names it honestly. Good. Keep the name `Orthogonalize` over `Reject` — "orthogonal to Y" describes what it produces; "Reject" describes one use. Names should describe what the thing IS, not what it's being used for today.

**4. The split of the old multi-mode Negate into three distinct things.**

Orthogonalize to core (computed weight), Subtract to stdlib (literal -1), Flip to stdlib (literal -2). That is good classification work. The original Negate with a `mode` string argument was exactly the kind of "three concerns braided into one form by a convenience switch" that Hickey's lens flags. Untangling it was the right call.

**5. Bundle's list-only signature (058-003).**

Correct. Variadic is an easy-looking convenience that complects the common case (composition over `map`/`filter` results) with a minority case (literal args). List-taking is what Bundle IS — a reducer over a list of thoughts. The Lisp tradition of variadic for arithmetic-over-atoms does not apply to list-reducers; `reduce`, `map`, `filter` take lists, and Bundle is in that family. Lock it.

**6. The cache-as-working-memory reframing (FOUNDATION "The Cache Is Working Memory").**

Naming matters. "Cache" and "working memory" are the same mechanism at different levels of description. Promoting the description from engineering detail to cognitive substrate is right — it forces the architect to reason about what the thing IS for the system, not just about how fast it is. This will pay off when L3 engram caches start interacting with L1/L2 thought caches under real workload.

---

## What is complected

**1. The `(get structure locator)` function has TWO inconsistent definitions in the 058 documents.**

FOUNDATION.md (line 1778) says `get` is AST-walking: find the matching entry in the Map or Array AST and return its value AST. No cleanup. No cosine. "The literal stays on its AST node." That's the foundational principle's consequence, and it is simple.

058-016-map and 058-026-array define `get` and `nth` as **cleanup-based vector operations**:

```scheme
(define (get map-thought key candidates)
  (cleanup (Unbind map-thought key) candidates))
```

These are different operations with different failure modes. One walks the tree (exact, typed, cheap). The other projects, unbinds, and does similarity-based retrieval (noisy, requires a codebook, cost scales with the codebook). They are not interchangeable. They are not even the same category of operation.

This is a concrete complection: the sub-proposals collapsed "retrieve by locator" into a single name across two distinct mechanisms. Decision needed before commit: is `get` the AST walker or the vector operator? Pick one. Name the other something else. A reader who sees `(get structure key)` should not have to know whether `structure` is "the AST I'm holding" or "a vector I decoded from somewhere" to predict the operation's cost and correctness.

**Recommendation:** `get` walks the AST (matches FOUNDATION, matches the foundational principle, matches the typical use case where the caller has the AST). The vector-decode operation is a different name — something like `decode-field` or keep it as the explicit `(cleanup (Unbind ...) candidates)` composition. Don't hide the cleanup-plus-codebook cost behind a name borrowed from AST-level retrieval.

**2. The `Thermometer` signature is contradictory across FOUNDATION, 058-023, and 058-008.**

- FOUNDATION.md line 1640: `(Thermometer value min max)` — three numeric arguments, encoding a scalar value within a range.
- 058-023 and RUST-INTERPRETATION.md: `(Thermometer atom dim)` — an atom anchor and a dimension count, encoding a gradient.
- 058-008 Linear and 058-018 Circular: `(Thermometer low-atom dim)` — matches 058-023.
- HYPOTHETICAL-CANDLE-DESCRIBERS.wat: `(Thermometer (:close c) 0 100)` — matches FOUNDATION.

These are fundamentally different primitives. One encodes a scalar value in a range (FOUNDATION's form). The other encodes a seeded gradient vector addressable by an atom (058-023's form). They produce different vectors, serve different purposes, and cannot substitute for each other.

This is undiscovered complection — two distinct primitives carrying the same name because the documents diverged without a reconciliation pass. Before commit, the signature must be chosen:

- If Thermometer is `(value, min, max)`, it is a scalar-to-gradient primitive and Linear/Log/Circular reframings in 058-008/017/018 need rewriting (they currently pass `(atom, dim)`).
- If Thermometer is `(atom, dim)`, it is a seeded-gradient primitive and FOUNDATION's Linear/Circular stdlib definitions need rewriting, and some other primitive is missing for direct scalar encoding.

**Recommendation:** `(Thermometer value min max)` as in FOUNDATION, because that captures the intent — gradient encoding of a specific scalar value in a range. The "atom + dim" form in 058-023 is confusing Thermometer with Atom; the two primitives were already distinct and 058-023's version collapses them. Either fix 058-023 or rewrite FOUNDATION. You cannot keep both.

**3. The `Array` expansion is defined two different ways inside FOUNDATION itself.**

- FOUNDATION lines 1764-1771: `(Array items) = (Bundle (map-indexed (lambda (i item) (Bind (Atom i) item)) items))` — position-as-integer-atom-binding.
- FOUNDATION line 2158: `(Array items) — indexed list (Sequential alias)`.
- 058-026-array: `(define (Array thoughts) (Sequential thoughts))` — the Sequential alias.

These are different encodings. The Bundle-of-Binds-to-integer-atoms form gives O(1) random access via Unbind (you know the integer key). The Sequential form (Bundle of positionally-permuted items) gives O(1) access via Permute with a known step. They produce different vectors. The `nth` accessor works differently in each — one uses Unbind, the other uses Permute-then-cleanup.

**Recommendation:** pick one. The Bind-to-integer-atom form (FOUNDATION section lines 1764-1771) is strictly simpler and more useful: it gives exact retrieval via Unbind against the integer key atom (assuming typed-literal atoms land per 058-001, which they will), and it does NOT require cleanup against a codebook. The Sequential alias form (058-026) requires cleanup against a candidate set, which is noisier and more expensive. Take the Bind-to-integer-atom form. Delete 058-026's Sequential aliasing, keep 058-026's name-and-intent but rewrite its expansion. Or delete Array entirely and let users write Map with integer keys — same vector, one fewer name.

**4. The Bundle-alias triplet: `Bundle`, `Concurrent`, `Set`.**

All three have the exact same expansion — `Bundle(xs)`. They produce the same vector. They have the same cache-collision question (separate cache entries for identical vectors under different AST shapes). The proposals (058-010, 058-027) defend them on "reader intent" grounds: Bundle is the primitive, Concurrent means "at the same time," Set means "unordered collection."

Reader intent is a legitimate stdlib criterion. FOUNDATION's own stdlib bar admits "reduces ambiguity for readers" as sufficient justification. But three names for one operation is still three names for one operation, and the "three reader intents" argument is thin:

- `Bundle` is the primitive invocation.
- `Concurrent` says "these things happen together."
- `Set` says "these things are a collection."

How often does vocab code need to distinguish "temporal co-occurrence" from "unordered collection" in a way that Bundle with a comment cannot capture? The honest answer is: rarely, and where it matters, the enclosing context (the binding that wraps the bundle) carries the semantic. `(Bind (Atom "observed-at-t1") (Bundle [rsi price volume]))` already communicates "these are concurrent observations." Adding `Concurrent` just moves the word from the enclosing context into the form name.

**Recommendation:** keep ONE stdlib Bundle-alias at most. `Set` if you want the data-structure framing; `Concurrent` if the temporal intent dominates your vocab. Do not keep both. And do not hide that these are all `Bundle`.

**5. `Subtract` and `Difference` are the same operation with two names.**

Both expand to `Blend(a, b, 1, -1)`. 058-004 and 058-019 both concede this openly, then defend keeping both on reader-intent grounds (noun vs imperative, delta vs removal). The defense is thin. In vocab code, a reader will pick the name that sounds good in context; readers who haven't memorized which is which will just pick one. The claim that readers gain information by the choice is unsubstantiated.

**Recommendation:** pick `Subtract`. It is imperative, it aligns with holon-rs's existing `subtract`, it reads directly as the operation. `Difference` is a noun for the RESULT; the naming convention in most Lisps is to name the operation by its verb. Delete the `Difference` stdlib alias. Use `Subtract` in `Analogy`'s definition. Save the name `Difference` for cases where "the delta between two observations" has its own semantics (it doesn't here).

**6. `Unbind` as a stdlib alias for `Bind`.**

058-024 argues Unbind names a decode intent distinct from Bind's encode intent. For bipolar vectors the math is identical; only the reader context differs. The proposal concedes: "two names for one operation (at bipolar input)." The defense ("the redundancy is accepted; the clarity gain exceeds the redundancy cost") is a punt.

This is borderline. Unlike Subtract/Difference (genuinely the same intent in different grammatical dress), Unbind does carry real information: it says "I am decoding, not encoding." That distinction shapes how a reader predicts code behavior even when the math is identical. For learned engram libraries and for the future non-bipolar case, Unbind may diverge from Bind operationally.

**Recommendation:** keep Unbind. This is the one alias that earns its keep — the operational context is stable enough to warrant a distinct name, and reserving the name for future non-bipolar divergence is good forward-planning. Document that `Bind` and `Unbind` are mathematically identical TODAY for bipolar inputs, not philosophically identical. Name them as what they DO, not as what they currently compute.

**7. `Array` aliasing `Sequential` (covered above in complection #3, but also a naming complection).**

Even if the expansion question gets resolved, the naming question remains: do `Array` and `Sequential` serve different reader intents that warrant two names? Same argument as Set/Concurrent — the intents overlap, and the data-structure-vs-temporal framing lives in the surrounding context, not in the form name.

**Recommendation:** pick `Array`. It is the common data-structure vocabulary; readers know what it means. `Sequential` is vague in programming contexts (is it a list? a pipeline? an ordering hint?). Use `Array` as the one ordered-list form, and use comments or enclosing binds to mark temporal intent where needed. Delete `Sequential` as a stdlib name.

**8. `Set` (058-027) has no accessor — asymmetric with Map/Array.**

The proposal notes this and argues "similarity testing IS the accessor for Set." That is technically true but operationally handwaved. A vocab author reading Set's proposal gets: "to test membership, use cosine with a threshold." The threshold is unspecified, application-dependent, and the proposal defers it to "userland stdlib." That is incomplete — it leaves the primary use case (does this set contain x?) without a well-specified operation.

**Recommendation:** either (a) give Set a `member?` stdlib with a documented default threshold and a caveat that the threshold is application-knob-tunable, or (b) remove Set entirely and let users write `Bundle` with whatever cosine threshold they need. The current midpoint ("Set exists but doesn't give you a first-class way to use it") is the worst of both.

---

## What is easy-pretending-to-be-simple

**1. "Reader intent" as a justification for alias proliferation.**

FOUNDATION's stdlib criterion is: "Its expansion uses only existing core forms AND it reduces ambiguity for readers." The second clause is where easy creeps in. Every one-line stdlib alias can claim it "reduces ambiguity for readers" because it introduces a name that didn't exist. Once you accept this as the bar, the stdlib grows indefinitely — every time someone wants a name, they write a one-line `define`, argue reader intent, and the name lands.

The batch has four Bundle-aliases (Bundle, Concurrent, Set, and Sequential's Bundle-of-Permute expansion), three names for the same Blend-with-(1,-1) weighting (Difference, Subtract, Amplify(_, _, -1)), and a doubled ordered-list form (Sequential, Array). These are the early symptoms.

**The Hickey-ian test is stricter than the proposals write it:** does the name communicate something the reader does not already get from the context? For Bundle vs. Concurrent, the answer is usually no — the enclosing context tells you whether these things are concurrent or just bundled. For Difference vs. Subtract, the answer is no — same math, indistinguishable in reader use. For Bind vs. Unbind, the answer is actually YES — the decode context is stable information that shapes reader expectations.

**Apply the stricter test.** Keep names that carry stable operational information. Delete names that just rename the same operation. The test is not "can I defend this name on some grounds"; it is "does a reader who doesn't know this name lose something when they see the expansion."

**2. Keyword-path naming as a substitute for namespaces.**

"No namespace mechanism — slashes in keyword names are just characters." This is defended on simplicity grounds: keywords are first-class, slashes are valid characters, no new machinery is needed. That is simple in the compiler-mechanics sense. It is not simple in the program-comprehension sense.

When `:wat/std/Difference`, `:alice/math/clamp`, and `:project/market/analyze` are all "just keywords," the reader has no tooling to ask "what namespace does this symbol live in?" because the language refuses to answer. Collision is detected at startup (good), but every other namespace question — "who owns this prefix? what's in `:alice/math/*`? can I replace `:project/*` with `:other-project/*` without rewriting every callsite?" — is deferred to "discipline."

This is the "classes doing what maps should do" mistake running backwards. The proposals say: "we don't need a namespace mechanism, keywords can do it." But keywords are an inferior namespace mechanism — no introspection, no aliasing, no rebinding. The proposals rename "namespace mechanism" to "keyword naming discipline" and claim to have simplified.

**Recommendation:** either accept that there is no namespacing at all (fine for a small language; say so plainly; stop calling the keyword prefix a "namespace") or build a minimal namespace mechanism (import aliases, at least, so a caller can rebind `:wat/std/Difference` as `my-diff` locally). Don't pretend a convention is a mechanism. That's easy-disguised-as-simple.

**3. "Programs are thoughts" as a design claim vs. an operational claim.**

FOUNDATION spends multiple pages on "Programs ARE Thoughts" — programs encode to vectors, discriminant-guided program synthesis, the machine writes its own replacements, etc. Some of this is a genuinely load-bearing consequence of the algebra (programs compose, values compose, both can be hashed and signed). Some of it is speculative ("the machine writes its own candidate replacements through algebraic decoding of learned geometric directions against a library of candidate program structures").

The operational claim — "a `define` body produces a ThoughtAST which encodes deterministically to a vector" — is true and load-bearing. The speculative claim — "self-improvement becomes discriminant-guided program synthesis in hyperdimensional space" — is aspirational, requires the reckoner/subspace machinery FOUNDATION doesn't yet specify, requires a codebook of candidate program ASTs that doesn't yet exist, and requires evidence that decoded discriminants actually produce executable programs.

Both claims are defensible. They should be separated. Putting the aspirational claim in the same document as the criterion for core/stdlib classification makes FOUNDATION harder to use as a reference, because a reader cannot easily tell which parts constrain 058's 30 sub-proposals and which parts are future-work projection. **Recommendation:** move the speculative material to a companion document ("VISION.md" or similar) so FOUNDATION stays a reference for the algebra's actual commitments.

**4. The "signed ASTs prevent injection" story is under-hammocked.**

FOUNDATION argues at length that eval is safe because user input is treated as data unless explicitly `eval`'d. Then it argues that `eval` itself is safe because it checks every function against the static symbol table. Then it notes that `cleanup` results passed to `eval` could be steered by attackers. Then it concludes the attack surface is bounded.

This is three layers of reasoning where one slip compromises the whole argument. The proposal is correct in the end — a constrained `eval` over a static symbol table IS a reasonable trust model — but the FOUNDATION presentation layers the argument in a way that makes the actual security property hard to state precisely.

**Recommendation:** state the security property as one sentence. Something like: "After startup, the only code that runs is code registered in the static symbol table. Runtime `eval` can construct new ASTs, but those ASTs can only call functions in that table. Therefore: what the operator loaded at startup IS what runs." That sentence is the property. The rest is commentary. Don't let the commentary obscure it.

---

## What demands hammock

**1. The type system's generic syntax and nominal-vs-structural split.**

058-030 has `(deftype :wat/std/Option<:T> (:Union :Null :T))` — angle-bracket generics inside keyword-path names. Also `(deftype :wat/std/Option (:T) (:Union :Null :T))` as an alternative. Neither is resolved. Neither is particularly Lispy. The angle-bracket form imports C++/Rust/Java syntax into Lisp; the Lispy form is awkward for multiple generics.

Also unresolved: `struct` and `newtype` are nominal; `deftype` is structural; `enum` is coproduct. Why four forms? Do we need all four?

- `newtype` (nominal alias over existing type): strong safety benefit, like Rust/Haskell newtypes.
- `struct` (nominal product): standard.
- `enum` (coproduct with optional fields): standard.
- `deftype` (structural alias): overlaps with `newtype` in most uses; the only case for structural-vs-nominal is when you want shape-compatibility for ergonomics.

The proposals do not have a clear case where structural-only matters beyond readability. `(deftype :alice/types/Price :Scalar)` is a structural alias; `(newtype :project/trading/Price :Scalar)` is a nominal alias. Same syntax shape. Different semantics. Easy to confuse.

**Recommendation:** hammock on whether `deftype` earns its place alongside `newtype`. In Rust, `type` (alias) vs `struct X(T)` (newtype) serves both needs and the distinction is clear. Pick the minimum forms that give nominal safety for domain types and clean aliases for complex type expressions. Three forms (struct, enum, newtype) may be enough; the fourth (`deftype`) may be punted to "future, if needed."

**2. The core-affirmation "proposals" (021, 022, 023, 025).**

058-021 (Bind), 058-022 (Permute), 058-023 (Thermometer), 058-025 (Cleanup) are explicit affirmations. Each says: "this is already core; this doc exists for leaves-to-root completeness." Each asks Question 1 of itself: "is this proposal needed?"

The answer is: no, not as proposals. They are audit entries. They should not go through the designer-review process as if they were live decisions, because they aren't. They are documentation exercises that consumed review effort better spent on the actually-open questions (Blend signature, Thermometer signature reconciliation, Array expansion).

**Recommendation:** demote these four to a single `CORE-AUDIT.md` entry listing existing core primitives with their signatures and "already core, no change proposed" stamps. Free up designer attention for the active decisions. Proposals should be for things being decided; audit entries are for things being documented.

A side benefit: if Thermometer's signature contradiction gets noticed during the audit, it gets fixed as a single reconciliation rather than hidden inside a "proposal that affirms existing behavior."

**3. The cache-canonicalization question across ALL stdlib aliases.**

Every stdlib alias (Linear, Log, Circular, Sequential, Concurrent, Set, Array, Difference, Subtract, Amplify, Flip, Unbind) faces the same question: does the AST cache key on the stdlib form (preserve the semantic name) or on the expansion (canonical Blend/Bundle/Bind)?

The proposals defer this to "tooling decision, outside FOUNDATION." But it is actually a foundational decision. Two policies:

- **Preserve:** the AST's identity IS what the user wrote. Cache keys reflect names. Two names for one operation get two cache entries storing the same vector. Memory duplication; clearer AST inspection.
- **Canonicalize:** the AST's identity is the math. All stdlib forms normalize to their expansion before hashing. One cache entry per operation. Semantic name vanishes from AST walking.

The choice ripples through cryptographic signing (are `(Subtract a b)` and `(Blend a b 1 -1)` the same signed thought or different ones?), through cache efficiency, through AST inspection tools, through cross-node determinism.

**Recommendation:** hammock on this. One decision, applied uniformly to all stdlib aliases. Leaving it to "tooling" means each stdlib form makes its own choice de facto, which will produce inconsistency and subtle bugs. The choice probably: canonicalize. Two wat source forms that expand to the same primitive AST should hash to the same identity. Otherwise "code addressable by hash" becomes "code addressable by author's naming choice," and the distributed-verification story frays.

**4. `Ngram`'s parameter and edge cases.**

058-013 leaves `(Ngram 0 xs)`, `(Ngram 5 [a b c])`, and `(Ngram 2 [])` to "confirm conventions." That is under-hammocked for a form that generalizes Chain and sits inside the temporal-stdlib family. The edge cases have real operational consequences for any vocab module that feeds short sequences through Ngram.

**Recommendation:** specify. `n=0` is error. `n > length(xs)` returns an empty bundle (zero vector, or a specific "empty thought" sentinel if the algebra grows one). `xs = []` returns the same empty bundle. Document. Don't let operational edge cases live as "TBD."

**5. `:Function` type parametrics and `:Any` escape hatch.**

The type system admits `(:Function [args] return)` and `:Any`. Generic `:T` unification is mentioned but undetailed. Higher-order stdlib (`map`, `reduce`, `filter`) needs generics to type-check. `:Any` is "escape hatch" — the proposal says "document as last resort" but doesn't constrain its use.

Once `:Any` exists in a type system, it gets used for everything hard. Cleanup returns `(:List :Any)` because candidates are heterogeneous. Data-structure `get` returns `:Any` because the value type depends on the key. Pretty soon, most interesting functions return `:Any` and the type system's benefit (static verification at startup) disappears.

**Recommendation:** hammock on `:Any`. If the algebra needs it for `Cleanup` or other polymorphic primitives, restrict `:Any` to those specific positions (primitive-only, not user-authorable). User `define`s can only declare `:Any` with an explicit "I know what I'm doing" marker. Otherwise the type system slowly degrades into dynamic typing under startup-verification clothing.

**6. The `Analogy` argument order and relationship to Plate/Kanerva.**

058-014 argues `(Analogy a b c) = c + (b - a)` — "a is to b as c is to ?". Kanerva and Plate have different completions (circular convolution-based, binding-based). The proposal notes this as a question, doesn't resolve it. Vocab modules will write analogies expecting some convention; picking wrong creates subtle bugs.

**Recommendation:** pick the MAP-VSA completion (Bundle + Difference, as the proposal argues) and document why. Other VSA literature has different formulations because they use different primitives. Holon's MAP foundation makes the choice clean. Name it.

---

## Per-proposal verdict

| # | Form | Class | Verdict | One-line reasoning |
|---|---|---|---|---|
| 001 | Atom typed literals | CORE | ACCEPT | Type-aware hash is the right primitive generalization; types live on the AST. |
| 002 | Blend | CORE | ACCEPT | Pivotal and correct. Option B (two independent weights) is the right signature. |
| 003 | Bundle list signature | CORE | ACCEPT | Lock the list form. Variadic is easy, list-taking is simple. |
| 004 | Difference | STDLIB | REJECT | Redundant with Subtract (058-019). Pick one name; this one loses. |
| 005 | Orthogonalize | CORE | ACCEPT | Genuinely new operation; computed weight distinguishes it from Blend. Keep the name. |
| 006 | Resonance | CORE | ACCEPT-WITH-CHANGES | Accept core status. But formalize the ternary output kind; "treat zeros as bipolar" is a complection. |
| 007 | ConditionalBind | CORE | ACCEPT-WITH-CHANGES | Accept in principle. Consider whether `Select(x, y, gate)` is the cleaner primitive that makes ConditionalBind stdlib. Hammock. |
| 008 | Linear | STDLIB | ACCEPT-WITH-CHANGES | Reframing is correct. Fix the Thermometer signature contradiction first (see "What is complected" #2). |
| 009 | Sequential reframing | STDLIB | ACCEPT-WITH-CHANGES | End the grandfather. But resolve whether `Array` (058-026) and `Sequential` both survive — probably not. |
| 010 | Concurrent | STDLIB | REJECT | Bundle alias without distinct operational information. `Bundle` with surrounding context suffices. |
| 011 | Then | STDLIB | ACCEPT | Binary directed pair with Permute-1. Earns its name because the permutation count is a convention worth naming. |
| 012 | Chain | STDLIB | ACCEPT | Pairwise-Then composition; carries stable operational information distinct from Sequential. |
| 013 | Ngram | STDLIB | ACCEPT-WITH-CHANGES | Specify edge cases (`n=0`, `n>length`, empty list) before commit. Otherwise fine. |
| 014 | Analogy | STDLIB | ACCEPT-WITH-CHANGES | Pick and document the MAP formulation; resolve Difference/Subtract naming first. |
| 015 | Amplify | STDLIB | ACCEPT | Variable emphasis factor; earns a name distinct from Subtract (fixed -1) and Flip (fixed -2). |
| 016 | Map | STDLIB | ACCEPT-WITH-CHANGES | Accept Map. But redefine `get` as AST-walking, not as cleanup-based vector decode. See complection #1. |
| 017 | Log | STDLIB | ACCEPT-WITH-CHANGES | Same as Linear (058-008); fix Thermometer signature first. |
| 018 | Circular | STDLIB | ACCEPT-WITH-CHANGES | Same as above. Negative-weight test for Blend Option B is useful; keep it. |
| 019 | Subtract | STDLIB | ACCEPT | Primary name for `Blend(_, _, 1, -1)`. Delete Difference. |
| 020 | Flip | STDLIB | ACCEPT | `Blend(_, _, 1, -2)`; distinct from Subtract because the weight is non-obvious. |
| 021 | Bind | CORE | ACCEPT — demote to audit | Already core; this is an audit entry, not a proposal. |
| 022 | Permute | CORE | ACCEPT — demote to audit | Already core; audit entry. |
| 023 | Thermometer | CORE | UNCONVINCED | Signature contradicts FOUNDATION. Reconcile before accepting. |
| 024 | Unbind | STDLIB | ACCEPT | The one alias that earns its keep; decode intent is stable operational information. |
| 025 | Cleanup | CORE | ACCEPT — demote to audit | Already core; audit entry. Defer `Similarity + Argmax` split to future. |
| 026 | Array | STDLIB | REJECT IF ALIAS, ACCEPT IF BIND-INTEGER | If `Array = Sequential` (as proposal argues), reject — redundant. If `Array = Bundle(Bind(Atom i) item)` (as FOUNDATION argues), accept. Pick one encoding, reconcile. |
| 027 | Set | STDLIB | REJECT | Bundle alias; intent doesn't distinguish operationally. No accessor (asymmetric with Map/Array). |
| 028 | define | LANG CORE | ACCEPT | Required typed definitions are correct. |
| 029 | lambda | LANG CORE | ACCEPT | Required typed anonymous functions are correct. |
| 030 | types | LANG CORE | ACCEPT-WITH-CHANGES | Hammock generic syntax and `deftype`/`newtype` overlap (see "What demands hammock" #1). |

---

## Answers to the 178 questions (selected)

### 058-001 (Atom typed literals)

- **Q1 (typed hash soundness):** `(type_tag, literal_bytes)` is correct. Type-first, value-second. Bytes-only would collapse `(Atom 1)` and `(Atom "1")`, which breaks the foundational principle. Type first, always.
- **Q2 (one variant or distinct variants):** Option A — `Atom(AtomLiteral)` with internal tagging. ThoughtAST enum stays small; pattern matching destructures cheaply; adding future literal types is an AtomLiteral change, not a ThoughtAST change.
- **Q3 (Null as atom):** Yes, allow `(Atom null)` as a first-class atom. Holon's "no nil" tradition comes from absence-as-structure, which is a different concern. `Atom null` represents "the null value" as a literal; it has a deterministic vector; it is not the same as "absence of a bind." Keep both mechanisms.

### 058-002 (Blend)

- **Q1 (distinct source category):** Yes. Bundle is a monoid (associative, commutative, identity). Blend is a parameterized linear combination. Categorically different.
- **Q2 (Option A vs B):** Option B. Option A would force Circular to stay core, which is exactly the simplification Blend is meant to enable.
- **Q3 (negative weights):** Allow. The math is consistent. Readers don't have to understand negative weights; they use the named stdlib forms (Subtract, Flip) when negativity is the point.
- **Q4 (variadic temptation):** Stay binary. Variadic Blend would dissolve Bundle's monoid structure and shift MAP's canonical set. Not worth the ergonomic gain.

### 058-003 (Bundle list)

- **Q1 (list form ergonomic):** Yes, because real vocab code pipes from `map`/`filter` into Bundle. Literal arguments are the minority case.
- **Q2 (accept both as aliases):** Strict. Rejection of variadic at parse time. One form, one meaning.

### 058-004 (Difference)

- **Q1 (keep both or unify):** Unify. Pick one name. The reader-intent argument is thin when the math is identical.
- **Q2 (which one):** Subtract (058-019). Imperative verb, matches holon-rs's function name, reads directly. Delete Difference.

### 058-005 (Orthogonalize)

- **Q1 (core vs widened Blend):** Core. Widening Blend to accept computed weights changes its character (from "literal-weighted" to "AST-with-expressions-in-scalar-positions") significantly. That's a larger proposal; not worth entangling.
- **Q3 (Orthogonalize vs Reject):** Orthogonalize. The result IS orthogonal; that's the defining invariant. Name by the property, not the use.
- **Q4 (zero y):** Return `x` unchanged. Document explicitly.

### 058-006 (Resonance)

- **Q1 (ternary kind):** Formalize. Don't pretend zeros are bipolar. Downstream operations already handle zeros gracefully (cosine contributes 0; bind preserves 0); the formalization just names what's happening.

### 058-010 (Concurrent)

- **Q1 (synonym policy):** Reject all synonyms. Only one name per distinct intent.
- **Q5 ("Concurrent" as right word):** It's not, actually. In systems programming the word means race-condition-prone parallelism. But this is minor — if the form survives at all, the ambiguity is documentable. My larger view: delete Concurrent entirely.

### 058-013 (Ngram)

- **Q2 (edge cases):** `n=0` error. `n > length(xs)` empty-bundle. `xs = []` empty-bundle.
- **Q3 (Bigram/Trigram specialized):** Reject. Chain at n=2 is the common case with a short name; anything else uses Ngram.

### 058-016 (Map)

- **Q1 (duplicates):** Document non-dedup behavior. Don't automate.
- **Q2 (get variants):** Redefine `get` as AST walker (per complection #1). The cleanup-based variant is a different operation that needs a different name (`decode-field` or explicit `(cleanup (Unbind ...) codebook)`).

### 058-021-025 (core affirmations)

- **Q1 everywhere ("is this proposal needed"):** No. Demote to audit entries.

### 058-026 (Array)

- **Q1 (Array vs Sequential):** Pick Array, delete Sequential as a user-facing name. Reconcile the expansion ambiguity first.

### 058-027 (Set)

- **Q1 (alias acceptance):** Reject.
- **Q2 (accessor):** N/A — reject the form.

### 058-028 (define)

- **Q1 (name collision policy):** Strict halt. No `redefine`. Collisions are source-level problems.
- **Q2/Q3 (required types):** Required. Removes dispatch ambiguity; matches Model A's startup verification.
- **Q4 (forward references):** Support. The startup resolver runs after parsing, so forward references are natural.

### 058-029 (lambda)

- **Q1 (closure semantics):** Value-capture. Algebra is immutable; reference-capture adds no power and complicates reasoning.
- **Q2 (recursion):** Use `define`. Lambdas shouldn't self-reference; that's what named functions are for.

### 058-030 (types)

- **Q1 (generics scope):** Start with List and Function. Add more only when stdlib needs emerge.
- **Q5 (type promotion):** No implicit promotion. Explicit conversion functions.
- **Q8 (subtype hierarchy):** Yes, `:Atom <: :Thought`. An Atom passes wherever a Thought is accepted.

---

## Questions the proposals didn't raise

**1. What is a `Thought`, operationally?**

The type `:Thought` is "any ThoughtAST node" per 058-030. But ThoughtAST is an enum with 10 variants (Atom, Bind, Bundle, Permute, Thermometer, Blend, Orthogonalize, Resonance, ConditionalBind, Cleanup). When a function takes a `:Thought` parameter, it accepts all 10 variants, even though most functions only handle a subset usefully (e.g., `encode` cares about vector-producing variants; `atom-value` only works on Atom).

Hickey's lens: is `:Thought` the right type granularity, or should it be finer-grained (`:AtomicThought`, `:CompositeThought`) to match what functions actually consume? Same question Clojure answers with protocols — you have one type (`ISeq`) but with a refined contract, so callers can rely on specific behavior.

The 058 batch does not ask this. It should before `:Thought` becomes the type that 90% of stdlib signatures declare. Once the ergonomic pattern sets, it's hard to refine.

**2. How does a vocab module hand a typed literal Atom to a function that expected a string?**

`(define (f [a : Atom]) ...)` accepts any AtomLiteral (string, int, float, bool, keyword, null). But `(define (f [a : String]) ...)` accepts only strings. The proposals' relationship between Atom-of-X-literal and the primitive literal types is not specified.

Is `(Atom "foo")` a `:Atom` or a `:String`? Both, presumably, via subtyping. But how does the typechecker know? Inference on literal position? Explicit tagging? Elaboration rules?

This is implementation-level, but it ripples into the type system's expressiveness. Needs an answer.

**3. What happens to the cache when the algebra changes?**

The cache keys on ThoughtAST hash. If Blend lands as core, existing cached vectors computed under the old algebra (pre-Blend) get orphaned — same AST shape if it was a literal construction, but different if prior code used Linear/Circular as variants that Blend now replaces.

How does the cache handle algebra versioning? Is the cache identified by something like `hash(algebra-version, ast-hash)`? The distributed-verification story requires that cached vectors match re-encoded vectors across nodes, which means all nodes must be running the same algebra version simultaneously. Upgrade becomes a coordinated event.

The proposals don't address this. For a distributed substrate, it matters.

**4. What is the semantics of `encode` on an AST that references an unknown function?**

Constrained eval errors out. But `encode` on a ThoughtAST presumably does not call user functions — it walks the known 10 core variants. Or does it? What if a user-defined stdlib `(define (MyForm xs) ...)` produces a `ThoughtAST`? When does the user function execute, and when does the encoder dispatch?

The two-tier story (UpperCase constructs ASTs; encoder realizes via lowercase) breaks down slightly when stdlib user-defined UpperCase forms exist. A call to `(MyForm xs)` evaluates the `MyForm` body at wat-eval time (producing a ThoughtAST), then that ThoughtAST is passed to `encode` which walks core variants. But is `MyForm`'s body executed eagerly at each call, or is it cached? If the body references other user-defined forms, does the chain resolve lazily? These are core semantic questions unresolved by the proposals.

**5. Where does the algebra stdlib live — in the Rust binary or in wat source?**

FOUNDATION says stdlib is "wat functions" living in files like `wat/std/thoughts.wat`, loaded via `(load ...)` at startup. But the Rust-interpretation guide says some stdlib (Linear, Log, Circular, Sequential) currently exists as ThoughtAST variants. The proposals reframe these as stdlib but leave the implementation choice open ("remove the variants, keep as fast-paths, or deprecate").

This is a load-bearing decision. If stdlib lives in wat source, a deployed system must load wat/std files at startup — which means there's a bootstrapping story. If stdlib is Rust-builtin fast-paths with wat source as documentation, the "no Rust changes for stdlib additions" promise is weakened.

Hammock on this.

**6. What does the algebra do when similarity breaks down?**

Kanerva's bound at d=10k is ~100 items per frame. The proposals assume this will hold for typical use; the "dimensionality is a deployment knob" section acknowledges that over-capacity frames fail cleanup silently. But the proposals do not specify how a vocab module, encoding a Map with 150 keys, DETECTS that it has exceeded capacity.

This is the operator-experience question. The machine "just becomes less reliable" as capacity is exceeded. That is not observable from the vocab module's perspective. Should the algebra offer a `capacity-check` primitive? Should the encoder log warnings? Should over-capacity be a type-level concern (some `:BoundedMap` type that caps at N)?

Not addressed. Will bite in production.

**7. Who owns the lowercase primitives?**

FOUNDATION says lowercase `atom`, `bind`, `bundle`, `cosine`, `permute`, `blend` are Rust primitives callable from wat. UpperCase forms construct ASTs that realize via these lowercase operations. But the lowercase set is not enumerated anywhere in the 058 documents with its own criterion or classification. Are they language core? Algebra core? Neither? Both?

The Two Tiers section describes the relationship but doesn't place the lowercase forms in the algebra/language classification. That is a gap — if lowercase `bind` is algebra core, does it need its own proposal? (058-021 is about the UpperCase `Bind` — they share an AST variant but serve different tiers.) If lowercase `bind` is something else (host-inherited? Rust-bridge? implementation detail?), where does that category live?

The proposals are silent. Someone needs to write the lowercase classification and bolt it to FOUNDATION.

---

## Final note

The batch's best move is the AST-primary reframing. The second-best is Blend as pivotal primitive. Those two carry the weight.

The worst moves are the alias proliferation (Set/Concurrent/Bundle, Array/Sequential, Difference/Subtract) and the unresolved signature contradictions (Thermometer, Array, `get`). All of these are fixable before commit. None require rework of the core insight.

Core affirmations (021/022/023/025) should be demoted to audit entries. That change alone would sharpen the designer-review focus.

Model A is correctly scoped as a host-level constraint, not an algebraic invariant. Keep that honesty.

The proposals that make me nervous are not the ones I marked REJECT — those are easy to delete. The ones that need hammocking are the type system (058-030) and the cache canonicalization question that spans twelve stdlib proposals without resolution. Those rabbit-holes want another session in the hammock before code lands.

The algebra here is real, and the insight is real. The commitments aren't yet as clean as the insight deserves. Tighten them.

---

*Review completed 2026-04-18, applying the Hickey lens.*
