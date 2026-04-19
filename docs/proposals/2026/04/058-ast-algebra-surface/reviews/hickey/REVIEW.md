# Review — 058 AST Algebra Surface (Round 3)

A Hickey-lens third pass. Round 1 lives in `../archive/hickey-round-1/REVIEW.md`; Round 2 in `../archive/hickey-round-2/REVIEW.md`. Scratch-pad notes from this round in `notes.md`.

---

## Summary verdict

**ACCEPT WITH OBSERVATIONS.**

Round 3 did the reconciliation work I asked for in Round 2, and in most cases went further than the ask. Every Round 2 concern I raised has a landed resolution, and the resolutions are substantive — not papered over. The sharp-rejection pattern (ten forms cut, each with a banner citing the specific reason) is the datamancer applying my Round 2 "does a reader lose something when they see the expansion?" test at scale. The substrate-level commits (parametric polymorphism, six-form algebra core, measurements tier, ambient-stdio removal) are disciplined decomplections rather than expansions.

The batch ships. What I am flagging here is second-order: scope creep that the batch title understates; one load-bearing claim (programs-are-atoms) whose production evidence is forward-pointed; reconciliation debt that persists in three proposal bodies even though their banners are correct. None of this blocks the commit; all of it is an afternoon of mechanical cleanup.

The three rounds of review converged. The algebra at six forms, the stdlib as blueprint, the language core at eight forms, the measurements tier, the kernel-primitives set — these are simple in the Hickey sense, where simple means unentangled concepts that each stand alone.

---

## Round-2 concerns — resolution status

### RESOLVED (R2 → R3)

**R2 concern: Thermometer signature contradiction across six docs.**
→ **RESOLVED.** 058-023 collapsed to CORE-AUDIT.md which states the 3-arity signature `(Thermometer value min max)` with canonical layout (first N dims +1, remaining d-N dims -1) locked as non-negotiable for distributed verifiability. FOUNDATION's complete-forms section, all Linear/Log/Circular expansions, RUST-INTERPRETATION, and HYPOTHETICAL converged. The bit-identical-across-nodes claim is preserved in the audit document. 2026-04-18 changelog entry "Thermometer canonical layout documented" explicitly cites this as the N5 resolution.

**R2 concern: `get`/`nth` contradicting across FOUNDATION (AST walker) and Map/Array proposals (cleanup+Unbind).**
→ **RESOLVED.** 2026-04-18 "Container constructors renamed" entry unifies `get` across HashMap, Vec, HashSet with signature `(get container locator) -> :Option<Holon>`. Direct structural lookup via each container's Rust runtime backing (HashMap::get, Vec index, HashSet::get). No cleanup, no Unbind, no codebook. `nth` retired. The R2 "single most dangerous unresolved contradiction" is closed. (Reconciliation debt persists in three proposal bodies — see Round-3 issues below — but the FOUNDATION claim is clean.)

**R2 concern: Alias proliferation (Concurrent, Set-as-alias, Unbind, Then, Flip, Chain).**
→ **RESOLVED VIA SHARP REJECTION.** Ten forms REJECTED since Round 2, each with a per-proposal banner citing specific reasoning and a FOUNDATION-CHANGELOG entry. The Round 2 test ("does a reader lose something when they see the expansion?") was applied at scale. The datamancer's framing in the 2026-04-18 "Stdlib-as-blueprint framing locked" entry rewrote the stdlib criterion from the weak "reduces ambiguity for readers" to three concrete conditions (expansion uses only core forms; demonstrates a distinct pattern; domain-free). The rejected forms fail the demonstration test. Userland macros preserved as the extension path. This is decomplection via deletion — simpler than the alternative.

**R2 concern: Core-affirmation proposals (021, 022, 023, 025) occupying designer attention.**
→ **RESOLVED.** 058-021, 058-022, 058-023 collapsed into CORE-AUDIT.md as audit entries (operation, canonical form, MAP/VSA role, downstream conventions). No proposal-shaped argumentation. 058-025 (Cleanup) REJECTED because the AST-primary framing dissolves the need for codebook-based recovery. Zero designer questions remain on any of these.

