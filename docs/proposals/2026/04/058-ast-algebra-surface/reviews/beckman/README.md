# Beckman's Review Scratch — Round 3

This directory is for the Brian-Beckman-lens reviewer of the 058 batch.

**Context:** This is the THIRD round of review. Round 1 is at `../archive/beckman-round-1/REVIEW.md`. Round 2 is at `../archive/beckman-round-2/REVIEW.md`. Round 2 also has `notes.md` showing the working discipline — scratch pad to organized verdict.

## What's changed since Round 2

Round 2 landed with these outstanding concerns:

- **Bundle non-associativity** — the `+1, +1, -1` counter-example at `d=1` produced three different values under the three associations (`+1, 0, +1`). The ternary threshold fixed only the one case flagged in Round 1; general associativity remained broken.
- **Thermometer signature contradiction** — FOUNDATION `(Thermometer value min max)` vs 058-023/008 `(Thermometer atom dim)`.
- **HYPOTHETICAL example migration** — `-> :Thought` signature syntax hadn't propagated.

Since Round 2, the datamancer did substantive due diligence on every remaining question and landed a series of decisions. The full audit trail is in `../../FOUNDATION-CHANGELOG.md` (append-only, chronologically dated). A summary of what's different:

### The similarity-measurement reframe — the load-bearing categorical response

Between Round 2 and Round 3, FOUNDATION added the **"Bind as query; algebra laws restated in similarity-measurement frame"** section. The substance: the algebra was never elementwise-exact — it was always **similarity-measured at Kanerva capacity**. Cosine similarity above a noise threshold (5σ ≈ 5/√d at d=10,000) means "yes, this matches"; below means "no."

Under this framing:

- **Bundle is similarity-associative** under capacity budget. Elementwise non-associative in general, as Round-2's counter-example correctly established. But downstream presence-measurement queries (the operational use of Bundle) succeed identically regardless of association, as long as the query target lives above the noise floor of the composed vector. The three associations of `Bundle([x, y, z])` produce different elementwise vectors but cosine-equivalent answers to any similarity probe. This is the operational associativity the algebra needs, and it is the honest one.
- **Orthogonalize's orthogonality** (now stdlib `Reject`) is similarly reframed — similarity-orthogonal, not elementwise-orthogonal, except at the exact `X = Y` degenerate case which produces all-zero exactly under `threshold(0) = 0`.
- **Bind as query** — Bind's reversibility is measured via similarity above noise. Sparse keys and capacity consumption are unified under the same substrate property.

This is a categorical reframe, not a mechanical fix. The question for Round 3: **does the similarity-measurement frame close the gap Round 2 flagged?** If yes, Bundle-associativity concern dissolves. If no, the batch is still broken.

### The Thermometer signature contradiction

Resolved. FOUNDATION, 058-023 audit, Linear/Log/Circular macro bodies, and HYPOTHETICAL all converged on `(Thermometer value min max)`.

### Parametric polymorphism as substrate — NEW

Between Round 2 and Round 3, the datamancer committed 058 to **parametric polymorphism across the board** — user types, functions, macros, and the algebra's `:Atom<:T>`. Triggered by the "Programs ARE Atoms" substrate corollary: every holon (including composite programs) can be atomized into an opaque-identity vector via parametric Atom. Without parametric polymorphism, programs cannot be atomized; the programs-as-values principle would remain theoretical.

Categorically:
- `Atom : (T : Serializable) → :Holon` — parametric constructor. Hash respects coproduct structure: `hash(type-tag, canonical-EDN(value))`.
- Extraction `atom-value : :Atom<:T> → :T` — polymorphic, type inference at call site.
- User types can be parametric: `newtype`, `struct`, `enum`, `typealias` all accept type parameters.
- Functions can carry type variables in rank-1 HM signatures.

The question for Round 3: **does the parametric structure compose cleanly with the algebra?** `Atom<Holon>` is a recursive type (Holon contains Atom); is that categorically sound? The datamancer claims yes — `Atom` is a coproduct constructor over an open payload universe, and the universe includes `:Holon` itself. The hash respects the coproduct at every depth.

### Algebra core shrinks 7 → 6

