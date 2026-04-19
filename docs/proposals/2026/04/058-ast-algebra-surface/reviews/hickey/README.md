# Hickey's Review Scratch — Round 3

This directory is for the Rich-Hickey-lens reviewer of the 058 batch.

**Context:** This is the THIRD round of review. Round 1 is at `../archive/hickey-round-1/REVIEW.md`. Round 2 is at `../archive/hickey-round-2/REVIEW.md`. Read Round 2 first — its open items are the foundation of what's being judged here.

## What's changed since Round 2

Round 2 landed with these outstanding concerns:

- Thermometer signature contradiction across docs (R1 carried through).
- Alias proliferation (Concurrent, Set, Array-as-alias, Unbind) despite round-1 rejection.
- Core-affirmation proposals (021, 022, 023, 025) occupying review effort.
- Rust-primitive type sweep hadn't propagated.
- `get` contradiction (stdlib containers defined it as cleanup-based vector ops despite FOUNDATION declaring AST walkers).

Since Round 2, the datamancer did substantive due diligence on every remaining question and landed a series of decisions. The full audit trail is in `../../FOUNDATION-CHANGELOG.md` (append-only, chronologically dated). A summary of what's different:

### Sharp rejections (ten forms REJECTED since Round 2)

Every rejection has a per-proposal REJECTED banner citing the reasoning. The speculative-primitive bar became sharp: "no cited production use" → reject, regardless of classical-VSA heritage.

- **058-006 Resonance** — REJECTED. Speculative. Primer documents it but cites no application.
- **058-007 ConditionalBind** — REJECTED. Speculative; half-abstraction (gate-consumer without gate-producer); 4-mode API is API-exploration fingerprint.
- **058-020 Flip** — REJECTED. Primer's single-arg `flip` and the proposal's 2-arg `Flip(x, y, 1, -2)` were different operations with the same name; magic `-2` weight was a tradition-matching convention, not an algebraic minimum; no cited production use.
- **058-012 Chain** — REJECTED. Redundant with new Bigram stdlib macro (same `Ngram 2 xs` expansion).
- **058-010 Concurrent** — REJECTED (earlier, reconfirmed). Pure alias; no new pattern; temporal-co-occurrence is carried by enclosing context.
- **058-011 Then** — REJECTED. Arity-specialization of Sequential; no new pattern.
- **058-024 Unbind** — REJECTED. Identity alias for Bind; Bind-on-Bind IS Unbind.
- **058-025 Cleanup** — REJECTED. AST-primary framing dissolves it; retrieval is presence measurement (cosine + noise floor), not argmax-over-codebook.
- **058-004 Difference** — REJECTED. Same math as Subtract.
- **058-008 Linear** — REJECTED. Under the new 3-arity Thermometer `(Thermometer value min max)`, Linear is literally Thermometer.

### Substantive reframes since Round 2

- **058-005 Orthogonalize → Reject + Project stdlib.** The computed-coefficient argument for CORE dissolved when Blend accepted as Option B (Q1 reply). Algebra core shrinks 7 → 6. Named to match primer + holon-rs (`reject`, not `orthogonalize`). Also ships `Project` as companion. Uses a new `:wat::algebra::dot` measurement primitive (scalar-returning sibling to `cosine`; not a HolonAST variant).
- **058-001 Atom → parametric Atom<T>.** Substrate-level decision: Atom accepts any serializable T (primitive, composite Holon, user-defined type). Enables programs-as-atoms (opaque-identity vector for any value). This commits the language to **parametric polymorphism across the board** — 058-030 Q1 (generics scope) resolved YES; user types + function signatures + macros all parametric (rank-1).
- **058-002 Blend accepted as Option B.** Two independent real-valued weights, negative allowed, binary arity. Option A's convex constraint identified as a complection. All downstream Blend-idiom macros unblocked.
- **058-009 Sequential reframed to bind-chain.** Primer's "positional list encoder" and trading-lab production both use bind-chain with Permute; the original bundle-sum expansion diverged from both. Corrected.
- **058-013 Ngram reframed + Bigram/Trigram added.** Stdlib-as-blueprint: ship the general form (Ngram) + common named cases (Bigram = n=2, Trigram = n=3). Users write higher-n macros in their own namespace.
- **058-014 Analogy DEFERRED** — new status between ACCEPTED and REJECTED. Proven-working-but-unadopted; preserved as resumable audit record.

### New cross-cutting decisions

