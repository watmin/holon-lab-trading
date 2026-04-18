# 058 — Categorical Review, Round 2

**Reviewer lens:** Brian Beckman — composition, laws, duals, parametricity.
**Scope:** FOUNDATION.md + 31 sub-proposals (one added since round 1) + RUST-INTERPRETATION.md + HYPOTHETICAL-CANDLE-DESCRIBERS.wat.
**Precedent:** round-1 REVIEW at `../archive/beckman-round-1/REVIEW.md`.
**Conclusion first, then the work.**

---

## Summary verdict

Round 2 makes significant progress on three of the five round-1 findings. The ternary output space (`threshold(0) = 0`) is the right substrate choice. The capacity-budget reframing is honest and operationally sound. The `defmacro` addition is the standard Lisp answer and it cleanly resolves the alias hash-collision concern. The variance rules are stated correctly. **But the batch claims Bundle is associative, and it is not.** A one-line counter-example (`+1, +1, -1` at `d=1`) produces three different results under the three possible associations. The ternary threshold only fixes the specific case I flagged in round 1 (`+1, -1, -1`) — it does not restore associativity in general. This claim is load-bearing for Chain, Ngram, and nested Sequentials and must be retracted. Two additional round-2 issues: (a) a substantive contradiction between FOUNDATION's `(Thermometer value min max)` and 058-023/008's `(Thermometer atom dim)` — two primitives share one name; (b) the HYPOTHETICAL example was not migrated to the new `-> :Thought` signature syntax. The rest of the batch is, as round 1 said, 80% correct; round 2 moved it to ~90%. The remaining 10% is where composition has to work, so it matters.

---

## Round-1 findings — resolution audit

### Finding #1 — Bundle non-associative

**Round-1 claim:** Bundle is not associative under bipolar threshold; `threshold(0)` convention picked arbitrarily.

**Round-2 claim:** ternary threshold (`threshold(0) = 0`) fixes it. FOUNDATION §"The Output Space" lines 1318-1325 gives a specific example:

> For `x = +1, y = -1, z = -1`:
>   `Bundle([x,y,z]) = threshold(-1) = -1`
>   `Bundle([Bundle([x,y]), z]) = Bundle([0, -1]) = threshold(-1) = -1`

This specific case works. **But it generalizes.**

**Verdict: UNRESOLVED.**

**Counter-example** (`d = 1`, ternary threshold, `threshold(0) = 0`):

Let `x = +1, y = +1, z = -1`. Compute three associations:

- **Flat:** `Bundle([+1, +1, -1]) = threshold(+1 + +1 + -1) = threshold(+1) = +1`
- **Left:** `Bundle([Bundle([+1, +1]), -1]) = Bundle([threshold(+2), -1]) = Bundle([+1, -1]) = threshold(0) = 0`
- **Right:** `Bundle([+1, Bundle([+1, -1])]) = Bundle([+1, threshold(0)]) = Bundle([+1, 0]) = threshold(+1) = +1`

Three routes, two different values: **+1, 0, +1**. Bundle is still not associative.

**The ternary threshold only fixes the `threshold(0)` ambiguity at the middle step.** It does not restore associativity where the intermediate sum has magnitude ≥ 2. The threshold is STILL lossy; it discards magnitudes greater than 1. When re-summed with subsequent contributions, the lost magnitude produces a different result.

The root cause: `threshold` is a non-linear projection. It commutes with permutation but NOT with addition. `threshold(a) + threshold(b) ≠ threshold(a+b)` in general. Bundle = `threshold ∘ sum`, and `threshold` cannot be distributed through partial sums.

**The only way Bundle is associative is if thresholding is deferred until the outermost level.** `Bundle([Bundle([a,b]), c]) = threshold(sum_pre_threshold(a,b) + c)`. But that requires representing pre-threshold intermediates, which FOUNDATION's stated semantics do not do.

**FOUNDATION's line 1318 — "Bundle is associative" — is false.**

The pragmatic framing in §"Capacity is the universal measurement budget" works better: Bundle's non-associativity is **similarity-measured drift** under the capacity budget. Two associations produce vectors that are *cosine-close* for high `d`; they are not *elementwise-equal*. That honest framing should replace the associativity claim.

**Required amendment to FOUNDATION:**

Remove "associative" from the Bundle properties (line 1283, line 1318). Replace with:

> **Bundle is n-ary commutative. It is NOT associative in general — intermediate thresholds lose magnitude information above the ±1 range. For dense inputs with per-frame count well below capacity, the post-threshold similarity between different associations is above the 5σ noise floor, so Bundle behaves associatively **in similarity**, not elementwise.**

And add the law:

> **L6 (Bundle non-associativity, formalized):** For ternary `x_i ∈ {-1, 0, +1}`, `Bundle(Bundle(xs), y)` and `Bundle(xs ++ [y])` coincide elementwise iff no intermediate partial sum has magnitude ≥ 2 at any dimension. Otherwise they differ at that dimension, with cosine-similarity bounded by the capacity budget at `d`.

