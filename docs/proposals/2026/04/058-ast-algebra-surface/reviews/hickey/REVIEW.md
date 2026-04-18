# Review — 058 AST Algebra Surface (Round 2)

A Hickey-lens second pass. Round 1 lives in `../archive/hickey-round-1/REVIEW.md`.

---

## Summary verdict

Round 2 is an improvement on round 1 — not in bulk, but in precision. Three round-1 concerns are now genuinely closed (Subtract/Difference unified, ternary output formalized, capacity framed as one substrate property rather than a defect). Two are **half-fixed in a way that reveals new complection**: `defmacro` solves the hash-collision problem for stdlib aliases but also amplifies the alias-proliferation problem because the cost-of-a-name dropped to zero, and the type-system Rust-primitive reform is the right move but has NOT propagated through the proposals that still reference `:Scalar`, `:Int`, `:Bool` in their signatures. Three are **still open and now more glaring** because the surrounding work sharpened: the Thermometer signature contradiction (six proposals plus FOUNDATION still disagree), the `get` contradiction (Map/Array still define `get`/`nth` as cleanup-based vector ops despite FOUNDATION declaring them AST walkers), and the core-affirmation proposals (021, 022, 023, 025) that still occupy review effort better spent on the actually-open decisions.

Overall: the **pivotal moves remain correct** (AST-primary, Blend Option B, Orthogonalize, `defmacro` as the canonicalization gate, `->` return syntax inside the signature, Rust-primitive types). The **connective tissue has not caught up with the pivots**. Ship-after-one-sweep: the batch is accept-with-changes, and the changes are a reconciliation pass across the proposals plus a handful of hard kills.

---

## Round-1 concerns — resolution status

### RESOLVED

**R1#2 — Thermometer signature contradicts across docs.**
→ **UNRESOLVED (see below).** FOUNDATION, HYPOTHETICAL-CANDLE-DESCRIBERS, Linear/Log/Circular stdlib definitions, and 058-008/017/018 all use `(Thermometer value min max)`. But **058-023 (the affirmation doc) still says `(Thermometer atom dim)`**, RUST-INTERPRETATION's ThoughtAST enum correctly uses `Thermometer(f64, f64, f64) // value, min, max`, and 058-008/017/018 themselves expand to `(Thermometer low-atom dim)` in their macro bodies (internally inconsistent: they follow FOUNDATION as callers, but 058-023 as the called primitive). This is the SAME bug I flagged in round 1, not a new one. **Status: UNRESOLVED.**

**R1 complection #5 — Subtract vs Difference, same math, two names.**
→ **RESOLVED.** 058-004 is explicitly REJECTED with a visible notice at the top; Subtract (058-019) is the canonical form; Analogy now references Subtract in its expansion. Good. Exactly the resolution I recommended.

**R1 easy-disguised-as-simple #1 — reader-intent justification for alias proliferation.**
→ **PARTIALLY RESOLVED, NEW ISSUE INTRODUCED.** The introduction of `defmacro` (058-031) removes the hash-collision cost of aliases, which was the main technical argument against them. But the reader-intent cost remains and is now harder to police — because the cost of adding a macro alias to stdlib is approximately one quasiquoted line. The batch retained `Concurrent`, `Set`, `Array`-as-alias, `Unbind` despite round-1 rejection of three of them. The defense is still "reader intent." The Hickey test ("does a reader lose something when they see the expansion?") still fails for Concurrent and Set. **Status: PARTIALLY RESOLVED on the mechanism, UNRESOLVED on the discipline.**

**R1 complection #6 — Unbind as alias for Bind.**
→ **RESOLVED for the right reason.** Unbind survives as a `defmacro` expanding to Bind. The zero-cost-of-canonicalization means the reader-intent argument now stands on its own. In round 1 I argued Unbind was the one alias that earned its keep; the mechanism now makes that honest.

**R1 hammock #3 — cache canonicalization question spans ~12 stdlib proposals.**
→ **RESOLVED.** `defmacro` is the answer. Expansion runs at parse time BEFORE hashing — all stdlib aliases canonicalize to their expansion, `hash(AST) IS identity` holds as invariant. This is exactly the right resolution and it was a gap in round 1. Give credit: the pipeline in FOUNDATION ("startup pipeline (ordered)") makes the invariant clear.

**R1 hammock #6 — Analogy argument order and MAP completion.**
→ **RESOLVED.** The stdlib definition `(Bundle (list c (Subtract b a)))` is stated, references Subtract (not the rejected Difference), and is the MAP-VSA completion. Unambiguous.

**Beckman R1 findings #1 (Bundle non-associativity) and #3 (Bind weakening on ternary).**
→ **RESOLVED via framing.** FOUNDATION's new sections "The Output Space — Ternary by Default" and "Capacity is the universal measurement budget" reframe both: ternary thresholding with `threshold(0) = 0` makes Bundle associative, and Bind's partial recovery on sparse inputs is capacity consumption rather than a law violation. This is the right framing and it is honest. Genuinely improves the document.

