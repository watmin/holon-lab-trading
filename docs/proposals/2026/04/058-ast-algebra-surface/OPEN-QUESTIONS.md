# 058 — Consolidated Open Questions for Designers

**Purpose:** single-scan sheet of every designer-facing question across the 29 sub-proposals. Audited primitives (Bind, Permute, Thermometer) have no open questions — see `CORE-AUDIT.md`. FOUNDATION's own Open Questions (Q1–Q7) and their resolutions live in `FOUNDATION.md` (`## Open Questions`).

**Generated from:** sub-proposals' "Questions for Designers" sections. Since Round 2 many have been resolved by architectural decisions recorded in `FOUNDATION-CHANGELOG.md`; the ones needing designer input are summarized below.

---

## Live questions for Round 3

The substantive decisions that still need designer opinions — everything else in this document is either RESOLVED (marked inline), MOOT (in a REJECTED proposal), or documentation-only.

**058-005 Orthogonalize.**
- **Q1** Orthogonalize as core vs. widened Blend with computed weights?
- **Q2** Should `Project` also be proposed first-class (the complement)?
- **Q3** Name: `Orthogonalize` or `Reject`? (Holon's existing name is `reject`.)

Everything else in this document is RESOLVED inline (with a pointer to the resolution source), MOOT (in a rejected proposal), or documentation-only (the recommendation IS the resolution).

---

## 058-001: Atom — ACCEPTED (parametric)

**All questions in this section are RESOLVED.** Atom accepts into core as `:Atom<T>` — parametric over any serializable T (primitive, composite `:Holon`, user-defined struct/enum/newtype). Substrate-level decision: without parametric Atom, programs cannot be atomized, which breaks FOUNDATION's "Programs ARE Holons" principle. See 058-001/PROPOSAL.md's ACCEPTED banner for the per-question reasoning, and FOUNDATION-CHANGELOG 2026-04-18 entry "Parametric polymorphism as substrate — programs ARE atoms, which demands it."


---

## 058-002: Blend — ACCEPTED

**All questions in this section are RESOLVED.** Blend enters algebra core as `(:wat/algebra/Blend a b w1 w2)` — two independent real-valued scalar weights (Option B), negative weights allowed, binary arity. See 058-002/PROPOSAL.md's ACCEPTED banner for the per-question reasoning, and FOUNDATION-CHANGELOG 2026-04-18 entry "Blend keystone closed." Designer review may still reopen in Round 3.


---

## 058-003: Bundle — List Signature

1. **Is the list form the right ergonomic tradeoff?** List-taking composes cleanly with `map` and `filter`, but requires `(list ...)` for literal cases. Does this serve the common use case well, given that vocab modules almost always generate Bundle inputs via list-producing operations?

2. **Should the parser accept both forms as aliases?** Lenient parsing would accept `(Bundle a b c)` and internally wrap into `(Bundle (list a b c))`. Strict parsing would reject variadic form. Lenient is user-friendly; strict preserves the one-form-one-meaning principle.

3. **Does this constrain future extensibility?** If we ever wanted Bundle to take additional parameters (e.g., `(Bundle list options)` for hypothetical parameterization), would the list-taking form make that addition awkward? Probably not — options could be a map parameter, same pattern as `Ngram n list`.

4. **Other list-operating forms.** Sequential, Concurrent, Chain, Ngram, Array, Set, Map — do all of them follow the list-taking convention, and is this proposal implicitly locking the convention across all of them? FOUNDATION.md uses the list form throughout; this proposal formalizes it.

5. **Is this worth its own proposal?** The change is small (documentation + possible parser strictness). Could have been bundled into a broader "wat form conventions" proposal. Arguments for its own proposal: the ambiguity was visible enough to be worth a named decision; the designers should review the form convention explicitly rather than having it slide in with other changes.

---

## 058-004: Difference — REJECTED

**All questions in this section are MOOT.** 058-004 was rejected — same math as Subtract, no new pattern demonstrated; `:wat/std/Subtract` (058-019) is the canonical delta macro. See FOUNDATION-CHANGELOG for the rejection record. Designers need not opine.


---

## 058-005: Orthogonalize

1. **Orthogonalize as core vs. widened Blend with computed weights.** The trade-off: Orthogonalize as its own variant (concrete, focused) vs. Blend with expression-valued weights (unifies but widens scope). Which is the right level of generality?

2. **Should `Project` also be proposed?** Related operation — the projection itself, rather than the complement. Can be stdlib (`Project = x - Orthogonalize(x, y)`), but some applications want the projection directly. Worth a first-class form, or let stdlib handle it?

3. **Naming: `Orthogonalize` or `Reject`?** Holon calls this operation `reject` (rejection of y's component from x). "Orthogonalize" describes what the result IS (orthogonal to y); "Reject" describes what the operation DOES (rejects y's component). Which name serves the wat reader better?

4. **Handling of zero-magnitude y.** If `y` is the zero vector, `Y·Y = 0` and the projection coefficient is undefined. The implementation must handle this edge case — probably by returning `x` unchanged (nothing to project out). Should this be explicit in the semantics?

5. **Classification reconsideration.** This sub-proposal NARROWED the original Negate proposal to just the orthogonalize mode. Subtract mode went to 058-019-subtract, flip mode went to 058-020-flip. Is this the right split, or should Negate have been preserved as a single multi-mode core form?

---

## 058-006: Resonance — REJECTED

**All questions in this section are MOOT.** 058-006 was rejected — speculative primitive with no cited production use beyond unit tests. Sign-agreement masking is a three-primitive composition over existing core forms (threshold + Bind). When real use demands it, propose with concrete application evidence or the refined `Mask(x, boolean)` abstraction. See FOUNDATION-CHANGELOG for the rejection record. Designers need not opine.


---

## 058-007: ConditionalBind — REJECTED

**All questions in this section are MOOT.** 058-007 was rejected — speculative primitive with no cited production use. Half-abstraction — consumes a gate without proposing how to derive one from a role atom. Classical functional update in VSA uses Subtract + Bind + Bundle, all already in core/stdlib. See FOUNDATION-CHANGELOG for the rejection record. Designers need not opine.


---

## 058-008: Linear — REJECTED

**All questions in this section are MOOT.** 058-008 was rejected — identical to Thermometer under the 3-arity signature `(Thermometer value min max)`; no new pattern beyond the existing core primitive. See FOUNDATION-CHANGELOG for the rejection record. Designers need not opine.


---

## 058-009: Sequential — ACCEPTED (reframed)

**All questions in this section are RESOLVED.** Sequential is stdlib with a **bind-chain** expansion (not the original bundle-sum) — `(Sequential [a b c]) = Bind(Bind(a, Permute(b, 1)), Permute(c, 2))`. Matches the primer's "positional list encoder" idiom and the trading lab's `indicator_rhythm` production pattern. The `map-with-index` dependency dissolves (bind-chain uses a left-fold); other questions resolved via 058-031 defmacro. See 058-009/PROPOSAL.md's ACCEPTED banner.


---

## 058-010: Concurrent — REJECTED

**All questions in this section are MOOT.** 058-010 was rejected — no runtime specialization, no corresponding type annotation, purely reader-intent; temporal-co-occurrence is carried by the enclosing context, not by a named alias of Bundle. See FOUNDATION-CHANGELOG for the rejection record. Designers need not opine.


---

## 058-011: Then — REJECTED

**All questions in this section are MOOT.** 058-011 was rejected — arity-specialization of Sequential; demonstrates no new pattern. Chain (058-012) inlines the binary Sequential directly rather than depending on Then. See FOUNDATION-CHANGELOG for the rejection record. Designers need not opine.


---

## 058-012: Chain — REJECTED

**All questions in this section are MOOT.** Chain was rejected — redundant with Bigram (new named stdlib form in 058-013's reframe). `Chain xs` = `Ngram 2 xs` = Bigram. See 058-012/PROPOSAL.md's REJECTED banner and FOUNDATION-CHANGELOG 2026-04-18 entry.


---

## 058-013: Ngram — ACCEPTED (reframed + ships Bigram/Trigram)

**All questions in this section are RESOLVED.** Ngram is stdlib. The 2026-04-18 reframe ships three macros: `Ngram` (general), `Bigram` (= Ngram 2), `Trigram` (= Ngram 3). Uses the reframed bind-chain Sequential (058-009). Users extend for higher n in their own namespace. Matches the trading lab's `indicator_rhythm` pattern exactly. See 058-013/PROPOSAL.md's ACCEPTED banner.


---

## 058-014: Analogy — DEFERRED

**All questions in this section are MOOT under deferral.** Analogy is proven working (classical Kanerva A:B::C:?) but not currently adopted in any application in this workspace. Proposal preserved as a resumable audit record — future proposal re-argues with application-citation evidence. Not shipping in 058. See 058-014/PROPOSAL.md's DEFERRED banner and FOUNDATION-CHANGELOG 2026-04-18 entry.


---

## 058-015: Amplify

1. **`s = 1` degeneracy.** `(Amplify x y 1)` ≡ `(Bundle [x y])`. Should Amplify document this, or restrict `s ≠ 1`? Recommendation: document, don't restrict.

2. **Negative `s` overlap with Subtract / Flip.** `(Amplify x y -1)` ≡ `(Subtract x y)`, `(Amplify x y -2)` (formerly proposed as the stdlib `Flip`, now REJECTED). Recommendation: freely allow overlap; stylistic preference picks the most specific name.

3. **Attenuation variant?** Some applications want "reduce `y`'s contribution" specifically (`0 < s < 1`). Could be a named variant `Attenuate` for clarity. Recommendation: no — avoid further proliferation. `(Amplify x y 0.5)` suffices; if users want a name for attenuation they can define their own stdlib alias.

4. **Dependency on Blend.** If 058-002 rejects, Amplify cannot exist. Resolution order: Blend first.

5. **Related trading-domain idioms.** In holon-lab-trading, the manager aggregates observer opinions — an Amplify pattern (observer X is weighted higher based on its conviction). Does this vocab fit Amplify cleanly? Concrete usage would validate the form.

---

## 058-016: Map

1. **Duplicate keys.** `(Map [[:a 1] [:a 2]])` produces noisy cleanup for key `:a`. Document the behavior as "Map does not deduplicate; pre-filter if needed," or add an automatic deduplication pass? Recommendation: document, don't automate.

2. **Accessor variants.** `get` (with cleanup) vs `get-raw` (without). Both useful. Keep both with these names? Or use `get` for raw and `get-cleanup` for the cleanup variant? Recommendation: `get` is the common case (with cleanup); `get-raw` for the raw case.

3. **Key type constraints.** — **RESOLVED.** Keys can be any `:Holon` value. Typed Atom literals (058-001) include string/int/float/bool/keyword; composite ASTs (Bind, Bundle, etc.) also work as keys because `:Holon` is the substrate's universal type. `:HashMap<K,V>` at declaration time pins the key type; runtime hash lookup (Rust `std::collections::HashMap`) handles any hashable key.

4. **Performance for large Maps.** Bundle's capacity is bounded (~d / ln(K) items for reliable cleanup). Maps with many keys exceed capacity and produce noisy retrieval. Document the capacity bound; stdlib could provide a `LargeMap` variant using partitioning if demand arises.

5. **Nested Maps.** `(Map [[:user (Map [[:name "alice"] [:age 30]])]])` nests dictionaries. `get`s compose: `(get (get root :user cb) :name cb)`. Or a `deep-get` stdlib variant for path-based access. Out of scope for this proposal but worth noting as a likely next stdlib addition.

6. **Empty Map.** `(Map [])` produces an empty Bundle — an all-zeros or undefined vector. Document the degenerate case or forbid it.

7. **Dependency ordering.** Map depends on Bundle and Bind (both core). `get` depends on Unbind (058-024) and Cleanup (058-025). If any prerequisite is rejected, Map and its accessors change. Explicit dependency statement: this proposal assumes all four primitives are available.

---

## 058-017: Log — ACCEPTED

**All questions in this section are RESOLVED.** Log is stdlib macro over Thermometer with log-transformed inputs: `(Thermometer (ln value) (ln min) (ln max))`. Concrete production evidence — at least 15 uses across the trading lab's vocab (`vocab/market/oscillators.rs` ROC-1/3/6/12, `vocab/market/momentum.rs` atr-ratio, `vocab/market/keltner.rs` bb-width, `vocab/market/price_action.rs` range-ratio and consecutive-up/down, `vocab/exit/regime.rs` variance-ratio, `vocab/exit/trade_atoms.rs` eight exit-vocab uses). See 058-017/PROPOSAL.md's ACCEPTED banner for per-question resolution.


---

## 058-018: Circular — ACCEPTED

**All questions in this section are RESOLVED.** Circular is stdlib macro over Blend (Option B — which is why Circular is the proof case for independent weights, since `cos(θ)+sin(θ)≠1`). Concrete production use in `vocab/shared/time.rs` — all five cyclic time components (`minute`/`hour`/`day-of-week`/`day-of-month`/`month-of-year`) plus three pairwise compositions. Every broker thought carries these facts. See 058-018/PROPOSAL.md's ACCEPTED banner for per-question resolution.


---

## 058-019: Subtract

1. **Subtract vs Difference: keep both or unify?** — **RESOLVED.** 058-004 Difference REJECTED (no new pattern; same math as Subtract). Only `:wat/std/Subtract` exists. See FOUNDATION-CHANGELOG 2026-04-18 stdlib macro audit entry.

2. **Naming: `Subtract` or `Remove`?** "Subtract" has mathematical connotations; "Remove" has more direct intent ("remove the noise"). Recommendation: keep `Subtract` — aligns with holon-rs's `subtract` function; readers recognize it.

3. **Imperative `Subtract!` variant for in-place?** In some languages, exclamation suffix denotes mutation. Here all operations are pure (ASTs are immutable). Irrelevant, noted for consistency.

4. **Dependency on 058-002-blend.** If rejected, Subtract re-proposes as core (it is one of the three original Negate modes, per FOUNDATION's history). Resolution order: Blend first.

5. **Subtract's relationship to Orthogonalize (058-005).** Subtract removes `y` linearly. Orthogonalize removes `y`'s DIRECTION proportionally. Different operations, different invariants. Subtract is stdlib; Orthogonalize is core (has a computed weight). Documentation should make the distinction explicit to avoid confusion.

---

## 058-020: Flip — REJECTED

**All questions in this section are MOOT.** 058-020 was rejected for three reasons: (1) the primer's `flip` is single-arg elementwise negation, not the proposal's 2-arg Blend idiom — same name, different operation; (2) the `-2` weight is a tradition-matching convention, not an algebraic minimum (any weight `< -1` produces the same thresholded result); (3) no cited production use beyond unit tests. The operation is trivially expressible inline as `(:wat/algebra/Blend x y 1 -2)` when needed. See FOUNDATION-CHANGELOG 2026-04-18 entry and 058-020/PROPOSAL.md REJECTED banner. Designers need not opine.


---

## 058-021, 058-022, 058-023 — Audited in CORE-AUDIT.md

Bind, Permute, and Thermometer are affirmed core primitives already present in holon-rs. The affirmation proposals had no open designer-facing questions — every entry was self-answering ("Is this proposal needed? … or is an audit entry sufficient?"). All three have been collapsed into `CORE-AUDIT.md`, which records operation, canonical form, MAP/VSA role, and downstream conventions. No open questions remain.

---

## 058-024: Unbind — REJECTED

**All questions in this section are MOOT.** 058-024 was rejected — identity alias for Bind — Bind-on-Bind IS Unbind, a fact about the algebra, not a name worth projecting. Simple, not easy. See FOUNDATION-CHANGELOG for the rejection record. Designers need not opine.


---

## 058-025: Cleanup — REJECTED

**All questions in this section are MOOT.** 058-025 was rejected — AST-primary framing dissolves the need for codebook-based recovery. Retrieval is presence measurement (cosine + noise floor); argmax-over-candidates is the caller's selection policy, not a substrate primitive. See FOUNDATION-CHANGELOG for the rejection record. Designers need not opine.


---

## 058-026: Array

1. **Array vs Sequential: keep both or unify?** — **RESOLVED.** Both stay. Array is renamed to `:wat/std/Vec` per the container-constructor-renaming decision (HashMap/Vec/HashSet share names with their Rust backings). Sequential is positional algebra encoding; Vec is an indexed container with O(1) `get` through Rust's `std::vec::Vec`. Distinct intents, distinct runtime semantics.

2. **Accessor naming.** `nth` is Lisp-idiomatic for positional retrieval. Alternative: `get-at`, `index`, `[]`-style operator. Recommendation: `nth` — matches Lisp tradition.

3. **Negative indices (from end).** Python-style `arr[-1]` for last element. Would require knowing the array length at retrieval time (not directly in the encoded AST without metadata). Explicit positive indices only, for now.

4. **Bounds checking.** `(nth arr 999)` when arr has 4 elements — what happens? Unbind-then-cleanup will return a noisy vector that may still match some candidate, producing an incorrect result. Document as user responsibility; consider a `nth-safe` variant that requires length metadata.

5. **Array length.** Can an encoded Array expose its length? Not directly — the length is not in the encoding unless deliberately added. A `(pair length array-ast)` pattern might be needed for bounds-checked access. Future work.

6. **2D Array (tables).** `Array` of `Array` works but is awkward. A first-class 2D table structure might be a useful stdlib addition later. Out of scope for this proposal.

7. **Dependency on 058-009-sequential-reframing.** If Sequential stays as a variant (reframing rejected), Array's definition unfolds to the expanded Bundle+Permute directly. Resolution order: 058-009 first, then this proposal aligns.

---

## 058-027: Set

1. **Alias acceptance.** Set is the third Bundle-alias (after Bundle itself and Concurrent). Accept the triple-alias for reader clarity, or consolidate to fewer names? Recommendation: accept; each has distinct intent.

2. **Accessor expectations.** Map has `get`, Array has `nth`. Should Set have a dedicated accessor? Proposal: no — similarity testing IS the accessor for Set. Document this asymmetry.

3. **Duplicates vs strict set semantics.** `(Set [:a :a :b])` is technically a multiset (duplicates superpose). Document as "Set does not deduplicate; pre-filter for strict set semantics." Add a `StrictSet` stdlib form only if demand emerges.

4. **Set size capacity.** Bundle's reliable-recovery bound is ~d/(2·ln(K)). For d=10,000 that's ~100 items. Document the limit; large sets use engram libraries instead.

5. **Relationship to `Group` / `Collection` / `Multiset`.** Are any of these distinct enough to warrant their own stdlib names? Recommendation: no — Set covers the data-structure intent; further aliases are redundant.

6. **Set operations (union, intersection).** In classical set theory, `A ∪ B`, `A ∩ B`, `A \ B` are primary operations. For Bundle-encoded sets:
   - Union: `(Set (concat A B))` or `(Bundle [A B])` — works cleanly
   - Intersection: `(Resonance A B)` — keeps dimensions where both sets align (per 058-006)
   - Difference: `(Orthogonalize A B)` or `(Subtract A B)` — removes B's contribution from A
   Worth noting as future stdlib idioms but out of scope for this proposal.

7. **Empty set.** `(Set [])` produces an empty Bundle — all-zeros or undefined vector. Document as degenerate case; callers should check for empty before encoding.

---

## 058-028: Define

1. **Name collision policy.** If two `define` calls in loaded files share a name, startup halts with an error. Is this the right policy, or should there be an explicit `(redefine ...)` form for intentional shadowing? Recommendation: strict collision error by default; explicit shadowing is a later addition if needed.

2. **Required-ness of return type.** Proposal requires return types. Alternative: infer from body (Scheme-style). Recommendation: keep required — removes evaluator ambiguity and makes the signature self-documenting.

3. **Required-ness of parameter types.** Same question. Recommendation: keep required for the same reason.

4. **Forward references.** Can `:wat/std/Chain` reference `:wat/std/Then` before Then is defined (e.g., in a single load pass)? Since all loading happens at startup before the symbol table freezes, forward references are natural: the resolver runs after all parsing but before type-checking. Recommendation: support forward references within the startup phase; they do not complicate Model A.

5. **Metadata / documentation strings.** Clojure's `defn` supports docstrings and metadata. Worth including in `define`'s AST shape? Recommendation: yes — optional metadata field. Docstrings help readers; metadata supports tooling.

6. **Anonymous functions via `lambda` (058-029).** `define` names a function; `lambda` creates an unnamed one. `define` can be viewed as `lambda` + startup-time symbol-table registration. Keep the primitives layered cleanly.

7. **First wat program.** From BOOK's "The first program" section:

   ```scheme
   (define (:watmin/hello-world [name : Atom]) : Thought
     (Sequential (list (Atom "hello") name)))
   ```

   This proposal specifies the `define` that makes that program runnable. The first program's execution waits on this proposal's implementation plus 058-029 and 058-030.

---

## 058-029: Lambda

1. **Closure capture semantics.** Value-capture (snapshot at creation) or reference-capture (see later mutations)? Recommendation: value-capture, consistent with FOUNDATION's "Algebra Is Immutable" section — nothing to mutate; snapshot suffices.

2. **Recursion in lambdas.** A lambda can't reference itself by name (no name). How to do recursion? Options: (a) force use of `define` for recursive functions, (b) support `Y` combinator pattern, (c) add a name-binding form like Clojure's `fn` with optional self-name: `(lambda self ([params]) : ReturnType body)` where `self` refers to the lambda itself. Recommendation: (a) — use `define` for recursion. Keeps lambda purely value-level without introducing self-reference complication.

3. **Higher-order parameter types.** `:fn(...)` types carry argument and return information. For stricter typing: `:fn(Holon,Holon)->Holon` (a function from two Holons to a Holon). Handled in 058-030-types.

4. **Brevity sugars.** Clojure's `#(...)` anonymous function shortcut. Python's `lambda x: expr`. Rust's `|x| expr`. Should wat have a shortcut? Recommendation: skip for now — the explicit form with types is the load-bearing primitive. Sugars can come later, expanding to full lambdas with inferred types.

5. **Free variables and captured environment.** If a lambda references a name not in its parameters or enclosing scope, what happens? Since the enclosing scope at startup is the global static symbol table, any reference resolves either locally, to a captured variable, or to a `define`. An unresolved reference is a type-check error at startup (for a `define` containing the lambda) or an eval error at runtime (for a lambda created by constrained eval). Recommendation: fail-fast at resolution.

6. **Serialization.** A lambda's AST serializes to EDN; its captured environment does not (captured values may be unencodable, large, or privacy-sensitive). Should lambda EDN include the captured env? Recommendation: no — EDN contains the lambda's AST only. Captured env is evaluator-runtime state, not part of the signed AST. A lambda serialized and sent over the wire CANNOT carry its closure; re-establishing closure context is a runtime concern at the receiver.

7. **Compiled form.** A frequently-called lambda could be JIT-compiled to native for speed. Out of scope for this proposal but worth noting; lambdas are natural JIT boundaries because they're self-contained ASTs.

---

## 058-030: Types

1. **Generics scope.** Is `:fn(args)->return` and `:List<T>` sufficient, or do we need variance, bounds (`T extends :Holon`), or existentials? Recommendation: start minimal — just List and fn parametrics. Add more if stdlib needs emerge.

2. **Type inference strength.** Parameter types on `define`/`lambda` are required. Should all intermediate expressions be inferred, or should `let` support optional type annotations? Recommendation: infer intermediates; allow optional `[let [[x : Thought] (Blend a b 1 -1)]]` for explicit annotation when helpful.

3. **Nominal vs. structural typing — RESOLVED 2026-04-18.** Nominal for `struct`/`enum`/`newtype`; structural for `typealias` (renamed from `deftype`). Four distinct head keywords, zero ambiguity at parse. `:is-a` removed; no nominal subtyping (polymorphism via enum wrapping, same as `:Holon`).

4. **`:Any` usage.** Was considered, rejected. Heterogeneous data uses named `:Union<T,U,V>` types; generic containers use parametric `T`/`K`/`V`; atom literals use `:AtomLiteral`. Resolved in the 2026-04-18 type-grammar sweep.

5. **Type promotion rules.** If a function takes `:f64` and you pass an `:i32`, does it auto-promote? Recommendation: no implicit promotion — explicit `(to-f64 int)` or similar. Matches Rust's strictness; prevents surprising behavior.

6. **Error reporting.** Type errors need to point at the offending expression with a useful message. "Expected :Holon, got :f64 at line X" is the minimum. Structured error types with source locations are part of the implementation.

7. **Metadata on types.** `typealias` could accept documentation strings, constraints, validators. Worth including in the first version? Recommendation: start simple (just alias); add metadata if needed.

8. **Subtype hierarchy — RESOLVED 2026-04-18.** No nominal subtyping. `:Holon` is an ENUM with 9 variants (Atom, Bind, Bundle, etc.). Functions on `:Holon` pattern-match to select variant. Same pattern as Rust's `match holon { HolonAST::Atom(lit) => ... }`. No `:is-a` keyword in the grammar.

9. **Dependency ordering.** Types depend on nothing; `define` and `lambda` depend on types. Resolution order: 058-030 (types) first, then 058-028 (define) and 058-029 (lambda).

10. **First-class types.** Types as keyword values can be passed around. Does this enable type-reflecting code? Probably, though not the focus of this proposal. Example: `(type-of x)` returns the keyword `:Thought`. Useful for introspection but out of scope for language core.

11. **Keyword-path in type names with generic parameters — RESOLVED.** Rust-surface angle-bracket keywords (`:wat/std/Container<T>`) as single tokens; tokenizer tracks bracket depth across `()`, `[]`, `<>`. `:fn(args)->return` uses parens + arrow (Rust-native function-type syntax). `:Option<T>` declared as enum with `:None` and `(Some (value :T))` variants — not a typealias, because it has distinct constructors.

---

## 058-031: defmacro

1. **Hygiene — RESOLVED.** The proposal ships with Racket-style sets-of-scopes hygiene (Flatt 2016). Every `Identifier` carries a `BTreeSet<ScopeId>`; the expander assigns a fresh scope per macro invocation; binding resolution uses `(name, scope_set)` pairs. Variable capture is structurally impossible, not discipline-enforced. The earlier "start unhygienic" recommendation was superseded — datamancer's call: "macro expansion must be safe... there's no way we can get rust to not be safe, right?"

2. **Recursion.** Can a macro invoke itself during expansion? Yes (standard Lisp). Expansion limit (e.g., 1000 recursive rewrites) prevents infinite loops. The fixpoint-until-no-macro-calls semantic handles this — a pathological macro that always emits a new macro invocation hits the limit and errors at startup.

3. **Typed macros — RESOLVED in 058-032.** Every macro parameter is `:AST<T>` with a concrete value type — same discipline as every other typed position in the language. Bare `:AST` without `<T>` is retired, matching 058-030's no-`:Any` rule. Macro-definition-time type checking runs before expansion; call-site checking names the parameter by its declared type. 058-031's initial draft called this deferred; 058-032 completes it.

4. **Introspection.** Should userland code be able to see what a macro call expands to? Useful for debugging. Recommendation: yes, via `(macroexpand form)` — returns the fully-expanded AST without evaluation. Classical Lisp feature. Not in 058-031's ship set; could land in a follow-up proposal when debugging tooling is built out.

5. **Signature-verification over expansion — RESOLVED via 058-031.** The hash used for cryptographic identity is on the EXPANDED AST (per FOUNDATION's Model A). Two semantically-identical source files that differ only in macro aliases produce the same expanded AST and the same hash. Source signatures are a separate concern (author identity vs. content identity).

6. **Stdlib aliases as macros — complete list, partial resolution.** 058-031 anticipated ~13-14 stdlib proposals changing from `define` to `defmacro`. Landed state:
   - **Accepted as macros**: 058-012 Chain, 058-013 Ngram, 058-014 Analogy, 058-015 Amplify, 058-019 Subtract, 058-016 HashMap, 058-026 Vec, 058-027 HashSet, 058-017 Log, 058-018 Circular, 058-009 Sequential (reframed). (058-020 Flip REJECTED.)
   - **REJECTED** (stdlib-as-blueprint test failed; no distinct pattern): 058-004 Difference, 058-008 Linear, 058-010 Concurrent, 058-011 Then, 058-024 Unbind, 058-025 Cleanup.
   - Users may define the rejected forms in their own namespaces as macros if they want the name.

7. **Provenance / versioning across distributed nodes — RESOLVED in 058-031.** See the "Provenance — Macro-Set Versioning and Distributed Consensus" section. Stdlib macros lock with the algebra version; user macros carry local provenance; distributed consensus operates on expanded ASTs, not source + macro-set pairs; macro-set upgrades are coordinated events.

---

## 058-032: Typed Macros

1. **Polymorphic macros — deferred.** A macro that accepts `:AST<T>` for any T (the "debug-print works on any type" case) requires parametric polymorphism. 058-030 does not currently provide polymorphism for functions either — the only polymorphism in 058-030 is via enum wrapping (closed coproducts pattern-matched). If a future proposal adds parametric polymorphism for functions, macros follow the same pattern. Out of scope for 058-032; not a loss, since it matches 058-030's existing discipline.

2. **Bare `:AST` retirement — confirm.** 058-031's original examples used bare `:AST` as macro-parameter types; 058-032 retires that as a placeholder (same discipline as 058-030's ban on `:Any`). 058-031 examples swept to `:AST<T>` in the same commit. Any remaining bare-`:AST` parameter types in sub-proposal examples are unintentional — sweep pass welcome from the designer review.

3. **Interaction with macro hygiene.** Typed-macro elaboration binds parameters in the type environment; 058-031's scope-set hygiene binds them in the scope environment. Both are per-parameter metadata on the `Identifier` struct; they operate orthogonally and compose cleanly. No open question other than the integration testing that happens when both features ship together.

4. **Type-variable polymorphism inside a typed macro body.** Hypothetical: a macro whose body uses a type variable that appears in its signature (`(defmacro (swap (a :AST<T>) (b :AST<T>) -> :AST<T>) ...)` with T bound in the macro's scope). Under 058-030's current "no parametric polymorphism for functions" rule, macros also don't get this. If 058-030 relaxes, macros follow. No open action for 058-032; deferred with the broader polymorphism question.

---

## Cross-cutting themes

### Theme: AST preservation vs. eager expansion (cache canonicalization)
- 058-008 Q2 — preserve `Linear` in AST or expand to Blend
- 058-009 Q3 — preserve `Sequential` as semantic name in AST
- 058-010 Q3 — `Concurrent`/`Bundle` cache entries, shared or separate
- 058-017 Q4 — "same consistency concerns as 058-008" for Log
- 058-018 Q6 — "same consistency concerns as 058-008 and 058-017" for Circular
- 058-024 Q2 — cache canonicalization for Unbind alias
- **Theme-wide RESOLUTION via 058-031 (defmacro).** All of the above dissolve: macros expand at parse time, the canonical (post-expansion) AST is what hashes and caches. Two source files differing only in alias choice produce the same expanded AST and same hash. No separate canonicalization layer needed.

### Theme: Dependency on 058-002 (Blend) resolution — RESOLVED (Blend ACCEPTED as Option B with negative weights)
- ~~058-004 Q3~~ — Difference REJECTED; moot.
- ~~058-008 Q4~~ — Linear REJECTED (identical to Thermometer); moot.
- ~~058-015 Q4~~ — Amplify becomes `(:wat/algebra/Blend x y 1 s)`; stdlib macro unblocked.
- ~~058-018 Q3~~ — Circular becomes `(:wat/algebra/Blend cos-basis sin-basis (cos θ) (sin θ))`; stdlib macro unblocked.
- ~~058-019 Q4~~ — Subtract becomes `(:wat/algebra/Blend x y 1 -1)`; stdlib macro.
- ~~058-020 Q4~~ — Flip REJECTED; moot.
- **Status:** Blend is ACCEPTED. All downstream stdlib macros are unblocked. Designer review may still reopen Blend in Round 3; the downstream cascade adapts to whatever final shape designers affirm.

### Theme: Naming — alias proliferation vs. reader-intent clarity — LARGELY RESOLVED
- ~~058-004 Q1/Q2~~ — Difference REJECTED.
- ~~058-010 Q1/Q5~~ — Concurrent REJECTED.
- ~~058-011 Q3~~ — Then REJECTED (reverse form question moot).
- ~~058-019 Q1/Q2~~ — Subtract is the canonical delta; Difference rejected; "Remove" considered and dropped.
- ~~058-020 Q1~~ — Flip REJECTED; moot.
- ~~058-024 Q1/Q6~~ — Unbind REJECTED.
- ~~058-026 Q1~~ — Array stays; renamed Vec per container-rename decision.
- 058-027 Q1/Q5 — Set as third Bundle-alias; Group/Collection/Multiset naming — LIVE (doc-only).

### Theme: Leaves-to-root completeness — RESOLVED
- 058-021 (Bind), 058-022 (Permute), 058-023 (Thermometer) collapsed to `CORE-AUDIT.md`.
- 058-025 (Cleanup) REJECTED.

### Theme: Ternary / non-bipolar vectors — RESOLVED via FOUNDATION "Output Space"
- ~~058-006 Q1/Q4~~ — Resonance REJECTED; questions moot.
- ~~058-007 Q5~~ — ConditionalBind REJECTED; questions moot.
- 058-021 Q2 — Bind reversibility on ternary → resolved: Bind as query, similarity-measured not elementwise; see FOUNDATION "Bind as query."
- ~~058-023 Q6~~ — Thermometer ternary extensions → Thermometer continues to produce bipolar; ternary comes from downstream ops.
- ~~058-024 Q3~~ — Unbind REJECTED.

### Theme: Edge cases and degenerate inputs
- 058-005 Q4 — zero-magnitude y in Orthogonalize
- 058-012 Q1 — `(Chain [])` and `(Chain [a])` semantics
- 058-013 Q2 — `(Ngram 0 xs)`, `(Ngram 5 [a b c])`, `(Ngram 2 [])`
- 058-015 Q1 — `s = 1` degeneracy in Amplify
- 058-016 Q6 — empty Map
- 058-017 Q2 — numerical preconditions for Log (must be positive)
- 058-026 Q4 — bounds checking in Array `nth`
- 058-027 Q7 — empty Set

### Theme: Remaining bareword sweep follow-ups (post-Round-3 cleanup)

The bareword-sweep agent flagged these as ambiguous — names left bare because their keyword paths were not in the mapping rules at sweep time. Datamancer direction already given; a mechanical pass will land them in source before implementation, not before designer review.

- **Math primitives** — `cos`, `sin`, `pi`, `log`, `ln` used inside Circular (058-018) and Log (058-017) macro expansions. **Decision:** these are used ONLY inside stdlib macros, so they live at `:wat/std/math/cos`, `:wat/std/math/sin`, `:wat/std/math/pi`, `:wat/std/math/log`, `:wat/std/math/ln`. Sub-proposal sweep pending (trivial; substitute at call sites).
- **Substrate accessors derived from `:wat/config/dims`** — `noise-floor` (the `5/sqrt(d)` threshold) is the primary example. **Decision:** these become typed properties on `:wat/config`. `(:wat/config/noise-floor) -> :f64` is computed at freeze time from `:wat/config/dims` and exposed as a direct getter. The config struct grows a computed-field tier; setters set the independent fields (dims), computed fields are populated at freeze. FOUNDATION update pending.
- **Algebra substrate operations** — `cosine`, `dot`, `encode`, `project`, `reject`, `anomalous-component`, `presence` appear bare in examples. **Decision:** these are algebra-level operations, so they live under `:wat/algebra/...` (e.g., `:wat/algebra/cosine`, `:wat/algebra/presence`). Distinct from `:wat/config/noise-floor` (which is a constant derived from dims) by the kind of value they return. Sub-proposal sweep pending.
- **Engram library operations** — `match-library`, `library-add!`, `entries` are app-level engram primitives. Not stdlib, not kernel — these live in the app's own keyword space (e.g., `:project/trading/engram/match`, `:project/trading/engram/add!`). The bang on `library-add!` is correct — the engram library mutates during learning, which is a program's private state behind a queue, not ambient state. Designers will see references to `entries` and `match-library` in examples; they are placeholder app-level ops.
- **List combinators — RESOLVED.** The split between `:wat/core/` and `:wat/std/list/` is drawn along **Rust-direct correspondence**: core wraps single-method calls on Rust's `Iterator` / `Vec` / `&[T]`; stdlib wraps small compositions of those methods.
  - **`:wat/core/`** (single-method direct): `list`, `cons`, `first`, `second`, `rest`, `map`, `for-each`, `filter`, `fold`, `foldl`, `foldr`, `reduce`, `length`, `reverse`, `range`, `take`, `drop`, `empty?`. No `null?` — Rust has no null; wat follows. Each maps to a single Rust iterator method or equivalent (`xs.len()`, `xs.is_empty()`, `xs.iter().take(n)`, etc.).
  - **`:wat/std/list/`** (iterator-method compositions): `pairwise-map`, `n-wise-map`, `map-with-index`, `window`, `zip`, `unzip`, `take-while`, `drop-while`, and similar short compositions. Each is also a near-one-liner in Rust (`xs.windows(2).map(f)`, `xs.iter().enumerate().map(f)`, etc.), but a COMPOSITION of core methods, not a single call. Stdlib macros emit calls to these by keyword path; resolution happens at load time.
  - **Userland** (not stdlib): `encode-window`. Domain-specific to asset tracking — it's the trading lab's Bundle-with-Permute-by-index of a candle window. Lives at its app's own path (e.g., `:project/trading/engram/encode-window`). Not generic; not stdlib.
  - **Load-bearing insight:** the division line between core and stdlib is not philosophical — it's "does Rust give us this as a method, or is it a short composition of methods?" This framing extends to future primitive proposals: show its Rust correspondence; if it's one method, it's core; if it's a short composition, it's stdlib; if it's app-shaped, it's userland.
  - Sub-proposal sweep pending: Chain/Ngram/Sequential/Analogy still use bare `pairwise-map` / `n-wise-map` / `map-with-index` in their macro bodies. Mechanical rewrite to full keyword paths can land post-Round-3.