- **Programs ARE Atoms** substrate corollary. Any holon can be atomized via parametric Atom, giving it an opaque-identity vector.
- **Core/stdlib division line named:** single Rust method → `:wat::core::`; short composition → `:wat::std::`; app-shaped → userland.
- **No bare aliases.** Dual-tier symbol table removed. Every call uses its full keyword path. `:wat/lang/` renamed to `:wat::core::`.
- **Naming discipline enforced:** `(:wat::core::define ...)`, `(:wat::core::let* ...)`, `(:wat::algebra::Bundle ...)`, etc. Bareword sweep complete across every scheme block in the batch.
- **`:` quoting rule** documented explicitly. `:Atom<holon::HolonAST>` legal; `:Atom<:holon::HolonAST>` illegal. Inside angle brackets, parameters are bare Rust symbols.
- **`:user::main`** as keyword-path entry point, receiving stdin/stdout/stderr/signals as parameters (no ambient capabilities).
- **`:wat::kernel::select`** added; **`:wat::kernel::HandlePool`** promoted to kernel; Topic and Mailbox REJECTED. Config setters entry-file-only, before any `load!`. One loader `:wat::core::load!` for all file kinds.
- **Programs-are-userland** subsection in FOUNDATION codifying the conformance contract (six rules). Only Console and Cache ship as stdlib programs (universal plumbing).
- **`WAT-TO-RUST.md`** seeded — the compile path complementing the interpret path.
- **Honest hello-world** — spawns Console program, joins to flush.

### The Thermometer signature contradiction

Resolved. FOUNDATION, 058-023 (audit), Linear/Log/Circular, HYPOTHETICAL all converged on `(Thermometer value min max)`. The contradiction Hickey Round 2 flagged is closed.

### Alias proliferation

Resolved by rejection. Concurrent, Set-as-alias, Unbind, Then, Flip, Chain all REJECTED. The test Hickey applied in Round 2 — "does a reader lose something when they see the expansion?" — was applied at scale and most failing aliases were cut.

### Core-affirmation proposals

Collapsed. 058-021, 058-022, 058-023 collapsed into `CORE-AUDIT.md` (audit entries, not proposals). No designer questions remain.

---

## Live designer questions

**NONE REMAINING.** All substantive questions across the batch closed on the datamancer's due diligence. `OPEN-QUESTIONS.md` has been swept; `Live questions for Round 3` section reads "NONE REMAINING" with a summary of the resolution state.

Round 3 reviewers may still reopen any decision. The per-question reasoning is preserved in each proposal's ACCEPTED/REJECTED/DEFERRED banner and in changelog entries dated 2026-04-18.

---

## Your working discipline

**Write freely here.** Inventories, per-proposal drafts, dependency tracings, counter-examples, decomplection sketches, complection audits — whatever helps you think. The notes are yours.

Like Round 2, you will likely benefit from:
- A `notes.md` scratch pad to collect evidence as you read.
- Per-topic working files if you trace specific threads (`complection-audit.md`, `rust-correspondence-check.md`, anything).
- A visible inventory of decisions you're accepting vs pushing back on.

The datamancer did this same assembly work — every decision in `FOUNDATION-CHANGELOG.md` represents due diligence captured in prose. You get the same discipline: write down what you're seeing, iterate, commit to a verdict only when the evidence is organized.

**Final artifact:** `REVIEW.md` in this directory. Structured verdict across the batch, same shape as Round 2.

**Read access:** everything in the parent `058-ast-algebra-surface/` directory AND the archive (`../archive/*/`). Your Round 2 REVIEW is at `../archive/hickey-round-2/REVIEW.md` — read it alongside this Round 3 to see what you flagged and whether it landed.

**Write access:** this directory only.

**The lens this round:** Is the algebra simple, in the Hickey sense? Are concepts untangled? Are there complections hiding? Does the parametric-polymorphism substrate commit buy simplicity or paper over it? Does the stdlib earn its names?

The dominant questions you'll likely want to work through:
- **Parametric polymorphism as substrate** — is `:Atom<:T>` the right reach, or is it sneaking in complexity? The datamancer argues it's required for programs-as-atoms; check whether the expansion in implementation scope (HM type-checker, generic enums) is justified by the expressiveness unlocked.
- **Algebra core at six forms** — are they genuinely independent? Does Blend-with-expression-valued-weights create coupling with arithmetic/measurement that wasn't there before?
- **`dot` as a scalar-returning algebra measurement** — is adding a new primitive tier (measurements, orthogonal to HolonAST variants) a clean move or a workaround for something the Blend/Orthogonalize question exposed?
- **Programs ARE Atoms** — does the atomize-a-program pattern earn its place, or is it a theoretical flourish? The datamancer cites production use cases (engram libraries, program similarity, program bundling). Judge.
- **Stdlib-as-blueprint discipline** — is the Bigram/Trigram + user-extensible-Pentagram pattern the right shape for user-extensible named forms, or does it multiply names unnecessarily?
- **The REJECTED-ten pattern** — do the rejections hold? Or is any of them (Resonance, ConditionalBind, Flip, Chain, Analogy-deferred, the others) premature rejection?

You are not required to work through these specific threads. They are the things most likely to yield Round 3 feedback. Follow whatever thread you think matters most.