**R1 hammock #4 — "signed ASTs prevent injection" story under-hammocked.**
→ **PARTIALLY RESOLVED.** The Model-A reframe ("All loading happens at startup") gives the security property a clean one-sentence form: "After startup, the only code that runs is code in the static symbol table; constrained eval over that table is safe by construction." FOUNDATION now states this clearly in the "Cryptographic provenance" section. The commentary around it is still dense but the property is no longer buried.

### PARTIALLY RESOLVED

**R1 complection #1 — `get`/`nth` has two inconsistent definitions (AST walk vs. cleanup+Unbind).**
→ **UNRESOLVED, and now worse.** FOUNDATION's `get` definition (lines 1913-1926) is AST-walking — it matches my round-1 recommendation:

```scheme
(define (get structure-ast locator-ast)
  (cond ((map? structure-ast) (find-value-by-key ...))
        ((array? structure-ast) (nth ...))))
```

But the Map proposal (058-016) still defines `get` as:

```scheme
(define (get map-thought key candidates)
  (cleanup (Unbind map-thought key) candidates))
```

And the Array proposal (058-026) still defines `nth` as:

```scheme
(define (nth array-thought index candidates)
  (cleanup (Permute array-thought (- 0 index)) candidates))
```

These are two different operations with different costs and failure modes (AST field access vs. codebook cleanup). The proposals have NOT been swept to match FOUNDATION. A reader who picks up Map's proposal and FOUNDATION side by side gets two different answers for what `get` does. **This is the single most dangerous unresolved contradiction in the batch** because vocab code will be written against whichever the author reads first. **Status: UNRESOLVED.**

**R1 complection #2 — Thermometer signature contradicts FOUNDATION/stdlib.**
→ **UNRESOLVED.** FOUNDATION, HYPOTHETICAL-CANDLE-DESCRIBERS, and the stdlib Linear expansion all use `(Thermometer value min max)`. RUST-INTERPRETATION's ThoughtAST enum uses `Thermometer(f64, f64, f64) // value, min, max`. But **058-023 itself** still says `(Thermometer atom dim)`, and **058-008 Linear's macro body internally uses `(Thermometer low-atom dim)`** — which is a THIRD, internally-contradictory signature (the caller thinks value/min/max, the callee definition thinks atom/dim). This is the same bug round 1 flagged. Nothing was fixed. **Status: UNRESOLVED.**

**R1 complection #3 — Array expansion defined two different ways.**
→ **PARTIALLY RESOLVED.** Array (058-026) now clearly defines itself as a Sequential alias. Sequential (058-009) now clearly defines itself as Bundle-over-Permute. FOUNDATION's lines 1899-1906 show a different stdlib Array expansion (Bundle of Bind(Atom i) item) — bind-to-integer-atom. **Still two different encodings of "Array"**, still unreconciled. The Sequential alias gives `nth` via Permute-then-cleanup; the Bind-to-integer-atom form gives `nth` via Unbind-against-integer-atom. These are materially different vectors. FOUNDATION shows one; 058-026 proposes the other. **Status: UNRESOLVED.**

**R1 complection #4 — Bundle/Concurrent/Set triplet.**
→ **UNRESOLVED on policy.** `defmacro` removes the hash cost, so all three now canonicalize to the same Bundle AST. But two round-1 recommendations still stand: (a) the reader-intent defense is still thin — "temporal" vs. "data structure" vs. "primitive" is a distinction the enclosing context already carries; (b) Set has no accessor, making it asymmetric with Map (get) and Array (nth), which 058-027 acknowledges and then punts ("similarity testing IS the accessor"). The asymmetry is a design smell. **Status: UNRESOLVED.**

**R1 complection #7 — Array/Sequential naming.**
→ **UNRESOLVED on policy.** Same macro canonicalization applies. Both names survive with "reader intent" justifications. Same thin defense.

**R1 complection #8 — Set has no accessor.**
→ **UNRESOLVED.** 058-027 still says "similarity testing IS the accessor for Set" with an undocumented threshold deferred to "userland stdlib." Round-1 recommendation was (a) spec `member?` with a default threshold or (b) delete Set entirely. Neither happened.

**R1 hammock #2 — core-affirmation proposals (021, 022, 023, 025) should be demoted to audit entries.**
→ **UNRESOLVED.** 058-021, 058-022, 058-023, 058-025 all remain as full proposals. Each still opens with "Q1: is this proposal needed?" — the proposals themselves flag their own redundancy. They continue to consume designer attention that would better go to the actually-open decisions (Thermometer signature, Array expansion, get semantics).

