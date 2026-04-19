# Round 3 scratch

## Round 2 concerns — status check

### R2 RESOLVED concerns (per Round 2 REVIEW)
- Subtract/Difference unified — holds (R3: 004 REJECTED, 019 canonical).
- Ternary output-space — holds (FOUNDATION formalized threshold(0)=0).
- Capacity as measurement budget — holds.
- Bundle associativity framing — holds (similarity-associative at high d).
- Thermometer canonical layout N5 — addressed (2026-04-18 entry — `N = round(d·clamp(...))`, first N +1, rest -1).
- `defmacro` resolution — holds.

### R2 UNRESOLVED concerns — did they land in R3?

1. **Thermometer signature contradiction** → RESOLVED. All six docs unified on `(Thermometer value min max)`. 058-023 collapsed to CORE-AUDIT.md which states 3-arity canonical form. Explicit R3 entry in changelog.

2. **`get` contradiction (AST walker vs cleanup+Unbind)** → RESOLVED. 2026-04-18 "Presence is Measurement" entry + "container constructors renamed" entry. `get` is now a single-line unified dispatch through Rust's runtime backing (HashMap::get, Vec index, HashSet::get), returning `:Option<T>`. No cleanup. No Unbind. Map (058-016), Array (058-026), Set (058-027) all renamed and rewritten.

3. **Alias proliferation** → LARGELY RESOLVED via SHARP REJECTION. Ten forms rejected (Concurrent, Then, Unbind, Flip, Chain, Linear, Difference, Cleanup, Resonance, ConditionalBind). Each with banner + changelog entry citing specific reasoning. This is the datamancer APPLYING my Round-1 test ("does a reader lose something when they see the expansion?") at scale. Sharp. Honest.

4. **Core-affirmation proposals (021, 022, 023, 025)** → RESOLVED. 021/022/023 collapsed into CORE-AUDIT.md. 025 REJECTED (Cleanup). No more full-proposal overhead on affirmations.

5. **Rust-primitive type sweep** → RESOLVED. Multiple bareword sweeps documented (2026-04-18 "Type grammar locked"; "Bareword sweep across all 058 docs ~140 scheme blocks"). `:Scalar`/`:Int`/`:Bool`/`:Null` → `:f64`/`:i32`/`:bool`/`:Option<T>` etc. `:Any` dropped entirely.

6. **Output-space ternary sweep downstream** → RESOLVED via rejection. Resonance (which still talked bipolar) REJECTED, so the open-ness is gone.

7. **`deftype` with `:is-a` syntactic ambiguity (N4)** → RESOLVED via simplification. `deftype` gone entirely. Four distinct heads: `newtype` (nominal), `struct`, `enum`, `typealias` (structural). No `:is-a` keyword at all — nominal subtyping dropped; `:Holon` is an enum with variants pattern-matched. This is a stronger resolution than the three-heads split I suggested — they went further.