**058-005 Orthogonalize** reframed to stdlib macros `Reject` + `Project` over Blend + a new `:wat::algebra::dot` measurement primitive. The datamancer introduces a scalar-returning measurement tier alongside HolonAST-producing core variants. Categorically: `cosine : :Holon × :Holon → :f64` and `dot : :Holon × :Holon → :f64` are bilinear measurements, orthogonal to the vector-producing HolonAST variants. This is a new categorical tier.

### The rejection pattern

Ten forms REJECTED since Round 2: Resonance, ConditionalBind, Flip, Chain, Concurrent, Then, Unbind, Cleanup, Difference, Linear. The consistent reasoning: "speculative primitive with no cited production use" or "redundant with an accepted form." Each has a per-proposal REJECTED banner.

**Analogy DEFERRED** — new status between ACCEPTED and REJECTED. Proven-working-but-unadopted; preserved as resumable audit record. Classical VSA operation without current production citation.

### New decisions relevant to composition

- **Sequential reframed** — bind-chain (compound), not bundle-sum (superposition). Matches the primer's "positional list encoder" and trading-lab production.
- **Ngram reframed + Bigram/Trigram added** as stdlib shortcuts.
- **Blend accepted as Option B** — independent real-valued weights, negative allowed, binary. The convex constraint (Option A) was identified as a complection.

---

## Live designer questions

**NONE REMAINING.** All substantive questions across the batch closed on the datamancer's due diligence. `OPEN-QUESTIONS.md` has been swept; `Live questions for Round 3` section reads "NONE REMAINING."

Round 3 reviewers may still reopen any decision. The per-question reasoning is preserved in each proposal's ACCEPTED/REJECTED/DEFERRED banner and in changelog entries dated 2026-04-18.

---

## Your working discipline

**Write freely here.** The notes are yours. Round 2 showed the shape: you wrote `notes.md` with 406 lines of working prose and counter-examples; the REVIEW at 597 lines emerged from that organized thinking. Do the same here.

Likely useful working files:
- `notes.md` — running scratch for observations, counter-examples, categorical checks.
- `laws.md` or `composition-check.md` — if you want to systematically verify associativity, commutativity, unit laws, inverses across the (now smaller) core.
- `parametric-check.md` — the Atom<T> parametric commit is the biggest categorical delta. Check it.
- `measurement-tier.md` — the cosine/dot measurement tier is a new orthogonal addition. Categorically clean?

**Final artifact:** `REVIEW.md` in this directory. Structured verdict across the batch, same shape as Round 2.

**Read access:** everything in the parent `058-ast-algebra-surface/` directory AND the archive (`../archive/*/`). Your Round 2 REVIEW is at `../archive/beckman-round-2/REVIEW.md`; your Round 2 notes are at `../archive/beckman-round-2/notes.md`. Read both alongside this Round 3 to see your prior work.

**Write access:** this directory only.

**The lens this round:** Does the algebra compose? Do the laws hold under the similarity-measurement reframe? Is the parametric-polymorphism substrate categorically sound? Does the new measurement tier (cosine, dot) preserve the algebra's structure? Does the stdlib-macro expansion pipeline produce categorically canonical ASTs?

The dominant questions you'll likely want to work through:
- **The similarity-measurement frame as the answer to Round-2 associativity**. Either this closes the concern or it doesn't. Judge.
- **Parametric Atom and the coproduct structure**. Is hash-over-EDN(T) a functor of T? What's the invariance claim when T is itself a Holon? Is there a categorical soundness problem in the recursion?
- **Blend Option B with negative weights**. Earlier Round-2 flagged Option B as a natural linear-map generalization of Bundle's monoid. Does keeping Bundle-as-monoid and Blend-as-linear-map cleanly (no variadic Blend) preserve the canonical MAP set?
- **`:wat::algebra::dot` and the measurement tier**. Does adding scalar-returning operations as a parallel tier preserve the algebra's independence, or does it couple vector-producing forms to scalar computation?
- **The REJECTED ten** — Resonance, ConditionalBind, Flip, etc. — do the rejections hold categorically? Or is the algebra missing an operation it needs for composition at some depth?
- **Sequential bind-chain semantics** — the compound-vector vs superposition choice matters for Ngram composition. Does the bind-chain form preserve the operations Ngram performs against it?

You are not required to work through these specific threads. Follow whatever thread matters most.