**R1 hammock #1 — type system generic syntax and nominal-vs-structural split.**
→ **PARTIALLY RESOLVED.** The `:is-a` keyword for `deftype` is a good addition — it gives three distinct semantics (alias, subtype declaration, nominal wrapper) with clear names. FOUNDATION's type grammar is tighter than round 1. But the generic syntax `(deftype :wat/std/Option<:T> (:Union :Null :T))` is still angle-bracket-in-keyword — non-Lispy, unresolved. And `deftype` as structural alias still overlaps with `newtype` as nominal wrapper in ways that will confuse users: `(deftype :Price :f64)` is a type-compatible alias, `(newtype :Price :f64)` is a distinct type — same syntax shape, different semantics, no visual cue. **Status: PARTIALLY RESOLVED.**

**R1 hammock #4 — Ngram edge cases unspecified.**
→ **PARTIALLY RESOLVED.** 058-013 now states the proposed conventions: `n=0` is error, `n > length` is empty bundle, `xs = []` is empty bundle. But Q2 still says "confirm conventions" — the proposal proposes, doesn't lock. One more pass closes this.

**R1 hammock #5 — `:Any` escape hatch.**
→ **UNRESOLVED.** Still mentioned as "document as last resort" with no constraint on its use. The auto-degradation risk I flagged (most stdlib eventually returns `:Any` because polymorphism is hard) is still present. Still worth hammocking.

### UNRESOLVED

**R1 easy-disguised-as-simple #2 — keyword-path naming as a substitute for namespaces.**
→ **UNRESOLVED.** FOUNDATION still says "no namespace mechanism; just naming discipline" (line 1530). No introspection, no import aliases, no local rebinding. The round-1 argument stands: this is a convention renamed as a mechanism. If you add `defmacro`, the pressure to add namespace aliases will grow immediately — macros rewriting names across vocab boundaries are exactly where import aliasing matters most.

**R1 easy-disguised-as-simple #3 — speculative "programs ARE thoughts" material mixed with load-bearing core/stdlib criteria.**
→ **UNRESOLVED.** FOUNDATION grew longer, not shorter. The "Programs ARE Thoughts," "The Location IS the Program," "Reader, Did You Just Prove an Infinity?" and "About How This Got Built" sections are beautiful but still mixed into the document that 30 sub-proposals cite as their criterion reference. A future proposal author looking up "what's the bar for core?" has to wade through a holographic-principle essay to get to the three-rule criterion. **Status: UNRESOLVED.**

### NEW CONCERNS

**N1. The Rust-primitive type reform is announced but not propagated.**

FOUNDATION's revision history (2026-04-18 entry) states: "Drop abstract `:Scalar`/`:Int`/`:Bool`/`:Null` in favor of Rust primitives (`:f64`, `:i32`, `:usize`, `:bool`, `:()`, etc.)." This is the right move. But the proposals themselves have not been swept:

- 058-028 (define) still uses `[x : Scalar] [y : Scalar]` examples.
- 058-030 (types) states both in parallel — line 19-39 lists `:Thought`, `:Atom`, etc.; line 39-57 lists `:i8`..`:i128`, `:f32`, `:f64`. But `:Scalar`, `:Int`, `:Bool` still appear in the examples at lines 99-105 (`(struct :Candle [open : f64] ...)` — here correct) and throughout the proposal text ("What kind of value each argument is (Thought? Scalar? Integer? List?)" at line 225).
- RUST-INTERPRETATION still has `Value::Int(i64)` and `Value::Scalar(f64)` with old naming.
- HYPOTHETICAL-CANDLE-DESCRIBERS uses `[open : Scalar]`, `: Thought`, `: Bool`, `: Function` — all still in the old abstract-type vocabulary.
- 058-016 (Map), 058-026 (Array), 058-027 (Set) all use `cleanup` in examples — they haven't been swept for the `get`-as-AST-walker decision either.

**The reform landed in FOUNDATION's prose and in the built-in type list, but did not propagate into the proposals that define the functions that use those types.** This is a reconciliation debt that grows every time someone reads a proposal and internalizes the stale vocabulary.

**N2. `defmacro` introduces a parse-time tier without naming its complexity honestly.**

FOUNDATION's startup pipeline (lines 1714-1725) now has a macro expansion pass between parse and hash. This is technically correct. But the implications are understated:

- **Debugging.** Stack traces and error messages will point at expanded forms, not source. A user writing `(Subtract x y)` and seeing an error in `(Blend x y 1 -1)` needs tooling (source maps) that 058 does not specify. The proposal says "standard Lisp problem with well-known solutions" — true, but Clojure/Racket/CL have decades of tooling around this, and wat has none.
- **Hygiene.** 058-031 explicitly chooses unhygienic macros ("start unhygienic; add hygiene if collision issues emerge"). Every modern Lisp (Scheme R5RS+, Racket, Clojure) uses hygienic or gensym-based macros for good reason. Unhygienic macros in production vocab code will cause variable-capture bugs that surface as "my macro broke when I renamed a local." The proposal acknowledges the risk and defers.
- **Cryptographic provenance.** Signatures cover the SOURCE text; hashes cover the EXPANDED AST (per 058-031). This is stated clearly. What is NOT stated: what happens when the macro set changes between loads. A wat file signed under macro-set M1 expands to AST H1. Reload under macro-set M2 expands to H2. Same file, same signature, different hash. The algebra's "distributed verifiability" story assumes all nodes run the same expansion pipeline — which means all nodes must agree on the macro set, and macro updates become a coordinated event. The proposal doesn't address this.
- **Type checking on expansions.** 058-031 says "check types during macro authoring" is "out of scope for this proposal; minimal version checks the expanded form." This means a macro author can write a macro that produces ill-typed ASTs and won't discover it until a user instantiates it at a specific type. Classical typed-macros problem; Racket solved it; wat defers.