**R2 concern: Rust-primitive type sweep (`:Scalar`/`:Int`/`:Bool`/`:Null`) hadn't propagated.**
→ **RESOLVED.** 2026-04-18 "Type grammar locked to Rust-surface form" entry plus the separate 140-scheme-block bareword sweep. `:f64`, `:usize`, `:i32`, `:bool`, `:()`, `:List<T>`, `:HashMap<K,V>`, `:Option<T>` throughout. `:Any` dropped entirely; `:Null` dropped entirely. 058-030 rewritten to match.

**R2 concern: `deftype` with `:is-a` syntactic ambiguity (R2 N4).**
→ **RESOLVED STRONGER THAN ASKED.** The datamancer went further than the three-head split I suggested. `deftype` dropped. Four distinct head keywords: `newtype` (nominal), `struct` (product), `enum` (coproduct, the polymorphism mechanism), `typealias` (structural alias). `:is-a` keyword dropped entirely — no nominal subtyping. The "every Atom is a Holon" relationship is expressed through the `:Holon` enum's variant set, pattern-matched directly (same as Rust's `match holon { HolonAST::Atom(lit) => ... }`). Zero ambiguity at parse. Simpler than three heads.

**R2 concern: `defmacro` deferred hygiene/provenance/debugging story (R2 N2).**
→ **LARGELY RESOLVED.** 058-031 ships with Racket-style sets-of-scopes hygiene (Flatt 2016) — every Identifier carries a scope set, binding resolution uses (name, scope-set) pairs, variable capture is structurally impossible. This replaces the earlier "start unhygienic, add hygiene later" recommendation. Datamancer's call: "macro expansion must be safe." 058-032 adds typed macros (`:AST<T>` with macro-authoring-time type checking). The macro-set-versioning story is addressed in 058-031's "Provenance — Macro-Set Versioning and Distributed Consensus" section. What remains deferred: introspection (`macroexpand`) and some debugging tooling, each named and scoped. That is the right stance.