### Finding #2 — Orthogonalize post-threshold orthogonality

**Round-1 claim:** `X - projY(X)` is orthogonal to Y pre-threshold; post-threshold, orthogonality is lost (counter-example: `X = Y = [+1,+1,+1,+1]` produces `threshold([0,0,0,0]) = [+1,+1,+1,+1]` with bipolar threshold).

**Round-2 claim:** ternary threshold fixes it. `[0,0,0,0]` stays `[0,0,0,0]` which is orthogonal to Y. 058-005 line 27: "exactly orthogonal, not 'up to threshold noise'."

**The round-1 specific counter-example IS resolved.** For `X = Y`, the subtracted vector is all zeros and stays zeros under ternary threshold. Dot with Y = 0. ✓

**But the general claim is still false.**

**Counter-example** (d=4, ternary threshold):

`X = [+1, +1, +1, -1]`, `Y = [+1, +1, +1, +1]`.

- `X·Y = 1+1+1-1 = 2`
- `Y·Y = 4`
- coeff = 2/4 = 0.5
- `X - coeff·Y = [+0.5, +0.5, +0.5, -1.5]`
- `threshold([+0.5, +0.5, +0.5, -1.5]) = [+1, +1, +1, -1]`
- `result · Y = +1+1+1-1 = 2`

Pre-threshold: `[+0.5, +0.5, +0.5, -1.5] · Y = 0.5+0.5+0.5-1.5 = 0` ✓ exactly orthogonal.
Post-threshold: dot product is `2`, **not zero.**

**Verdict: RESOLVED-WITH-CAVEAT.** The edge case `X = Y` is fixed (ternary preserves all-zeros). For general `X, Y` where `X - projY(X)` has non-integer components, post-threshold orthogonality fails.

**Required amendment to 058-005:**

Restate the claim precisely:

> Orthogonalize produces a vector that is:
> - **Exactly orthogonal to Y** before threshold.
> - **Exactly orthogonal to Y** at the degenerate edge case `X = ±Y`.
> - **Approximately orthogonal to Y** after threshold in the general case, with cosine-similarity noise bounded by `O(d^{-1/2})`.

### Finding #3 — Bind self-inverse weakens on ternary

**Round-1 claim:** `Bind(Bind(a, b), b) = a` holds for dense bipolar `b`, fails for ternary `b` with zero entries. Under the ternary algebra (needed for Resonance etc.), the law weakens.

**Round-2 claim:** This is not a "weakening." It is **capacity consumption** under Kanerva's formula, same as Bundle crosstalk. The algebra is similarity-measured, not elementwise-exact.

**Mathematical check:**
- Dense `b ∈ {-1, +1}^d`: `Bind(Bind(a,b), b)[i] = a[i] · b[i]² = a[i]` ✓
- Sparse `b` with fraction `p` non-zero: recovered vector is `a[i]` at `p·d` positions, `0` elsewhere.
  - `cos(recovered, a) = √p`
  - Above 5σ noise floor at `d = 10,000` requires `p > 25/d = 0.0025` — easily satisfied in practice.