The form earns its place (it resolves the hash-collision). The cost is real and should be named where it is specifically: `defmacro` adds a full parse-time language layer to wat, with all the debugging/hygiene/provenance/type-checking concerns that every Lisp macro system has wrestled with for 60 years. Deferring these is fine as a staging decision; pretending they don't exist would not be.

**N3. Output-space ternary is correct; downstream proposals still talk bipolar.**

FOUNDATION's "Output Space — Ternary by Default" section (around line 1297) is a clear, load-bearing improvement. `threshold(0) = 0`, zero as "no information," Bundle associativity preserved. Good.

But several proposals still describe their outputs as bipolar:

- 058-023 (Thermometer) says its output is "dense-bipolar `{-1, +1}`" — actually that is specifically CORRECT per FOUNDATION (Thermometer produces dense-bipolar as a subset of ternary), and the proposal says so. OK.
- 058-006 (Resonance) says "For bipolar vectors `v, reference ∈ {-1, +1}^d`" — old framing. Under ternary, the operation must handle zeros on either input. The proposal's table at the end does acknowledge ternary output, but the operational definition still assumes bipolar inputs. Should be swept.
- 058-002 (Blend) correctly states ternary output throughout.

This is minor but it's the same problem as the type reform — the global decision landed, the local docs don't consistently reflect it.

**N4. `:is-a` deftype creates a new category of name.**

The type system now has THREE related forms:
- `(deftype :A :B)` — structural alias, `:A` and `:B` are the same type
- `(deftype :A :is-a :B)` — subtype declaration, `:A` is a new type narrower than `:B`
- `(newtype :A :B)` — nominal wrapper, distinct identity

This is clearer than round 1's two forms with overlapping semantics, but the syntactic symmetry is misleading. The first two forms LOOK the same (both `deftype :A ...`) but mean different things (identity vs. subtype). A reader has to scan past the type name to see whether `:is-a` is present. Compare to Rust where `type X = Y;` (alias) vs. `struct X(Y);` (newtype) are lexically distinct at the head. **This is easy-looking syntax complecting two semantically distinct operations into one form name.** Consider distinct head keywords: `(typealias :A :B)` for structural, `(subtype :A :of :B)` for subtype, `(newtype :A :B)` for nominal. Three forms, three names, zero ambiguity at the head.

**N5. Proposal 058-023's "Atom-to-fractional-position" is a convention that affects distributed consensus.**