8. **`:Any` polymorphism erosion (R1 hammock #5)** → RESOLVED. `:Any` dropped from grammar. Every case has principled replacement (`:Holon`, `:Union<T,U>`, parametric T, `:List<Pair<Holon,Vector>>`).

9. **keyword-path naming as convention-dressed-as-mechanism** → PARTIALLY RESOLVED. Consolidated to one canonical policy section. BUT: parametric polymorphism was added (2026-04-18 "Parametric polymorphism as substrate"). This is new complexity and needs its own audit.

10. **N2 defmacro debugging/hygiene/provenance/typed-macros** → LARGELY RESOLVED. 058-031 ships with Racket-style sets-of-scopes hygiene (not "start unhygienic"). Datamancer: "macro expansion must be safe... there's no way we can get rust to not be safe, right?" 058-032 adds typed macros. Macro-set-versioning section added. This moved from "deferred" to "actually specified." Good answer.

11. **N3 output-space ternary sweep** — mostly moot because the bipolar-talking forms (Resonance) REJECTED.

12. **N5 Thermometer canonical layout** → RESOLVED. Locked: N = round(d · clamp((v-min)/(max-min), 0, 1)), first N +1, rest -1. Bit-identical across nodes.

### Status summary

Every Round 2 open item has a landed resolution. This is the rare case where ALL the reconciliation debt I flagged was addressed. 

## New Round 3 concerns — things that changed that need scrutiny

### N6 (R3). Parametric polymorphism as substrate

This is the biggest single new commit. 2026-04-18 entry: "Parametric polymorphism as substrate — programs ARE atoms, which demands it."

Claim: `:Atom<T>` accepts any T (primitive, composite `:Holon`, user type). Forces parametric polymorphism for user types, functions, macros. Rank-1 HM.

Hickey test: **Is this simple or easy?**

Arguments the move is SIMPLE:
- Uniform across the board (Atom, functions, types, macros) — one rule, not many.
- Enables programs-as-atoms (the operational claim of "Programs ARE Holons"). Without it, the claim is rhetorical — programs can't be atomized, can't be library-keyed, can't be compared.
- Rank-1 is well-understood (HM is 50 years old, bounded polynomial).
- Deferred: higher-kinded types, bounds, existentials. The complexity is paid only for what's needed.

Arguments it's EASY DRESSED AS SIMPLE:
- HM inference is NOT free in reviewer cognition. A parametric `:Atom<T>` in a type signature requires the reader to understand T's scope. Rank-1 is easier than rank-N but still not zero cost.
- The type-checker pass in holon-rs is substantial (the changelog names it "bounded polynomial"). A fully-static Rust-backed wat-vm with parametric types at startup is a real implementation feature.
- The "programs ARE atoms" application is evidenced but not yet used in production. The trading lab doesn't atomize programs today (only rhythms, candles, time facts). The engram library of learned programs is ASPIRATIONAL.

My read: **DEFENSIBLE BUT ON THE EDGE.** The substrate-level argument (programs ARE atoms is the honest operationalization of "Programs ARE Holons") is compelling. HM inference is tractable. The deferral of HKT/bounds/existentials is correct discipline.

Concern: the justification is "the algebra requires it to be honest about programs-as-values." But NO proposal in 058 shows a WORKING example of atomized programs in a trading or DDoS context. HYPOTHETICAL-CANDLE-DESCRIBERS presumably demonstrates this — let me check.

The scope commit is substantive. If I were to push back, it would be on "is the parametric commit motivated by current applications, or by future ones?" — and the answer "programs ARE atoms requires it" is speculative operationalization. A future-proofing argument dressed in foundational language.

HOWEVER: the datamancer owns this. They've committed to the work, named the cost, deferred what they can defer. The commit is ON PURPOSE. Not sneaking in.

**Verdict:** ACCEPT, with a note that the next-session work has to show at least one production use of atomized programs to retire the "substrate-not-speculation" defense.

### N7 (R3). `dot` as scalar-returning algebra primitive

New primitive: `:wat/algebra/dot`. Sibling to cosine. `:Holon :Holon -> :f64`. Scalar-out, not Holon-out.

Introduced to support the Reject/Project stdlib macros (which need a computed Gram-Schmidt coefficient `(x·y)/(y·y)`).

Hickey test: Is this introducing a new primitive tier, or is it exposing an existing operation?

Answer: Exposing. `cosine` was already computed internally as `dot / (norm·norm)`. `dot` is the un-normalized sibling. Trivial Rust implementation, same cost as cosine's internal step.

Tier: FOUNDATION now names TWO categories — Holon-producing primitives (6 forms) and scalar-returning measurements (cosine, dot). Orthogonal, honest.

**Verdict:** ACCEPT. The tier split is the honest naming of what's already implicit. Not a new thing — a previously-implicit thing made explicit.

Small nit: `dot` should probably be read as `:wat/algebra/dot` everywhere. Let me grep for bare references... seems consistent.

### N8 (R3). Algebra core shrinks to 6 forms

Post-rejections: Atom, Bind, Bundle, Blend, Permute, Thermometer. Six.

Was 7 (with Orthogonalize). Orthogonalize → Reject/Project stdlib. Algebra core shrunk.

Resonance, ConditionalBind, Cleanup all REJECTED.

**Verdict:** Correct. Smaller core is better when the smaller still covers everything. The six forms span:
- Structure: Atom, Bind, Bundle, Permute (MAP's A+M+P + naming)
- Continuous: Thermometer (the one scalar-to-gradient primitive)
- Combination: Blend (the parameterized binary combination)

These are genuinely independent algebraic operations. No complection hiding in the six.

### N9 (R3). Kernel primitives section

FOUNDATION now has a "wat-vm Substrate — Kernel Primitives" section (lines 780-1208, so ~430 lines).

Primitives: make-bounded-queue, make-unbounded-queue, send, recv, try-recv, drop, spawn, join, select, HandlePool (promoted from stdlib), Signal enum, signals queue.

Two stdlib programs: Console, Cache. Topic + Mailbox REJECTED (changelog entry cites "in practice they added a pointless thread hop over a loop the caller can write inline").

Hickey test: does this kernel surface belong in an ALGEBRA SURFACE proposal?

Concern: 058 is nominally the "AST algebra surface" batch. The kernel primitives (queues, spawn, signals, select, HandlePool) are CSP machinery. They support programs, not algebra. Where do they live?

Answer from FOUNDATION: "The wat-vm Substrate" section is load-bearing because without it, programs cannot run, and "Programs ARE Holons" is a dead principle. The algebra-surface batch has to specify the kernel that runs programs, otherwise the algebra is suspended in mid-air.

Counter-concern: this is a LOT of substrate to agglomerate into one proposal batch. 29 sub-proposals about algebra + FOUNDATION + kernel + program conformance + config-setters + load-ordering = probably too many concepts for one review cycle.

BUT: the alternative (land algebra first, kernel later) would leave algebra unrunnable between batches. The datamancer is choosing to land them together. Once.

**Verdict:** ACCEPT WITH A NAMED OBSERVATION. The batch is bigger than the title suggests. That's OK if the reviewer is warned; the title "AST algebra surface" is too narrow for what the batch actually commits.

### N10 (R3). Programs-are-userland + Console/Cache as the only stdlib programs

2026-04-18 entry: "The ONLY two stdlib programs are `:wat/std/program/Console` (single-sink stdout/stderr serializer) and `:wat/std/program/Cache<K,V>` (LRU memoization for AST-encoding hot path; 1 c/s → 7.1 c/s evidence)."

Everything else — Database, metrics, rate-gates, signal converters, CLI, all domain programs — userland.

Rules: six-rule conformance contract (function by keyword path, handles as params, state as return, drop-cascade, no self-pipes, HandlePool for client handles).

Hickey test: Is the cut principled, or is it cherry-picked?

Principled. Console is "hello-world requires stdout serialization across N writers." Cache is "AST-encoding is measurably 7x faster with memoization." Both named with production evidence. Every other candidate (metrics, database, rate-gates) REJECTED with explicit "this is app-specific; not every program wants it."

**Verdict:** ACCEPT. The discipline is visible. The cut is honest — ship what's universal, leave what's domain-shaped to userland. Matches Linux's "bin vs lib vs /usr/local" pattern.

### N11 (R3). Stdlib-as-blueprint discipline

Criterion rewritten (2026-04-18 "Stdlib-as-blueprint framing locked"):
- Expansion uses only core forms.
- Demonstrates a DISTINCT pattern.
- Domain-free.

Pure aliases (Unbind=Bind, Concurrent=Bundle, Then=binary Sequential, Difference=Subtract) fail the demonstration test. Userland macros.

Hickey test: Does the Bigram/Trigram + user-extensible-Pentagram pattern shape the stdlib right?

- Ngram (general form): ACCEPTED.
- Bigram (n=2 named shortcut): ACCEPTED.
- Trigram (n=3 named shortcut): ACCEPTED.
- User's higher-n: `(:my/app/Pentagram xs) = (Ngram 5 xs)` in their own namespace.

**Verdict:** ACCEPT. The pattern is honest. Ship the useful defaults, hand extension to users. Matches Linux's /bin/ls vs user's own /home/me/bin/lsx.

Small concern: is there a principled line between "ship Bigram" and "ship Pentagram"? The datamancer says "ship what users commonly need; they can write their own for rarer cases." This is a stdlib decision, not an algebra decision. Reasonable.

### N12 (R3). Naming discipline — keyword paths with no bare aliases

2026-04-18 entry ("Honesty ratcheted up"): "No bare aliases. Every call to a wat-vm-provided form uses its full keyword path, always — `(:wat/core/define ...)`, `(:wat/core/let* ...)`, `(:wat/algebra/Bundle ...)`."

Hickey test: Is this simple or merely strict?

Arguments for simple: one name per thing, no shadowing-by-symbol-table, no precedence rules. Hash identity is on the full path. Consistent with "no namespace mechanism, just discipline."

Arguments for heavy: every expression in user code is verbose. `(:wat/algebra/Bundle (:wat/core/list ...))` reads like `std::collections::HashMap::new().insert(...)`. Programs become visually cluttered.

But: the alternative (bare aliases with precedence) IS the complection the datamancer killed. Shadowing rules are EASY (everyone knows them) and COMPLECTED (name/precedence braided).

Also: the trading lab and HYPOTHETICAL already read this way. It's the shape of the language NOW.

**Verdict:** ACCEPT. The honesty-over-convenience stance is the Hickey lens applied recursively. The reader ALWAYS knows what path resolves; no hidden resolution at symbol-table level. Matches Clojure's `clojure.core/map` pattern without the fallback.

### N13 (R3). Entry file's two-part shape (config setters then loads)

2026-04-18 "Load-form unification" entry: parser enforces `(:wat/config/set-*!)` setters precede `(:wat/core/load!)` calls. Loaded files can't contain setters.

Hickey test: Does the entry-file shape check earn its place?

The committed config values (`:wat/config/dims`, `:wat/config/capacity-mode`) are LOAD-BEARING — they affect every encoded vector's identity. Hiding them inside a transitive load would make the program's deployment choices non-local.

Forcing setters-first in the entry file is a one-file discipline with a clear read: "EVERY deployment choice is on the first lines of the entry file." Reader sees it at a glance.

**Verdict:** ACCEPT. Well-motivated. The entry-file two-part shape is a small, load-bearing piece of discipline.

### N14 (R3). `:user/main` as entry point

2026-04-18 entry: `:user/main` (not bare `main`). Kernel-required slot under `:user/...` convention. Kernel provides `:wat/...` paths; user provides `:user/...` slots.

Hickey test: Is this principled or contrived?

The earlier draft had "main is a reserved bare name" — a narrow exception. Exceptions are complections. Making it `:user/main` under a slot convention removes the exception.

Future slots named: `:user/shutdown-handler`, `:user/on-signal`.

**Verdict:** ACCEPT. Principled. The `:wat/...` = kernel-provided, `:user/...` = user-provided distinction is honest.

### N15 (R3). Signal enum and signals queue

`:wat/kernel/Signal` enum (:SIGINT, :SIGTERM initially, SIGHUP etc. via proposal). `:user/main` takes four params: stdin, stdout, stderr, signals (QueueReceiver<Signal>).

**Verdict:** ACCEPT. Explicit-signal handling through a queue matches the CSP discipline. No ambient signal handlers. Matches Go's `signal.Notify`.

### N16 (R3). Ambient console accessors removed; stdio threads through parameters

2026-04-18 final entry: removed `:wat/kernel/console-out`, `console-err`, `console-in`. Stdio handles flow through `:user/main`'s four params. Any function that writes to console declares the handle it needs.

Datamancer: "this is the /frustrating/ part of haskell.. so what.. it works.. simple not easy."

**Verdict:** EXEMPLARY. This is the Hickey lens applied to itself. Ambient authority IS the complection. Making every side effect visible at the type is the Haskell IO monad discipline without the monadic overhead. Simple, not easy.

### N17 (R3). WAT-TO-RUST.md seeded

New document: "seed sketch of the COMPILE path: a Rust program consumes wat source and emits Rust source, which rustc compiles to a native binary. Two execution paths, one language."

Scope: the wat-vm has TWO execution paths — interpret (RUST-INTERPRETATION.md) and compile (WAT-TO-RUST.md). Both produce the same semantics.

Hickey test: Is this scope creep or substrate honesty?

Substrate honesty. The interpret path is reference semantics; the compile path is the production target. Having both named makes the "single language, two runtimes" claim operational, not speculative.

**Verdict:** ACCEPT, but note that this is still a SEED. The compile path isn't fully specified. That's OK — it's named as future work.

### N18 (R3). Honest hello-world using Console program + join-to-flush

Previously: wrote to raw stdout. Now: spawns Console program, pops client handle, joins driver to flush before exit.

**Verdict:** Exemplary. The honest example IS the canonical pattern. No shortcut that the reader has to un-learn.

---

## Complection audit — any hiding?

### 1. `:Atom<T>` with T = :Holon

`(Atom some-bundle)` atomizes a bundle. Two encodings possible:
- Direct: structural vector, unbind-recoverable.
- Atomized: opaque-identity vector, EDN-hash seeded.

Are these complected? The changelog: "both legitimate." "Applications choose per use case."

Hickey test: does the reader know which one they're getting?

`(Bundle [x y z])` — direct encoding.
`(Atom (Bundle [x y z]))` — atomized wrapping.

Different ASTs, different vectors, different retrieval. Visually distinct at the call site. Not complected.

But: a reader might not know WHICH to use. "When do I want structural vs opaque identity?" The FOUNDATION section lists four use cases. Clear-enough.

**Verdict:** NOT COMPLECTED. Two different operations, two different calls, two different use cases. Named.

### 2. Blend with expression-valued weights

Blend's weight slots accept any f64 expression, including computed like `(- (/ (dot x y) (dot y y)))`.

Does this couple Blend with arithmetic/measurement in a way that wasn't there before?

Blend's core spec: `threshold(w1·a + w2·b)` where w1, w2 are real. The weights are just f64 values. How they're computed (literal, from dot, from a reckoner, from a user function) is caller-side.

The algebra doesn't care. The encoder sees `(Blend a b 1 -1)` or `(Blend a b 1 (- (/ (dot x y) (dot y y))))` and evaluates the same way — compute the two weights, do the weighted sum, threshold.

**Verdict:** NOT COMPLECTED. The weight slots are f64. Any f64 expression works. Reject/Project compute their coefficients and pass the result; Blend never sees the computation.

### 3. HashMap / Vec / HashSet named identically with Rust's types

The wat UpperCase constructor, `:Type<...>` annotation, and Rust runtime backing share one name each. `HashMap` in wat IS Rust's HashMap under the hood.

Hickey test: is this one-name-one-thing, or is this shadowing Rust semantics in wat?

The 2026-04-18 entry says: "The AST describes what the container IS; the runtime materializes the efficient backing (HashMap / Vec / HashSet from std); `get` goes through that backing. Direct lookup through Rust's runtime backings — no "walk," no cosine, no cleanup."

So `(:wat/std/get my-hashmap k)` compiles to a literal Rust HashMap::get call. The AST says "this is a HashMap"; the runtime materializes the std::HashMap; get goes through std::HashMap::get.

This is honest. The wat AST IS the type declaration; the backing IS the Rust collection; the get IS Rust's get. No abstraction gap.

But: the wat HashMap's AST (Bundle of Bind(k,v) pairs) ALSO has a vector projection via encode. When does encode run vs when does the Rust HashMap back the access?

Answer from FOUNDATION: the AST is the primary representation; the vector is the cached projection. The Rust HashMap backing exists for O(1) structural get; the vector exists for cosine similarity against other HashMap-holons. Two different questions, two different machines.

Wait — is the HashMap's backing ALWAYS materialized, or only when get is called? The changelog says "runtime materializes the efficient backing." This is a performance optimization by the runtime.

Hmm. One HashMap has two parallel materializations: the Rust backing (for O(1) structural get) AND the vector (for cosine). They're both computed from the same AST. Both are caches.

**Verdict:** NOT COMPLECTED, but the dual-caching story needs to be explicit. FOUNDATION says "vector is cached projection" but doesn't name "Rust backing is cached structural access." The dual-cache property is real and honest — but could be called out more clearly.

### 4. The two tiers (UpperCase AST / lowercase Rust primitive)

FOUNDATION's "Two Tiers" — UpperCase forms BUILD AST, lowercase forms RUN Rust. Does this complect construction with execution?

No. This SEPARATES them cleanly. UpperCase is lazy-plan; lowercase is immediate-execute. The only coupling is realization (encoder walks UpperCase AST, dispatches to lowercase).

**Verdict:** NOT COMPLECTED. Decomplection made visible.

### 5. The dual-loader (interpret path + compile path)

RUST-INTERPRETATION.md describes interpret; WAT-TO-RUST.md describes compile. Same wat source, two backends.

Does this complect "what a wat program does" with "how it runs"?

No. This is the same distinction Lisp had: REPL vs compile-to-FASL. The language's semantics are one thing; the execution substrate is another. Having both is normal.

**Verdict:** NOT COMPLECTED. Healthy substrate split.

---

## Per-proposal verdicts (Round 3)

Going through each — mostly ACCEPT since most are closed.

- 058-001 Atom typed + parametric: ACCEPT. Substrate commit defensible.
- 058-002 Blend: ACCEPT. Option B correct; two independent weights unbraided.
- 058-003 Bundle list signature: ACCEPT. Lock the list form.
- 058-004 Difference: ACCEPT REJECTION (rejected; audit record).
- 058-005 Orthogonalize→Reject+Project: ACCEPT. Reframed well; uses :wat/algebra/dot; algebra core shrinks 7→6.
- 058-006 Resonance: ACCEPT REJECTION. Speculative, no production use.
- 058-007 ConditionalBind: ACCEPT REJECTION. Speculative; half-abstraction.
- 058-008 Linear: ACCEPT REJECTION. Identical to Thermometer under 3-arity.
- 058-009 Sequential reframing: ACCEPT. Bind-chain matches primer + trading lab production.
- 058-010 Concurrent: ACCEPT REJECTION. No specialization; context carries meaning.
- 058-011 Then: ACCEPT REJECTION. Arity-specialization.
- 058-012 Chain: ACCEPT REJECTION. Redundant with Bigram.
- 058-013 Ngram + Bigram + Trigram: ACCEPT. Stdlib-as-blueprint pattern.
- 058-014 Analogy: ACCEPT DEFERRED. Honest third state; resumable audit.
- 058-015 Amplify: ACCEPT. Variable emphasis.
- 058-016 Map→HashMap: ACCEPT. Unified get, no cleanup.
- 058-017 Log: ACCEPT. 15+ production uses in trading lab.
- 058-018 Circular: ACCEPT. Proves Blend Option B.
- 058-019 Subtract: ACCEPT. Canonical delta.
- 058-020 Flip: ACCEPT REJECTION. Primer-collision, magic-weight, no use.
- 058-021 Bind (→ CORE-AUDIT): ACCEPT AUDIT. 
- 058-022 Permute (→ CORE-AUDIT): ACCEPT AUDIT.
- 058-023 Thermometer (→ CORE-AUDIT): ACCEPT AUDIT. 3-arity locked.
- 058-024 Unbind: ACCEPT REJECTION. Bind-on-Bind IS Unbind; not worth a name.
- 058-025 Cleanup: ACCEPT REJECTION. Presence is measurement.
- 058-026 Array→Vec: ACCEPT. Integer-keyed HashMap.
- 058-027 Set→HashSet: ACCEPT. Get unified; Bundle alias with Rust backing.
- 058-028 define: ACCEPT. Typed registration.
- 058-029 lambda: ACCEPT. Typed anonymous.
- 058-030 types: ACCEPT. Simplified to 4 heads; no :is-a; no :Any; parametric.
- 058-031 defmacro: ACCEPT. Racket-style hygiene, typed in 058-032.
- 058-032 typed macros: ACCEPT. Extends 031 with AST<T>.

All 29 sub-proposal verdicts land. Zero UNCONVINCED.

---

## Reconciliation-debt pattern — persists in proposal BODIES

Verification pass:

- 058-016 (Map→HashMap): banner clean, BODY still defines `get` as `(cleanup (Unbind ...) candidates)` (lines 106-110, 135-136, 156, 177-182). Body lists `get-raw`. Body's designer-questions section (lines 186-198) still treats it as a live proposal.
- 058-026 (Array→Vec): banner clean, body still uses `nth` (lines 139, 149, 200), Sequential alias encoding (line 159).
- 058-027 (Set→HashSet): banner clean, body still mentions `cleanup`-based retrieval (lines 82, 119, 125, 136).
- 058-030 (types): CLEAN. Banner + body match. `:is-a`, `:Scalar`, `:Null`, `:Any` all explicitly marked removed with reasoning.

The datamancer's pattern: put the resolution in an ACCEPTED/REJECTED/REFRAMED banner at the top, preserve historical body below as audit trail. This preserves the audit trail but LEAVES stale content in the body — the exact reconciliation-debt concern I flagged in R2.

A first-time reader of 058-016 reads the banner (correct), then reads down, and hits `(cleanup (Unbind ...))` at line 178, and the old question list at line 184. They internalize the wrong form unless they remember the banner supersedes.

For R2, this was a pre-commit blocker. For R3: the policy is consistent (banner supersedes body; historical preserved), but the policy should be NAMED at the top of each stale-body proposal with a "---HISTORICAL CONTENT FOLLOWS; SUPERSEDED BY BANNER ABOVE---" line. Currently the transition is ambiguous.

058-030's body was rewritten to match the resolution — that's the gold standard. 058-016, 058-026, 058-027 should follow the same pattern.

## Summary

Round 3 addressed every Round 2 concern I raised. The resolutions are often STRONGER than what I suggested (e.g., parametric types, algebra core shrink from 7→6, 10 rejections, ambient-stdio removal). The rare review cycle where the authors' work landed beyond the reviewer's ask.

New concerns in Round 3: mostly scope creep (kernel primitives in "algebra surface" batch) and substrate commits (parametric polymorphism). Both named honestly; both defensible; neither ducks the cost.

Persistent from R2: reconciliation debt in proposal bodies. Banner supersedes body — but stale body reads wrong. Fix is mechanical: either collapse stale sections under an explicit "HISTORICAL" separator, or rewrite bodies to match banners (as 058-030 did).

Batch verdict: ACCEPT WITH OBSERVATIONS.

Key observations to name:
1. The batch title "AST algebra surface" is narrower than the batch content (kernel primitives, program conformance, config setters, type system, macros, two-tier loader). The title understates the scope.
2. The parametric polymorphism commit is load-bearing but the "programs ARE atoms" production evidence is forward-pointed, not backward-pointed. Next session should validate.
3. The dual-caching of HashMap/Vec/HashSet (Rust backing for O(1) get AND vector projection for cosine) should be named explicitly in FOUNDATION.
4. The algebra's measurements tier (cosine, dot) is a clean decomplection; the tier name could be made more prominent.
5. Reconciliation-debt pattern persists in 058-016, 058-026, 058-027 — banner updated, body stale. Name an explicit "HISTORICAL" separator.