**R2 concern: `:Any` polymorphism erosion risk (R1 hammock #5).**
→ **RESOLVED.** `:Any` dropped from the grammar. Every apparent use case has a principled replacement: `:Holon` for any algebra value, `:Union<T,U,V>` for closed heterogeneous sets, parametric `T`/`K`/`V` for generic containers, `:List<Pair<Holon,Vector>>` for engram libraries. The type universe is closed — no escape hatch — which is what makes startup verification total.

**R2 concern: Thermometer atom-to-fractional-position convention (R2 N5).**
→ **RESOLVED.** Locked: `N = round(d · clamp((v-min)/(max-min), 0, 1))`; first N +1, remaining -1. Bit-identical across nodes. Cosine geometry `1 - 2·|a-b|/(mx-mn)` exact. Already running in production in holon-rs across 652k BTC candles.

**R2 concern: Output-space ternary sweep (R2 N3) — forms still talking bipolar.**
→ **RESOLVED VIA REJECTION.** The form that still talked bipolar (058-006 Resonance) was REJECTED. The ternary sweep lands in the remaining forms cleanly.

### PARTIALLY RESOLVED

**R2 concern: Keyword-path naming as substitute for namespaces.**
→ **MECHANISM CLARIFIED, CONVENTION HARDENED.** 2026-04-18 "Naming Discipline consolidation" collapses the two prior statements into one canonical section. 2026-04-18 "Honesty ratcheted up" entry removes the dual-tier symbol table entirely — no bare aliases, every kernel/algebra/language-core/stdlib call uses its full keyword path always. The argument for this ("honesty over convenience; simple not easy; frustration IS the discipline") is explicit in the changelog. But the remaining concern stands: with parametric polymorphism added (see below), the pressure to add namespace aliases will grow. Today the discipline holds because the language is small and still being shaped; tomorrow a project with 200 sub-vocabularies will want `import as`. This is future work, not a commit blocker.

### UNRESOLVED

(None at the FOUNDATION level.)

---

## New Round-3 issues

### R3-1. Reconciliation debt persists in three proposal bodies

R2 flagged stale body content in proposals whose banners had been updated. R3 applied this pattern systematically — banner supersedes body; body preserved as audit trail. 058-030 (types) did the gold-standard thing: rewrote body to match banner. Three proposals still have stale body content that a first-time reader will internalize:

- **058-016 (Map → HashMap).** Banner is clean. Body lines 106-110, 135-136, 156, 177-182 still define `get` as `(cleanup (Unbind ...) candidates)` — contradicting the banner's "no cleanup, no Unbind, no codebook" contract. Lines 184-198 still present the old designer questions as live. Pre-commit: either rewrite body to match banner, or add an explicit "--- HISTORICAL CONTENT; SUPERSEDED BY BANNER ABOVE ---" separator.

- **058-026 (Array → Vec).** Banner is clean (including "nth is retired"). Body lines 139, 149, 200 still reference `nth` as an operation; line 159 still describes the old Sequential-alias encoding. Same fix.

- **058-027 (Set → HashSet).** Banner is clean. Body lines 82, 119, 125, 136 still talk about `cleanup`-based retrieval. Same fix.

Mechanical pass. Not a designer question.

### R3-2. Batch title "AST algebra surface" understates scope

058 now commits: the 6-form algebra core, the measurements tier (cosine, dot), the 18-form stdlib, the 8-form language core (including `defmacro` and typed macros), the type system (4 heads, parametric polymorphism), the kernel primitives (queue, send/recv, spawn, join, select, HandlePool, Signal), the config-setter tier (`:wat/config`), the two stdlib programs (Console, Cache), the conformance contract (six rules for programs-are-userland), the startup pipeline, the entry-file shape, the interpret path (RUST-INTERPRETATION.md), and the compile path (WAT-TO-RUST.md as seed).

This is substantive substrate, not just an algebra surface. A future reader arriving at the title "058-ast-algebra-surface" and the repository-level claim that this batch is "algebra extension" will be surprised by the kernel primitives section in FOUNDATION.md (~430 lines).

Observation, not a blocker. A note in INDEX.md's purpose line that the batch's scope grew to include substrate and kernel would serve the first-time reader.

### R3-3. Parametric polymorphism's production evidence is forward-pointed

This is the single biggest substrate commit in R3. 2026-04-18 "Parametric polymorphism as substrate" entry commits the language to rank-1 HM polymorphism across `:Atom<T>`, user types, functions, and macros. The justification: "Programs ARE Holons" requires the ability to **atomize** a program — wrap a composite Holon in `:Atom<Holon>` to receive an opaque-identity vector — which requires Atom be parametric in T.

The motivation is sound. The claim that "without parametric Atom, programs cannot be library-keyed, cannot be compared cosine-wise, cannot be Bound to metadata" is operationally correct. The commit is principled: rank-1 only, no higher-kinded types, no bounds, no existentials — the complexity is paid only for what's needed.

The observation: no current 058 proposal shows a **working production example** of atomized programs. HYPOTHETICAL-CANDLE-DESCRIBERS demonstrates programs-as-holons; the engram library of learned programs is aspirational across DDoS and trading labs. The substrate-level defense ("the algebra requires it to be honest about programs-as-values") is compelling but forward-pointing — the applications cited (engram libraries of attack signatures, trading observer patterns, MTG deck archetypes) are future work.

This is not speculative-primitive in the same sense that Resonance and ConditionalBind were; parametric polymorphism is well-understood mathematics with bounded implementation cost. But the cost is real — an HM type-checker pass in holon-rs, parametric type instantiation at startup, parametric macros at parse time.

Not a commit blocker. An observation: next session's work should surface at least one production use of atomized programs to retire the "substrate-not-speculation" defense. Without that evidence in the next round, the commit will read as future-proofing dressed as foundational.

### R3-4. Dual-caching of containers (Rust backing + vector projection) not named explicitly

HashMap / Vec / HashSet each have TWO parallel materializations from their AST:
- **Rust backing** (`std::HashMap`, `std::Vec`, `std::HashSet`) for O(1) structural `get`.
- **Vector projection** (via `encode`) for cosine similarity and other VSA operations.

Both are caches of the same AST. Both are computed at realization time. Both coexist in the runtime.

FOUNDATION's "AST is primary, vector is cached projection" framing names only the vector side. The Rust backing is implicit — mentioned in the container constructor entries ("runtime materializes the efficient backing") but not elevated as a substrate property.

The dual-caching is honest and the right split — structural questions go through the Rust backing (fast, exact, O(1)); similarity questions go through the vector (fuzzy, capacity-bounded, cosine-measured). Two different questions, two different machines, both rooted in the same AST.

Pre-commit: name this in FOUNDATION. "The AST is primary. The Rust backing is its cached structural representation. The vector is its cached geometric projection. Both are caches — both rebuild from the AST; neither holds identity." That is the honest framing.

### R3-5. The measurements tier could be more prominent

FOUNDATION now names two tiers of primitive:
- **Holon-producing** core forms (6 variants: Atom, Bind, Bundle, Blend, Permute, Thermometer).
- **Scalar-returning** measurements (cosine, dot) — operate on Holons but return `:f64`.

The measurements tier appears only under "Algebra Measurements — scalar-returning primitives (not HolonAST variants)" (a sub-section of "The Algebra — Complete Forms"). It is load-bearing — Reject/Project both depend on `dot`; presence measurement depends on `cosine`; the 5σ noise floor gating depends on cosine.

The tier split is a clean decomplection. Holon-producing primitives make new Holons; measurements observe existing Holons as scalars. Different categories of operation; different return types; different algebraic roles.

Pre-commit: lift the measurements tier to a top-level section or a "Two kinds of primitive" subsection under "Two Tiers of wat." The current placement buries the split inside an algebra-forms listing where it reads as a side-note.

Not a commit blocker. A readability concern.

---

## Per-proposal verdicts

| # | Form | Class | Status | Verdict | One-line reasoning |
|---|---|---|---|---|---|
| 001 | Atom typed + parametric | CORE | ACCEPTED | ACCEPT | Parametric over any serializable T; substrate for programs-as-atoms. |
| 002 | Blend | CORE | ACCEPTED | ACCEPT | Option B correct; two independent weights unbraided; Circular proves it. |
| 003 | Bundle list signature | CORE | ACCEPTED | ACCEPT | List-taking convention locked; ternary associativity under similarity. |
| 004 | Difference | — | REJECTED | ACCEPT rejection | Same math as Subtract; no new pattern. |
| 005 | Orthogonalize → Reject + Project | STDLIB | ACCEPTED (reframed) | ACCEPT | Gram-Schmidt duo over Blend + new `dot`; core shrinks 7→6. |
| 006 | Resonance | — | REJECTED | ACCEPT rejection | Speculative; no cited production use; Mask is a better primitive. |
| 007 | ConditionalBind | — | REJECTED | ACCEPT rejection | Speculative; half-abstraction (consumes gate without producer). |
| 008 | Linear | — | REJECTED | ACCEPT rejection | Identical to Thermometer under 3-arity signature. |
| 009 | Sequential (reframed) | STDLIB | ACCEPTED | ACCEPT | Bind-chain matches primer and trading-lab production. |
| 010 | Concurrent | — | REJECTED | ACCEPT rejection | No runtime specialization; enclosing context carries temporal meaning. |
| 011 | Then | — | REJECTED | ACCEPT rejection | Arity-specialization of Sequential; demonstrates nothing new. |
| 012 | Chain | — | REJECTED | ACCEPT rejection | Redundant with Bigram under the Ngram reframe. |
| 013 | Ngram + Bigram + Trigram | STDLIB | ACCEPTED (reframed + shortcuts) | ACCEPT | Stdlib-as-blueprint pattern well-applied. |
| 014 | Analogy | — | DEFERRED | ACCEPT deferral | Proven working; no current application; resumable audit record. |
| 015 | Amplify | STDLIB | ACCEPTED | ACCEPT | `Blend(x, y, 1, s)`; variable emphasis. |
| 016 | Map → HashMap | STDLIB | ACCEPTED (renamed) | ACCEPT with body rewrite | Banner clean; body still has cleanup/Unbind contradictions — see R3-1. |
| 017 | Log | STDLIB | ACCEPTED | ACCEPT | 15+ concrete uses in trading lab; production-grounded. |
| 018 | Circular | STDLIB | ACCEPTED | ACCEPT | Time-vocab evidence; proves Blend Option B since `cos+sin ≠ 1`. |
| 019 | Subtract | STDLIB | ACCEPTED | ACCEPT | Canonical delta; 058-004 rejection makes this the single form. |
| 020 | Flip | — | REJECTED | ACCEPT rejection | Primer collision + magic weight + no production use. |
| 021 | Bind | CORE | AUDITED | ACCEPT audit | See CORE-AUDIT.md. |
| 022 | Permute | CORE | AUDITED | ACCEPT audit | See CORE-AUDIT.md. |
| 023 | Thermometer | CORE | AUDITED | ACCEPT audit | See CORE-AUDIT.md; 3-arity locked, canonical layout documented. |
| 024 | Unbind | — | REJECTED | ACCEPT rejection | Bind-on-Bind IS Unbind; a fact about the algebra, not a name. |
| 025 | Cleanup | — | REJECTED | ACCEPT rejection | AST-primary framing dissolves it; retrieval is presence measurement. |
| 026 | Array → Vec | STDLIB | ACCEPTED (renamed) | ACCEPT with body rewrite | Banner clean; body still references `nth` and old encoding — see R3-1. |
| 027 | Set → HashSet | STDLIB | ACCEPTED (renamed) | ACCEPT with body rewrite | Banner clean; body still references cleanup-based retrieval — see R3-1. |
| 028 | define | LANG CORE | ACCEPTED | ACCEPT | Typed registration; `->` return syntax; keyword-path names. |
| 029 | lambda | LANG CORE | ACCEPTED | ACCEPT | Typed anonymous functions with closure capture. |
| 030 | types | LANG CORE | ACCEPTED | ACCEPT | Rust-surface primitives; four declaration heads; no `:is-a`; parametric polymorphism. |
| 031 | defmacro | LANG CORE | ACCEPTED | ACCEPT | Racket-style sets-of-scopes hygiene; startup-pipeline integration. |
| 032 | typed-macros | LANG CORE | ACCEPTED | ACCEPT | `:AST<T>` with macro-authoring-time type checking; extends 031. |

**Zero UNCONVINCED verdicts.** Three ACCEPT with body-rewrite notes. Ten REJECT-confirmations. Three AUDIT-confirmations. One DEFERRED-confirmation. Seventeen clean ACCEPTs.

---

## Architectural observations

### 1. The sharp-rejection pattern is the right discipline

Ten REJECTED banners, each with a named reason and a FOUNDATION-CHANGELOG entry dated 2026-04-18. This is the cost-of-a-name discipline made visible. Every rejected form explains:
- What it did.
- Why it fails the demonstration test or production-use bar.
- Where userland may define it if needed.

The userland-escape-hatch is important — rejection doesn't erase the option; it moves the option to the caller's namespace where the name-cost is borne by the caller. This is exactly how a language grows responsibly: ship the minimum, let users add the rest, observe what earns a promotion.

### 2. The algebra at six forms is honestly minimal

Atom, Bind, Bundle, Blend, Permute, Thermometer. No form is derivable from the others:

- **Atom** is hash-to-vector seed — a deterministic primitive encoder.
- **Bind** is elementwise product — the multiplicative leg of MAP.
- **Bundle** is thresholded sum — the additive leg of MAP.
- **Permute** is dimension-shuffle — positional encoding, invertible.
- **Thermometer** is gradient — the scalar-to-vector bridge.
- **Blend** is scalar-weighted binary combine — the parameterized combination.

Each stands alone algebraically. The measurements tier (cosine, dot) is orthogonal — scalar-out, not Holon-out. The stdlib is built on top of these six. The framing is as minimal as it can be while still covering what the production labs need.

### 3. The two-tier (UpperCase AST / lowercase Rust) split does real decomplection work

The split separates "construct a plan" from "execute now." Users write UpperCase; encoders walk UpperCase and dispatch to lowercase primitives. The laziness property, the cryptographic-identity property, and the user-writable-stdlib property all follow from this split.

It is the same pattern Clojure applies to data vs. functions (`(list 1 2 3)` is a plan; `(eval ...)` executes) — but applied to the algebra layer itself. The AST is data; the vector is what you get when you ask for it.

### 4. The ambient-stdio removal is the Hickey lens applied to the team's own work

The R3 final entry removed ambient `:wat/kernel/console-out`/`console-err`/`console-in` accessors. Every stdio handle now threads through function parameters explicitly. The justification: "ambient authority is exactly the dishonesty wat's type system is meant to prevent."

This is the Hickey test recursively applied: is the implicit-access convenient (easy) or unentangled (simple)? Easy. So remove it. Make every side-effect visible at the type.

This is the pattern I would hope to see at every layer. Applied here, it produces code that reads like Haskell IO without the monadic overhead — simple, not easy. The datamancer's note ("this is the /frustrating/ part of haskell.. so what.. it works.. simple not easy") names the discipline explicitly.

### 5. The stdlib-as-blueprint framing makes the criterion teachable

The R3 rewrite of the stdlib criterion from "reduces ambiguity for readers" (weak — any name does this) to three conditions (expansion uses only core forms; demonstrates a distinct pattern; domain-free) is a genuine improvement. The criterion is now USABLE — a proposal author can read it and decide whether their form belongs.

The Bigram/Trigram-as-named-shortcuts + user-defined-Pentagram pattern is the right shape. Ship the common cases; hand extension to users; don't multiply stdlib names to cover every instantiation.

### 6. The FOUNDATION-CHANGELOG.md extraction is a process improvement

Pulling the 60+ dated change entries out of FOUNDATION.md into its own file frees FOUNDATION to focus on load-bearing claims. The changelog is where the "how did we decide this?" story lives; FOUNDATION is where "what is true now?" lives. Same separation VISION.md gets for speculative framings. Three documents, three scopes. Good discipline.

### 7. The rejection-ten survived scrutiny

I spot-checked each rejection banner. They hold:

- **Resonance (006)** — no production citation; the Mask primitive is the correct level of abstraction if the need ever arises.
- **ConditionalBind (007)** — 4-mode API fingerprint of exploratory exploration; half-abstraction.
- **Linear (008)** — literally equal to `(Thermometer value min max)` under the 3-arity reframe.
- **Concurrent (010)** — no runtime specialization; enclosing context carries temporal meaning.
- **Then (011)** — arity-specialization; no new pattern.
- **Chain (012)** — `Chain xs` = `Ngram 2 xs` = Bigram; redundant.
- **Flip (020)** — primer collision + magic `-2` + no production use.
- **Unbind (024)** — Bind-on-Bind IS Unbind; a fact about the algebra, not a name worth projecting.
- **Cleanup (025)** — AST-primary framing dissolves the need; retrieval is presence measurement.
- **Difference (004)** — same math as Subtract; no new pattern.

All ten rejections are sound. No premature rejection. If anything, the bar was applied evenly — the sharp-rejection pattern caught three forms that Round 2 had flagged but not killed (Concurrent, Then, Unbind) and three more the datamancer found on their own sweep (Linear, Chain, Flip).

---

## Final note

Round 3 is the rare review cycle where the reviewer's open items closed on the authors' due diligence — and the closures were often stronger than what was asked. Parametric polymorphism as substrate, algebra core shrinking to six, ten alias rejections, `:deftype` dissolved into four distinct heads, ambient-stdio removed, honest hello-world, Model A substrate made load-bearing — each move is a decomplection.

The open items that remain are second-order and mechanical: three proposal bodies to sweep against their banners, a batch title that understates scope, a measurements tier that deserves more prominence, and a dual-caching property that should be named explicitly in FOUNDATION. None of these blocks the commit. An afternoon of mechanical reconciliation plus a light editing pass on FOUNDATION closes them.

**The batch is ready. The algebra at six forms is simple in the Hickey sense — unentangled concepts that each stand alone. The stdlib is a blueprint. The kernel is minimal. The language is honest. Ship it.**

---

*Round 3 review completed 2026-04-18, applying the Hickey lens.*

*these are very good thoughts. PERSEVERARE.*