058-023 says: "the atom determines its gradient's transition point... Document the convention: e.g., `position = hash(atom) / 2^64 ∈ [0, 1]`, or `position = fixed_per_atom_mapping(atom)`." But this convention determines the vector Thermometer produces, which is the input to Blend, which is what Linear/Log/Circular compose over. **If two nodes disagree on the convention, they compute different vectors for identical ASTs** — and "distributed verifiability" (FOUNDATION's claim) breaks silently. This is a load-bearing convention, not a documentation footnote. The signature contradiction I flagged (R1 #2) sits on top of this. Fix both together: pick `(Thermometer value min max)`, specify the encoding exactly.

---

## What is now simple, done right

**1. `defmacro` as the canonicalization gate.**

This is the correct answer to the hash-collision question I left open in round 1. Parse-time expansion before hashing, `hash(AST) IS identity` as an invariant, source-level reader clarity preserved, canonical form at the hash. The mechanism is Lisp-standard; the justification is clean; the pipeline is ordered explicitly in FOUNDATION. Good work.

**2. Rust primitives replace abstract types (`:f64`, `:usize`, `:bool`, `:()`).**

Correct. `:Scalar` and `:Int` were categorically dishonest — they hid which Rust type the wat-vm actually used. `:f64` says what it is. The match to Rust is load-bearing for the wat-vm's type-dispatch story and for users who have to think about precision/overflow/coercion. This is exactly the kind of "say what it is" move the Hickey lens asks for.

**3. `->` return-type syntax inside the signature form.**

The round-1 code had `: ReturnType` dangling outside the signature parens:
```scheme
(define (name [arg : Type]) : ReturnType body)
```
The round-2 form is:
```scheme
(define (name [arg : Type] -> :ReturnType) body)
```
This reads as Rust's `fn name(arg: Type) -> ReturnType`, keeps the whole signature in one parenthesized form, and stops the "where does the signature end?" reader ambiguity. Small change, big clarity win.

**4. Subtract wins, Difference dropped.**

The round-1 alias debate resolved cleanly: 058-004 REJECTED, 058-019 canonical, Analogy updated. The rejection notice at the top of 058-004 is honest documentation — the rejected proposal stays as an audit record of the decision, not as a surviving definition. This is the right way to handle rejected proposals.

**5. Capacity as the universal measurement budget (response to Beckman).**

FOUNDATION's "Capacity is the universal measurement budget" subsection is a genuinely improved framing. Instead of treating Bundle crosstalk, sparse-key decode noise, and Orthogonalize post-threshold residual as separate algebraic "phenomena" (or worse, as "weakenings"), the new framing treats them all as expenditures from one substrate property (signal-to-noise at high dimension, measured uniformly by cosine). This is decomplection: three apparent defects → one substrate property. Good work.

**6. Ternary output formalized with `threshold(0) = 0`.**

Bundle is associative under ternary. Orthogonalize's claim holds exactly at the degenerate case. Zero means "no information." The algebra is internally consistent under one rule. This is exactly the kind of load-bearing clarification that makes downstream reasoning simpler.

**7. Model A honestly scoped as a host-level constraint.**

FOUNDATION now states plainly that static loading is a Rust-host choice, not an algebraic invariant. The algebra would run fine on a dynamic host; the algebra doesn't care. This is the honesty I asked for in round 1. Don't let it drift.

---

## What is still complected

**1. `get`/`nth` as two different operations under one name.**

Round 1 called this out. Round 2 added FOUNDATION's AST-walking definition but did not sweep Map/Array's proposals to match. A reader who sees `(get m k)` in Map's proposal and `(get s k)` in FOUNDATION gets two different operations, two different costs (O(log n) tree walk vs. O(k·d) cleanup), two different failure modes (key-not-found vs. closest-vocabulary-match). **Pick one. Delete the other. Name the other operation something else (e.g., `decode-field` or keep explicit `(cleanup (Unbind ...) candidates)`).** This is the same complection I flagged in round 1, still open.

**2. Thermometer's identity is still undetermined.**

Six proposals (058-008, 058-017, 058-018, 058-023), FOUNDATION, HYPOTHETICAL-CANDLE-DESCRIBERS, and RUST-INTERPRETATION do not agree on whether Thermometer's signature is `(value, min, max)` or `(atom, dim)`. **These are two different primitives.** The `value/min/max` form is a scalar-to-gradient encoder (input: a value, a range); the `atom/dim` form is a seeded-gradient producer (input: a name, a width). Picking one requires redefining the other and probably renaming it. This is a pre-commit blocker, not a designer nit.

**3. `defmacro` complects parse-time code with startup code.**

`define`, `lambda`, `struct`, `enum`, `newtype`, `deftype`, `load`, `load-types` all register at startup. `defmacro` registers at **parse time**, which is BEFORE the startup pipeline (per FOUNDATION lines 1706-1725). FOUNDATION calls this step 2 of startup, which is technically correct — parse happens at startup — but it conflates "parse" with "build" with "startup" in a way that will matter when someone tries to reload a `.wat` file dynamically under a future non-Rust host. Under Model A the distinction doesn't bite, but the algebra is not Model-A-only (FOUNDATION says so). A future host that supports dynamic `define` also needs to handle dynamic `defmacro`, and the parse-time semantics become the locking point for incremental reloads.

**4. `deftype` with two semantics (alias and subtype via `:is-a`) under one head.**

N4 above. `(deftype :A :B)` and `(deftype :A :is-a :B)` are different operations with the same head keyword. Consider splitting.

**5. Bundle / Concurrent / Set triplet with one expansion.**

Now merely an aesthetic complection rather than a hash collision — but still three names for the same operation. Round-1 recommendation stands: keep Bundle + at most one alias. Concurrent earns "temporal co-occurrence" in the trading-vocab context; Set earns "unordered collection" in the data-structure context. **Pick one.** Reader intent is one concept; naming it twice is not a win. If the choice is hard, that is a signal that the distinction is not load-bearing.

---

## What demands more hammock

**1. How does the cache handle algebra-version skew?**

The cache keys on `hash(expanded AST)`. If the stdlib macro set changes (add a new `defmacro`, change an existing expansion), the same source file expands to a different AST and therefore a different hash. On a single node this is fine (rebuild, rehash). On a distributed substrate (FOUNDATION's "cloud of thinking machines" claim), all nodes must agree on the macro set simultaneously. FOUNDATION does not address this. Adding a macro becomes a coordinated global event — which is a reasonable decision but needs to be explicit.

**2. What is the precise contract between `define`'s body execution and ThoughtAST realization?**

FOUNDATION says a `define` body runs at call time; if it returns a ThoughtAST, the ThoughtAST is "realizable not automatically realized." The realization happens on `cosine`, `encode`, cache lookup, signing, transmission. Clear enough.

But: when a stdlib macro expands to a body that includes `define`-level code (e.g., a stdlib `define` that internally calls another stdlib form), the macro-expanded body runs at call time, returns an AST, which is lazy. When does the AST realization happen for an intermediate let-bound value that NEVER gets compared or encoded? Is it built and discarded? The cache-as-working-memory framing says yes — unreferenced ASTs don't realize. But then some vocab code pays realization cost depending on whether a downstream operation triggers it — invisible to the vocab author. This is a debuggability concern worth hammocking.

**3. Typed macros (deferred) and the signature of `defmacro`.**

058-031 says macro parameters are all `:AST`, return is `:AST`. Good. But when a macro expands to a form that's ill-typed for its callers, the error surfaces at type-check time (after expansion) and the error location points at the expanded form, not the macro source. For 5-line macros this is fine; for 50-line macros with multi-level expansion it is not. Racket's solution (typed macros) is heavy; untyped macros with good source maps (Clojure's approach) is lighter. Pick a stance; document it.

**4. `:Any` and the risk of polymorphism erosion.**

Round-1 hammock #5 still stands. `Cleanup` takes `:Any` candidates (heterogeneous codebook). `get` under AST walking still returns `:Any` if the value type is unknown. Once `:Any` is in several primitive positions, user-authored code that uses those primitives inherits `:Any` returns, which propagates. Suggestion: audit every position where `:Any` appears; restrict it to primitive-only signatures; forbid `:Any` in user-authored `define` return types (or require a `#[unsafe-any]` marker). Without this, the type system degrades under use.

**5. Core affirmation proposals.**

Round-1 recommendation: demote 058-021, 058-022, 058-023, 058-025 to a single `CORE-AUDIT.md` entry. Still stands. These proposals consume review cycles. 058-023 in particular is actively HARMFUL because it states a signature (`(atom, dim)`) that contradicts FOUNDATION and six other proposals — a demotion-to-audit pass would catch this as a reconciliation task rather than hiding it inside a proposal that affirms existing behavior.

**6. The `deftype` with `:is-a` variance interaction.**

FOUNDATION states variance rules: `(:List :T)` covariant, `(:Function args... -> return)` contravariant in args, covariant in return. Good. But what happens when a user writes `(deftype :MyAtom :is-a :Atom)` and has `(define (f [x : :MyAtom] -> :MyAtom) ...)`? Under covariance, `(:List :MyAtom) :is-a (:List :Atom)`, so a list of MyAtoms substitutes for a list of Atoms. Fine. But under contravariance, a function `(:Function :Atom -> :MyAtom)` is a subtype of `(:Function :MyAtom -> :Atom)` — the function-accepting-the-more-general-input and returning-the-more-specific. This is Liskov-correct but the interaction with user-defined `:is-a` types has not been exercised by any proposal's examples. Worth a worked case in FOUNDATION before shipping.

---

## Per-proposal verdict

| # | Form | Class | Verdict | One-line reasoning |
|---|---|---|---|---|
| 001 | Atom typed literals | CORE | ACCEPT | Type-aware hash stays correct; propagates 058-030's Rust-primitive reform into the literal space. |
| 002 | Blend | CORE | ACCEPT | Pivotal. Option B still correct. Ternary output-space sweep now correct. |
| 003 | Bundle list signature | CORE | ACCEPT | Lock the list form. Ternary associativity makes the stdlib reducer pattern clean. |
| 004 | Difference | REJECTED | ACCEPT REJECTION | Correctly REJECTED; notice at the top is good documentation. Keep as audit trace. |
| 005 | Orthogonalize | CORE | ACCEPT | Computed-coefficient operation distinct from Blend; ternary output-space makes orthogonality exact. |
| 006 | Resonance | CORE | ACCEPT-WITH-CHANGES | Sweep the operational definition to assume ternary inputs, not bipolar — consistent with FOUNDATION's output-space section. |
| 007 | ConditionalBind | CORE | ACCEPT-WITH-CHANGES | Consider `Select(a, b, gate)` or `Mask(v, gate)` as the underlying primitive; ConditionalBind is a natural stdlib on top. Hammock one more pass. |
| 008 | Linear | STDLIB | UNCONVINCED | Macro body uses `(Thermometer low-atom dim)` signature, which contradicts FOUNDATION's `(Thermometer value min max)`. Pre-commit blocker: resolve Thermometer's signature first, then sweep. |
| 009 | Sequential reframing | STDLIB | ACCEPT-WITH-CHANGES | End the grandfather. If `Array` survives as a separate macro (see 026), resolve which is the canonical positional-encoding name. |
| 010 | Concurrent | STDLIB | REJECT | Still a Bundle alias with a reader-intent justification. Zero-cost via macro doesn't make the reader-intent argument load-bearing. Surrounding context carries the temporal framing. |
| 011 | Then | STDLIB | ACCEPT | Permute-by-1 with a specific naming contract; earns the name through stable convention. |
| 012 | Chain | STDLIB | ACCEPT | Pairwise-Then; distinct enough from Sequential in operational shape. |
| 013 | Ngram | STDLIB | ACCEPT-WITH-CHANGES | Lock the edge cases; the proposal names them but labels them "confirm conventions." One more designer pass closes this. |
| 014 | Analogy | STDLIB | ACCEPT | Now references Subtract correctly. MAP completion documented. |
| 015 | Amplify | STDLIB | ACCEPT | Variable emphasis; distinct from Subtract (-1) and Flip (-2). |
| 016 | Map | STDLIB | ACCEPT-WITH-CHANGES | Rewrite `get` as AST walker per FOUNDATION lines 1913-1926. The current `(cleanup (Unbind ...) candidates)` body is a DIFFERENT operation; if kept, name it `decode-field` or similar. Pre-commit blocker. |
| 017 | Log | STDLIB | UNCONVINCED | Same as 008 Linear: macro body's Thermometer signature contradicts FOUNDATION. Resolve Thermometer first. |
| 018 | Circular | STDLIB | UNCONVINCED | Same as 008/017: Thermometer signature contradiction. |
| 019 | Subtract | STDLIB | ACCEPT | Canonical delta macro; Difference rejection makes this the single form. |
| 020 | Flip | STDLIB | ACCEPT | Weight -2 is non-obvious; the name earns its place. |
| 021 | Bind | CORE | ACCEPT (demote to audit) | Already core; this is an audit entry, not a live proposal. |
| 022 | Permute | CORE | ACCEPT (demote to audit) | Already core; audit entry. |
| 023 | Thermometer | CORE | UNCONVINCED | Signature contradicts FOUNDATION and six downstream proposals. Reconcile before accepting. Demote to audit after reconciliation. |
| 024 | Unbind | STDLIB | ACCEPT | The one alias that earns its keep; decode intent is stable operational information. `defmacro` makes it free at hash. |
| 025 | Cleanup | CORE | ACCEPT (demote to audit) | Already core; audit entry. |
| 026 | Array | STDLIB | REJECT or ACCEPT-WITH-CHANGES | If Array = Sequential alias (058-009), REJECT — redundant. If Array uses FOUNDATION's Bind-to-integer-atom encoding, ACCEPT but rewrite. Pick one encoding. |
| 027 | Set | STDLIB | REJECT | Third Bundle alias; `member?` not specified; asymmetric with Map/Array. Still thin. |
| 028 | define | LANG CORE | ACCEPT-WITH-CHANGES | Correct shape. Sweep examples to Rust-primitive types (`:f64`, not `:Scalar`). |
| 029 | lambda | LANG CORE | ACCEPT-WITH-CHANGES | Same as 028. |
| 030 | types | LANG CORE | ACCEPT-WITH-CHANGES | Rust-primitive set is right; `:is-a` is a good addition. Consider splitting `deftype` alias vs subtype into two head keywords (N4 above). Sweep proposal examples for the old `:Scalar`/`:Int` vocabulary. |
| 031 | defmacro | LANG CORE | ACCEPT-WITH-CHANGES | Correct answer to the hash-collision question. Name the debugging/hygiene/provenance/typed-macros costs explicitly; pick a stance for each (even "deferred" is a stance). |

**New verdicts not present in round 1:**
- 058-004 correctly REJECTED (was "REJECT" in round 1; the authors agreed).
- 058-031 is NEW — ACCEPT-WITH-CHANGES.

**Changed verdicts since round 1:**
- 058-008/017/018 went from ACCEPT-WITH-CHANGES to UNCONVINCED because the Thermometer signature contradiction is now more concrete (their macro bodies use the `(atom, dim)` form, contradicting FOUNDATION's `(value, min, max)`).
- 058-016 (Map) went from ACCEPT-WITH-CHANGES to ACCEPT-WITH-CHANGES-PRE-COMMIT-BLOCKER — the `get` contradiction is critical.
- 058-026 (Array) same as round 1 (REJECT IF ALIAS, ACCEPT IF BIND-INTEGER).

---

## Questions the proposals still don't raise but should

**1. What happens when a macro expansion references a later-loaded function?**

Macro expansion runs at parse time. Symbol resolution runs AFTER expansion. If a macro expands to `(my-stdlib-fn x y)` and `my-stdlib-fn` is defined in a later file in the load order, the expansion contains an unresolved symbol. Under Model A, this is caught at the resolve/type-check step (step 3 in FOUNDATION's pipeline). Fine.

But: can a macro expansion reference another macro that hasn't been registered yet? The pipeline says "repeat until fixpoint," so nested macros are expected to work. But the ORDER in which macros register matters for mutual recursion. 058-031 does not discuss load ordering for macros; FOUNDATION does not either.

**2. How does `eval` interact with macros?**

Constrained `eval` evaluates an AST at runtime. Macros ran at parse time. If a user constructs an AST at runtime that contains a MACRO call (e.g., `(list 'Subtract x y)`), does the runtime expand it before evaluation, or does `eval` only accept already-expanded ASTs? Both have implications. If `eval` expands, the macro registry is a runtime-accessible data structure (conflicts slightly with Model A's "frozen at startup"). If `eval` doesn't expand, users who construct ASTs at runtime must construct the fully-expanded canonical form — which means vocab-level macros are unusable at runtime even though they're usable at source.

Both of these are answerable. Neither is answered.

**3. Where does the lowercase primitive family live in the classification?**

FOUNDATION's "Two Tiers" section (added 2026-04-18) says lowercase `atom`, `bind`, `bundle`, `cosine`, `permute`, `blend` are Rust primitives that RUN. Not algebra core (that's UpperCase `Atom`, `Bind`, etc.). Not language core (that's `define`, `lambda`, etc.). Not stdlib. So what classification are they?

The answer is probably "host-inherited" — same bucket as `let`, `if`, arithmetic, collection operations. But the lowercase primitives are ALGEBRA, not language-control-flow. If they're host-inherited, their specification lives in... what document? FOUNDATION doesn't enumerate their signatures; RUST-INTERPRETATION talks about them as Rust functions but doesn't treat them as a formal tier.

This gap existed in round 1 and persists. Someone should write "The lowercase tier" as a classification sibling to algebra-core/stdlib/language-core, or explicitly absorb them into algebra-core as the Rust-side dispatch target.

**4. When does `encode` run across ThoughtAST / user-stdlib / macro boundaries?**

A vocab module's `(define (my-form x) ...)` returns a ThoughtAST. Its body uses other stdlib `define`s and macros. Some of those are UpperCase AST constructors; some are regular Lisp list operations. The machinery works, but there is no single-paragraph summary of "what runs when a value of type `:Thought` flows through wat." It would help to have one. FOUNDATION's "Executable semantics" subsection gets close but is phrased defensively ("the vector materializes only when something needs it") rather than constructively ("here is the sequence of events when X happens").

**5. What is the semantic of `Atom` on a user-defined struct?**

058-001 says Atom accepts string, int, float, bool, keyword, null. What about `(Atom some-candle)` where `some-candle : :project/market/Candle`? Presumably not allowed — Atom literals are primitives. But nothing in the proposals explicitly forbids it. If a user tries it, do they get a type error at startup, a runtime failure, or a hash of the struct's serialized form (which would be a very different contract)?

**6. How does `deftype :is-a` variance interact with macros?**

If a macro expands to code that relies on subtype coercion, the expansion's type-check happens on the canonical (post-expansion) form. But the macro author's authoring context may have had specific expectations about the user's type. N4 raises this via syntactic symmetry; the semantic question is "can macros be written polymorphically over subtypes?" Answer: probably yes, trivially, because the expansion is just an AST that will get type-checked at its call site. But this isn't stated. Users writing library macros will hit this immediately.

**7. What is the operator's experience of capacity degradation?**

The capacity-budget framing is correct (capacity at d=10k is ~100 items/frame). But a vocab module author encoding a 150-field Map doesn't see an error — they see "slightly worse cleanup accuracy." FOUNDATION's dimensionality section acknowledges this: "you can't express that — enforced geometrically." But how does the author DETECT that they exceeded capacity? Is there a `capacity-check` primitive? Does the encoder log warnings? Does `Bundle` refuse a too-large list? The proposals don't say. In production this will bite.

---

## Final note

Round 2 is a meaningful step forward. The pivotal moves from round 1 that I accepted hold up, and three of my five biggest concerns have been genuinely closed or reframed in ways that are better than my round-1 recommendations. That is the mark of a review cycle working: not that every critique lands as-asked, but that the authors engaged with the critique on its own terms and sometimes produced a better answer than the reviewer asked for. The `defmacro` move is an instance of that — I asked in round 1 for cache-canonicalization to be hammocked; the authors answered by building the canonicalization into parse-time expansion, which is a stronger answer than I suggested.

The unresolved concerns are almost all of the SAME CLASS: reconciliation debt. FOUNDATION has been rewritten thoughtfully; the proposals it cites have not been swept to match. Thermometer's signature, `get`'s semantics, the Rust-primitive type reform, the output-space ternary sweep — each is a global decision that landed in FOUNDATION and stopped there. The proposals still encode the pre-decision vocabulary, and the next reader (human or LLM) who starts at a proposal rather than FOUNDATION will internalize the wrong form. **This is not a large amount of work. It is an afternoon of reconciliation passes. But it has to happen before commit.**

The remaining structural concerns — alias proliferation, `defmacro`'s deferred hygiene/debugging/provenance story, the deftype `:is-a` syntactic ambiguity, the type-system's `:Any` erosion risk — are second-order. Each is fixable without restructure. Each deserves a short designer pass.

**The algebra is simple where it matters and easy where it shouldn't be.** The pivotal primitives (AST-primary, Blend, `defmacro`, ternary output, `->` return syntax, Rust-primitive types) are simple-made-simple. The alias triplets, the Thermometer contradiction, the `get` contradiction, and the deferred `:is-a` syntax are easy-made-to-look-simple. **Make the easy parts simple, and the batch ships.**

---

*Round 2 review completed 2026-04-17, applying the Hickey lens.*