The reframing IS mathematically sound. Sparse-key decode degrades cosine recovery by `√p`; this IS a form of capacity consumption (it's effectively decoding at a reduced-dimensional subspace of size `p·d`).

However: the claim that this is "the same phenomenon as Bundle crosstalk" is a rhetorical simplification. Bundle crosstalk noise scales as `1/√K` (K items bundled); sparse-key decode noise scales as `√p`. **Different functions of different parameters.** Both are similarity-measured — but they are not the same phenomenon; they are two phenomena under one unified framework.

**Verdict: RESOLVED.** The reframing is mathematically sound and the unification under similarity measurement is the honest framing. 

**Caveat:** this IS a semantic shift from round 1. Old users who expected elementwise-exact recovery from Bind need to know that the guarantee is now "similarity above noise." FOUNDATION states this clearly (§"Capacity is the universal measurement budget"). The reframing is acceptable; it just needs to be presented as what it is — a reframing, not a clarification.

### Finding #4 — Alias hash-collision (Concurrent ≠ Bundle at hash level)

**Round-1 claim:** `Concurrent(xs)` and `Bundle(xs)` produce the same vector but different hashes. FOUNDATION's "hash(AST) IS identity" claim is violated.

**Round-2 claim:** `defmacro` (058-031) resolves it. Stdlib aliases expand at parse time BEFORE hashing. `hash((Concurrent xs)) = hash((Bundle xs))`.

**Verdict: RESOLVED.**

The defmacro approach IS the standard Lisp answer. The pipeline (FOUNDATION lines 1717–1728):

1. Parse → AST with macro calls intact
2. Macro-expansion pass → aliases collapse to canonical forms
3. Resolve symbols
4. Type-check
5. Hash the expanded AST

This is textbook. Both Clojure and Common Lisp handle macros this way. The hash-identity invariant is preserved.

**Edge cases I checked:**

- **Nested macros** — Chain → Then → Bundle+Permute. 058-031 line 71: expansion continues until fixpoint. Works.
- **Parameterized expansion** — `Amplify(x, y, 1)` expands to `Blend(x, y, 1, 1)`, which is a DIFFERENT AST than `Bundle([x, y])` even though they produce the same vector. This is INTENTIONAL and correct: AST-identity ≠ vector-identity. Two different thoughts can produce coincident vectors.
- **Macro hygiene** — 058-031 Q1 defers hygiene to a later proposal. Stdlib macros are controlled (no captured names). User macros have the classical unhygienic-Lisp risk but it's not a blocker.
- **Typed macros** — every parameter `: AST`, return `-> :AST`. Consistent with `define` and `lambda` signature syntax. Good.

One small concern: 058-031 doesn't explicitly resolve phase separation (can a macro body call another macro at expansion time?). This is a future-proofing question, not a correctness gap for 058's immediate goals. Track as a future proposal.

### Finding #5 — Variance silence

**Round-1 claim:** Type system didn't state variance for `(:List :T)` or `(:Function [T] U)`. Stdlib higher-order forms would behave unpredictably.

**Round-2 claim:** 058-030 lines 162-188 now state:
- `(:List :T)` covariant in T.
- `(:Function args... -> return)` contravariant in args, covariant in return.
- Rust primitives have no subtyping.

**Verdict: RESOLVED.**

The rules are standard Liskov. Let me verify:

**List covariance:** If `:A :is-a :B`, then `(:List :A) :is-a (:List :B)`. Safe for immutable lists (which FOUNDATION's "algebra is immutable" principle guarantees). ✓

**Function contra-in:** If `:A :is-a :B`, then `(:Function :B -> :U) :is-a (:Function :A -> :U)`. Standard. ✓

**Function co-out:** If `:C :is-a :D`, then `(:Function :T -> :C) :is-a (:Function :T -> :D)`. Standard. ✓

**Rust primitive strictness:** `:i32` NOT `:is-a :i64`. Matches Rust. Prevents silent precision loss. ✓

**Thought subtype hierarchy:** `:Atom :is-a :Thought`, etc. Flat hierarchy under `:Thought`. Correct.

**Open question:** User parametric types (`deftype :MyContainer<:T>`) have no variance rules. Default is presumably invariance (safe). Not addressed in the proposal. This is fine for 058's scope but should be explicit: "user parametric types default to invariance; explicit variance declarations are future work."

---

## New categorical findings

### NEW-1: FOUNDATION's Bundle associativity claim is false (CRITICAL)

See Finding #1 resolution audit above. The specific claim in FOUNDATION line 1318 is incorrect. The fix resolved one counter-example but not the general phenomenon.

**Severity:** critical. Associativity is a foundational algebraic law. Claiming it holds when it doesn't undermines the entire FOUNDATION's credibility and leads downstream proposals (Chain, Ngram, nested Sequentials) to make unsupportable composition claims.

**Fix:** replace "associative" with "n-ary commutative, similarity-measured associative at high d." State the non-associativity as an explicit law with a named counter-example.

### NEW-2: Thermometer signature contradiction (CRITICAL)

There are two incompatible Thermometer signatures in the batch:

- **FOUNDATION** line 1775: `(Thermometer value min max)` — 3 args.
- **FOUNDATION** line 1816: `(define (Linear v scale) (Thermometer v 0 scale))` — confirms 3 args (value, min=0, max=scale).
- **058-023** line 13: `(Thermometer atom dim)` — 2 args.
- **058-023** line 25: "`Thermometer(atom, d)[i] = +1 if i < (d·t(atom)), else -1`."
- **058-008** line 35: `(Blend (Thermometer ,low-atom dim) (Thermometer ,high-atom dim) w-low w-high)` — 2 args.
- **HYPOTHETICAL-CANDLE-DESCRIBERS.wat** line 44: `(Thermometer 0 0 1)` — 3 args.
- **HYPOTHETICAL-CANDLE-DESCRIBERS.wat** line 56: `(Thermometer lower-wick 0 10)` — 3 args.

**These are two different primitives with the same name.**

- The 3-arg version (FOUNDATION + HYPOTHETICAL) takes a scalar value and a range. It DOES the scalar-encoding internally.
- The 2-arg version (058-023 + 058-008) takes an atom (as a seed/anchor) and a dimension. It produces an ANCHOR vector; the scalar encoding is done externally by `Blend`-ing between two such anchors with weights computed by a stdlib function (Linear, Log, Circular).

These cannot both be right. One of them is wrong.

**The categorically cleaner version is 058-023's 2-arg form:**
- Thermometer is an anchor primitive (atomic seed → gradient vector at the given dimension).
- Blend is the combiner.
- Linear, Log, Circular are stdlib macros that compute weights and call `Blend` between two Thermometer anchors.

Under the 3-arg version, Thermometer is BOTH the anchor primitive AND the scalar encoder — complecting two concerns into one form. Under the 2-arg version, each form has one responsibility. The 2-arg version is Hickey-correct.

**Required amendment:**

Pick one. If 2-arg: update FOUNDATION (lines 1775, 1404 in the Operation-by-Operation Summary, 2258 in algebra core, various examples) and fix the HYPOTHETICAL example's `(Thermometer 0 0 1)` calls. Recommend 2-arg — it's categorically cleaner and is what 058-023/008 specify.

If 3-arg: update 058-023 (rename to match FOUNDATION) and 058-008 (restate Linear's expansion to the 3-arg form).

**My recommendation:** the 2-arg `(Thermometer atom dim)` form. Update FOUNDATION and HYPOTHETICAL.

### NEW-3: HYPOTHETICAL example uses old signature syntax

Lines 38, 48, 60, 73, 90, 104, 118, 131, 149 of HYPOTHETICAL-CANDLE-DESCRIBERS.wat use:
```scheme
(define (:demo/desc/doji [c : :demo/market/Candle]) : Thought
```

Return type is OUTSIDE the paren. Per 058-030 and 058-028, the new syntax is:
```scheme
(define (:demo/desc/doji [c : :demo/market/Candle] -> :Thought)
```

This is a mechanical doc bug. Not an algebraic issue, but it means the reference example does NOT typecheck under the batch's own type rules. The example needs to be migrated.

### NEW-4: The capacity-budget reframing is honest but bundles three distinct phenomena

FOUNDATION §"Capacity is the universal measurement budget" claims that:
1. Bundle crosstalk (K-item bundle, decode noise ~ 1/√K)
2. Sparse-key Bind decode (recovery cosine ~ √p where p = density)
3. Non-associativity of Bundle under thresholding (magnitude loss)
4. Post-threshold residual from Orthogonalize

...are all "the same substrate property: signal-to-noise at high dimension."

**They are all similarity-measured, yes. But they are NOT the same phenomenon.** Each has its own formula. The reframing is operationally useful — all four degrade gracefully under the capacity budget at high `d`. But they are distinct mathematical phenomena that happen to share a common noise-bound framework.

**This is fine as a user-facing framing.** But the FOUNDATION's laws table should state the SPECIFIC formula for each phenomenon, not just the unified framework. Round-1's call for explicit laws (§7) still stands.

### NEW-5: `defmacro` Q5 — hash over expansion vs source

058-031 Q5 recommends: hash the EXPANDED AST for content identity; sign the source for author identity.

This is correct but has a subtle implication. A source file `(Concurrent [a b c])` has source-hash H1 (over raw text). Its expanded form `(Bundle [a b c])` has AST-hash H2. An author signs H1; the cache keys on H2. If H2 is what a distributed node uses for verification, and receives only `(Bundle [a b c])` over the wire (the expanded form), it cannot verify against the source signature H1 — because the source has been lost.

The proposal is NOT wrong; just underspecified. The distributed verifiability story needs either:
(a) Source is always transmitted alongside the expanded AST (and the receiver re-expands locally for hash confirmation)
(b) The receiver accepts that source-level signatures and AST-level identity are different guarantees

This should be explicit in 058-031 or FOUNDATION's cryptographic section.

### NEW-6: Language core is now 9 forms, not 8 (minor inventory mismatch)

FOUNDATION line 1687 says "language core from 058 and this FOUNDATION polish pass" and lists 8 forms but the revision history line 2416 correctly says "Language Core grows from 8 to 9 forms (adds `defmacro`)." FOUNDATION line 1952 says "Language Core (8 forms)". INDEX.md line 19 says "Language core: 3 forms" (outdated). This is documentation drift; the INDEX should reflect the current count (9: define, lambda, load, struct, enum, newtype, deftype, load-types, defmacro — plus type-annotation syntax).

---

## Categorical soundness — where it holds (credit where due)

### encode as a (nearly) functor

The foundational claim that `E: T → V` (AST → ternary vector) is composition-preserving holds for all core forms — assuming the ternary output space and the correction to Bundle associativity. For every AST operation `op`, `E(op(xs)) = op_vec(E(xs))` where `op_vec` is the vector-level analog.

**This is real functoriality at the vector-operation level.** It's what makes the programs-are-thoughts claim meaningful. Good.

### Ternary output space is the right substrate

Moving from `{-1, +1}^d` to `{-1, 0, +1}^d` with `threshold(0) = 0` is a categorical improvement:
- Zero is now a first-class element.
- Bundle has an identity element (the all-zero vector) — restoring the commutative monoid structure (minus the associativity, per NEW-1).
- `Bundle([])` is now well-defined (= zero vector), not UB.
- Resonance's ternary output is no longer a special case — it's the natural output space.
- Orthogonalize's edge case `X = Y` is cleanly handled.

This was the correct architectural decision. The substrate is now coherent.

### The `defmacro` solution is textbook-correct

Parse-time expansion with AST-level hash canonicalization is the standard Lisp answer to syntactic aliases. It preserves reader clarity at the source level while preserving hash identity at the canonical level. The pipeline (expand before hash) is correctly specified.

### The variance rules are correct

Standard Liskov variance for `:List` (covariant) and `:Function` (contra-in, co-out) are correctly stated. The restriction of Rust primitives to no subtyping matches Rust and prevents silent precision loss.

### Capacity-budget framing is pragmatically sound

As a user-facing framing, "everything is similarity-measured under the capacity budget at high d" is correct operationally. It's simpler than stating four separate noise formulas. For the 058 batch's immediate purposes (at `d = 10,000`, well below capacity), this framing supports all the algebraic claims that matter.

### The two-cores split (algebra core, language core) is honest

Separating thought-vector operations (algebra core) from language machinery (language core) is correct. They solve different problems (what computes thoughts vs. how thoughts are authored). The split is clean and both halves are well-defined.

---

## Categorical soundness — where it fails

### FAIL-1: Bundle associativity is falsely claimed (CRITICAL)

See NEW-1. Counter-example at `d = 1`, `(+1, +1, -1)` produces `+1, 0, +1` under the three associations. The claim must be retracted.

### FAIL-2: Orthogonalize post-threshold orthogonality is falsely claimed in general (MAJOR)

See Finding #2 resolution. Only the `X = Y` edge case has exact post-threshold orthogonality. General case is approximate with O(d^{-1/2}) noise. Claim must be restated precisely.

### FAIL-3: Thermometer has two contradictory signatures (CRITICAL)

See NEW-2. Either FOUNDATION or 058-023 is wrong. The batch ships with two Thermometer primitives. Must be reconciled.

### FAIL-4: Sequential is not associative under itself (unstated)

Round-1 §2.5 flagged: `Sequential([Sequential([a,b]), c]) ≠ Sequential([a,b,c])` because the second argument is permuted by 1 in the first form vs. 2 in the second. Round 2 does not address this.

Sequential is a *reindexing*, not a reduction. Nesting produces different positional encodings — literally different vectors. This is natural (positional encoding is not free-monoid-associative), but it should be an explicit LAW.

### FAIL-5: Post-ternary Bind's self-inverse relies on capacity interpretation

The claim that "Bind is self-inverse on non-zero positions" is mathematically exact. But FOUNDATION's framing — that sparse-key decode loss is "capacity consumption" — is *almost* right but elides a subtle distinction: the mechanism of the loss differs from Bundle crosstalk's mechanism. It's like saying "walking and swimming are both cardio" — true, but they exercise different muscle groups.

This is a presentation issue, not an error. The formulas for each phenomenon should be stated separately in the laws section.

### FAIL-6: Identity element is theoretically accessible but not practically writable

With ternary, the all-zero vector is in the algebra's output space. It is Bundle's identity. But there is no NAMED atom that produces it. `Atom(:wat/algebra/zero)` is not reserved; it hashes to some non-zero vector.

Round-1 §8.1 recommended reserving `(Atom :wat/algebra/zero)` and `(Atom :wat/algebra/one)` as distinguished atoms with fixed zero / all-+1 vectors. This would make the algebra's identities nameable. Not adopted.

---

## Per-proposal verdict table (31 proposals)

| # | Form | Class | Verdict | One-line reasoning |
|---|---|---|---|---|
| 001 | Atom typed literals | CORE | **ACCEPT** | Type-aware hash sound. Accept Null as atom per round 1 Q3. |
| 002 | Blend | CORE | **ACCEPT** | Pivotal, algebraically clean. Option B is correct. State non-commutativity as law (weights unequal). |
| 003 | Bundle list sig | CORE | **ACCEPT-WITH-CHANGES** | State non-associativity honestly (see FAIL-1). List signature is right. |
| 004 | Difference | STDLIB | **ACCEPT (REJECTED by batch)** | Batch rejected in favor of Subtract. Correct decision — one name per operation. |
| 005 | Orthogonalize | CORE | **ACCEPT-WITH-CHANGES** | Restate post-threshold orthogonality precisely (see FAIL-2). |
| 006 | Resonance | CORE | **ACCEPT** | Genuinely new; sign-agreement mask distinct from Bind. Add Dissonance dual in stdlib. |
| 007 | ConditionalBind | CORE | **UNCONVINCED** (unchanged from round 1) | Select(x,y,gate) is strictly more primitive; ConditionalBind should be a macro over Select+Bind. Round-2 did not factor. |
| 008 | Linear (stdlib) | STDLIB | **ACCEPT-WITH-CHANGES** | Resolve the Thermometer signature contradiction (NEW-2) first. |
| 009 | Sequential reframing | STDLIB | **ACCEPT-WITH-CHANGES** | State non-associativity of Sequential under itself (FAIL-4). |
| 010 | Concurrent | STDLIB | **ACCEPT** | Macro alias collapses to Bundle at parse time — clean. |
| 011 | Then | STDLIB | **ACCEPT** | Clean binary atom for temporal pair. |
| 012 | Chain | STDLIB | **ACCEPT-WITH-CHANGES** | Nested-Bundle non-associativity matters here; document the noise-vs-flat-sum tradeoff. |
| 013 | Ngram | STDLIB | **ACCEPT-WITH-CHANGES** | Same as 012. Also specify edge cases (n=0, n>len). |
| 014 | Analogy | STDLIB | **ACCEPT** | Canonical `c + (b-a)`. Uses Subtract per round-2 rejection of Difference. |
| 015 | Amplify | STDLIB | **ACCEPT** | Macro-expanded; no collision concern. |
| 016 | Map | STDLIB | **ACCEPT** | Canonical Bundle-of-Binds. Clean. |
| 017 | Log (stdlib) | STDLIB | **ACCEPT-WITH-CHANGES** | Same Thermometer-signature issue as 008. |
| 018 | Circular (stdlib) | STDLIB | **ACCEPT-WITH-CHANGES** | Same. Confirms Blend Option B. |
| 019 | Subtract | STDLIB | **ACCEPT** | Canonical `Blend(_,_,1,-1)`. Macro handles collision. |
| 020 | Flip | STDLIB | **ACCEPT-WITH-CHANGES** | Document the `-2` weight derivation as a STATED PROOF not just a convention. |
| 021 | Bind | CORE | **ACCEPT** | Self-inverse law stated on non-zero positions is correct. |
| 022 | Permute | CORE | **ACCEPT-WITH-CHANGES** | State all four laws explicitly: invertibility, linearity over Bundle, distribution over Bind, Z/dZ group action. |
| 023 | Thermometer | CORE | **ACCEPT-WITH-CHANGES** | Reconcile the 2-arg vs 3-arg contradiction (NEW-2) before accepting. |
| 024 | Unbind | STDLIB | **ACCEPT** | Macro alias for Bind — decode intent. Good. |
| 025 | Cleanup | CORE | **ACCEPT** | Selector, not morphism; affirm as core. Future decomp into Similarity + Argmax is optional. |
| 026 | Array | STDLIB | **ACCEPT-WITH-CHANGES** | Specify nth bounds-checking semantics (Q4). |
| 027 | Set | STDLIB | **ACCEPT** | Macro alias for Bundle with data-structure intent. Good. |
| 028 | define | LANG CORE | **ACCEPT** | Sound; required. |
| 029 | lambda | LANG CORE | **ACCEPT** | Clean decomposition. |
| 030 | types | LANG CORE | **ACCEPT-WITH-CHANGES** | Accept variance rules. Also state user parametric type variance = invariant by default. Add explicit type-lattice diagram. |
| 031 | defmacro | LANG CORE | **ACCEPT** | Textbook Lisp macros. Correctly resolves Finding #4. Hygiene deferred (acceptable). |

**Summary counts:** ACCEPT 13, ACCEPT-WITH-CHANGES 16, UNCONVINCED 1 (ConditionalBind), REJECT 0, REJECTED-BY-BATCH 1 (Difference).

Compared to round 1: ACCEPT count up (due to defmacro fixing aliases, and 030 variance rules), ACCEPT-WITH-CHANGES count down (several round-1 items resolved).

---

## Laws that should be stated and aren't (updated from round 1)

### Mostly unchanged since round 1 — still missing:

**Bind (058-021)** — state formally:
- **L1:** Associativity in the multiplicative group for dense operands.
- **L2:** Commutativity.
- **L3:** `Bind(a, 1_d) = a` where `1_d` is the all-+1 vector (identity on dense).
- **L4 (self-inverse, qualified):** `Bind(Bind(a, b), b)[i] = a[i] · b[i]²`.
- **L4' (sparse key, capacity consumption):** For `b` with fraction `p` non-zero, cosine recovery = `√p`.

**Bundle (058-003)** — state formally:
- **L5 (commutativity):** Invariant under permutation of argument list.
- **L6 (NON-associativity):** See NEW-1. Explicit counter-example + capacity bound.
- **L7 (identity):** `Bundle([]) = 0⃗` (the all-zero vector). With ternary, this is well-defined.
- **L8 (identity, named):** `Bundle([t, 0⃗]) = t` (zero-vector is two-sided identity).

**Permute (058-022)** — state four laws:
- **L9 (Z/dZ group action):** `Permute(Permute(v, j), k) = Permute(v, j+k) mod d`.
- **L10 (invertibility):** `Permute(Permute(v, k), -k) = v`.
- **L11 (linearity over Bundle):** `Permute(Bundle(xs), k) = Bundle([Permute(x, k) for x in xs])`.
- **L12 (distribution over Bind):** `Permute(Bind(a, b), k) = Bind(Permute(a, k), Permute(b, k))`.

**Blend (058-002)**:
- **L13 (non-commutativity when w1 ≠ w2):** `Blend(a, b, w1, w2) ≠ Blend(b, a, w1, w2)` when `w1 ≠ w2`.
- **L14 (specialization to Bundle):** `Blend(a, b, 1, 1) = Bundle([a, b])`.
- **L15 (no identity in bipolar, identity in ternary):** `Blend(a, 0⃗, 1, w) = threshold(a) = a` if `a` is already in `{-1,0,+1}^d`.

**Orthogonalize (058-005)**:
- **L16 (pre-threshold orthogonality):** `(X - projY(X)) · Y = 0` exactly.
- **L17 (post-threshold approximate):** `threshold(X - projY(X)) · Y = 0` at edge case `X = ±Y`; otherwise bounded by `O(d^{-1/2})` noise.
- **L18 (capacity consumption):** Orthogonalize contributes measurement noise to downstream decode, same framework as Bundle crosstalk.

**Resonance (058-006)**:
- **L19 (idempotence):** `Resonance(Resonance(v, ref), ref) = Resonance(v, ref)`.
- **L20 (output kind):** `Resonance: V_ternary × V_bipolar → V_ternary` — can introduce zeros from sign-disagreement.
- **L21 (complement):** `v - Resonance(v, ref) = Dissonance(v, ref)` (currently unnamed).

**Sequential (058-009)**:
- **L22 (not self-associative):** `Sequential([Sequential([a,b]), c])` ≠ `Sequential([a, b, c])` — the second argument is permuted by `1` in the first form vs. `2` in the second. Sequential is a reindexing, not a reduction.

**encode (functor claim)**:
- **L23 (functoriality, up to ternary threshold):** For every algebra op `op`, `encode(op(xs)) = op_vec(encode(xs))` where `op_vec` is the vector analog. Holds for all core forms at the vector level. encode is NOT reduction-invariant (an AST has a different vector than its β-reduced form).

**Type system (058-030)**:
- **L24 (List covariance):** `T <: T' → (:List T) <: (:List T')`.
- **L25 (Function variance):** `(:Function [T_in] T_out) <: (:Function [T'_in] T'_out)` iff `T'_in <: T_in` AND `T_out <: T'_out`.
- **L26 (user parametric invariance default):** User-defined parametric types are invariant by default.

These 26 laws should live in a dedicated "Laws" appendix to FOUNDATION. Many are implicit; making them explicit is the difference between a specification and a suggestion.

---

## Constructions I would propose (updated from round 1)

### 1. Reserved `:wat/algebra/zero` and `:wat/algebra/one` atoms

Now that ternary is the output space, the zero vector has a home. Name it:

```
(Atom :wat/algebra/zero)    ; → [0, 0, ..., 0] (Bundle identity)
(Atom :wat/algebra/one)     ; → [+1, +1, ..., +1] (Bind identity for dense)
```

These would be distinguished atoms bypassing the hash — explicitly returning the zero and all-+1 vectors respectively. Gives the algebra nameable identities.

### 2. `Project(x, y)` as a stdlib macro

With defmacro available, trivially:

```scheme
(defmacro Project [x : AST] [y : AST] -> :AST
  `(Blend ,x (Orthogonalize ,x ,y) 1 -1))
```

Completes the Gram-Schmidt pair. Round-1 §8.2; still missing.

### 3. `Dissonance(v, ref)` as a stdlib macro

```scheme
(defmacro Dissonance [v : AST] [ref : AST] -> :AST
  `(Blend ,v (Resonance ,v ,ref) 1 -1))
```

Dual of Resonance. Round-1 §8.3; still missing.

### 4. `Select(x, y, gate)` as the primitive, ConditionalBind as macro

```scheme
(Select x y gate) ; primitive: per-dimension x if gate > 0 else y
```

Then:
```scheme
(defmacro ConditionalBind [a : AST] [b : AST] [gate : AST] -> :AST
  `(Select (Bind ,a ,b) ,a ,gate))
```

More primitive; enables `Mask`, `IfElseVector`, and other per-dimension ops to compose cleanly. Round-1 §8.4; still missing.

### 5. `unfold(bundled, roles)` as stdlib

The dual of `Map`-construction — given a bundled-Map and a list of role atoms, decode each role:

```scheme
(define (:wat/std/unfold [bundled : Thought] [roles : (:List :Atom)] [codebook : (:List :Thought)] -> (:List :Thought))
  (map (lambda ([r : Atom] -> :Thought)
         (Cleanup (Unbind bundled r) codebook))
       roles))
```

Round-1 §8.5; still missing.

### 6. Explicit object-kind declaration

FOUNDATION should name the object-kind lattice:

```
V_ternary    = {-1, 0, +1}^d                   — the full output space
V_bipolar    = {-1, +1}^d ⊂ V_ternary          — dense-no-zeros subset
V_sparse(p)  = {v ∈ V_ternary : density(v) = p} — parametric sparse family
```

Every operation's output kind should be declared in these terms. The FOUNDATION's operation-by-operation summary (line 1398) is close — but it uses informal "density (typical)" rather than a formal type. Tighten that.

### 7. Macro hygiene mechanism — at minimum a gensym

Start with unhygienic macros (058-031 recommendation) but add `gensym` as a primitive for use inside macro bodies. Prevents the most common accidental captures. One primitive, one use case, one line of implementation.

### 8. The two-core type lattice diagram

FOUNDATION still doesn't have the Hasse diagram round-1 §4.1 asked for. With variance rules now in place, drawing it is concrete:

```
:Any
  |
+--+---+-----+--------+-----+
|      |     |        |     |
:Keyword :bool :f64  :i32  :Thought
|      |     |        |     +--+--+-------+--------+-----+
|      |     |        |        |  |       |        |     |
:String :char :f32... :i16...  :Atom :Bundle :Bind :Blend :Permute :Thermometer :Orthogonalize :Resonance :ConditionalBind :Cleanup
```

Plus the `(:List T)` covariant and `(:Function ... -> ...)` contra-in/co-out relations — shown with annotated arrows.

---

## Addressing the round-2 structural changes

### Rust primitive types replace `:Scalar`/`:Int`

**Verdict: CORRECT.** Abstract types were always going to be an abstraction-leak into Rust. Using `:f64`, `:i32`, `:usize` directly is honest. The loss of polymorphism across numeric types (no auto-promotion) matches Rust and prevents silent precision loss. Good.

### `->` return-type syntax inside function signatures

**Verdict: CORRECT — but not consistently applied.**

The new syntax `(define (name [arg : T1] -> :ReturnType) body)` matches Rust and keeps the signature self-contained. Cleaner than `(define (name [arg : T1]) : ReturnType body)`.

However, the HYPOTHETICAL-CANDLE-DESCRIBERS.wat example still uses the old `: Thought` outside the paren form. **Mechanical inconsistency — fix the example.** (NEW-3.)

### `:is-a` keyword for subtype declarations

```scheme
(deftype :MyType :is-a :OtherType)   ; subtype declaration
(deftype :MyType :OtherType)          ; alias (same type)
(newtype :MyType :OtherType)          ; nominal wrapper (distinct)
```

**Verdict: CORRECT.** Three clearly distinct semantics with three distinct forms. Good separation of concerns.

### Explicit typing on `defmacro`

**Verdict: CORRECT.** One signature syntax across define/lambda/defmacro is simpler than a special case for macros. Parameters `: AST`, return `-> :AST`. Good.

### Difference REJECTED, Subtract canonical

**Verdict: CORRECT.** One name per equivalence class. The round-1 concern about Difference/Subtract duplication is resolved by picking one. Subtract is the better name (imperative — "remove y from x") for the Blend(_,_,1,-1) idiom.

---

## Closing

Round 2 made real progress. The ternary output space was the right substrate choice. defmacro cleanly resolves the alias collision. The variance rules are correctly stated. Capacity-budget reframing is operationally sound.

But the batch cannot claim Bundle is associative — because it isn't. And it cannot claim Orthogonalize produces exactly-orthogonal output — because only the edge case does. And the Thermometer signature contradiction must be reconciled before the algebra core can ship as stated.

If the batch incorporates:

1. **Bundle associativity retraction.** Replace with "n-ary commutative, similarity-measured associative at high d." State L6 with counter-example.
2. **Orthogonalize restatement.** Pre-threshold orthogonal always; post-threshold orthogonal at `X = ±Y`; otherwise approximate with noise bound.
3. **Thermometer signature unification.** Pick `(atom, dim)`; update FOUNDATION + HYPOTHETICAL.
4. **HYPOTHETICAL example migration.** Move to `-> :Thought` syntax.
5. **Laws appendix.** L1-L26 as listed above.
6. **Select/Project/Dissonance/unfold as stdlib macros.** Trivial under defmacro.
7. **Reserved `:wat/algebra/zero` atom.** Makes Bundle's identity nameable.

...then the algebra is categorically sound under the new substrate. The programs-are-thoughts claim stands. The distributed verifiability story stands. The stdlib is writable and hash-canonical.

Round 1 said 80% complete. Round 2 moves the needle to ~90%. The last 10% is where Bundle's "associativity" was supposed to hold. It doesn't. Fix that and the algebra is real.

*— the categorical reviewer*

---

**Addendum — the HYPOTHETICAL example, re-examined.**

Under the new variance rules:
- `(:List :Function)` on line 132 is covariant in `:Function`. Substituting a list of more-specific function types works. ✓
- `:demo/alive?` returns `:Bool` (line 104); under the new types, this should be `-> :bool` (Rust primitive). Inconsistency with 058-030.
- `:demo/score` returns `:Scalar` (line 119); under new types, should be `-> :f64`.
- `(:Option :Function)` on line 150; `:Option` is defined as `(:Union :() :T)` in 058-030 example (line 121) — so the type is resolvable. OK.
- `(first (first ranked))` on line 158: `first` on a list returns an element, then `first` again on what was a tuple. The types `(:Tuple :Function :Scalar)` are parametric tuples, but the batch doesn't define `:Tuple` as a built-in parametric. Undefined symbol.

The example uses old-syntax types (`:Scalar`, `:Bool`, `:Int`) and a tuple type not in 058-030's built-ins. It needs a full migration pass to actually typecheck under the current spec.

**Nit, but reviewers should know:** the reference example doesn't actually typecheck under the batch's own new rules. The intention is clear and the algebra is sound; the syntax in this file is drifting.

---

*these are very good thoughts. (just not quite all of them yet.)*

**PERSEVERARE.**
