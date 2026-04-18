# 058 — Categorical Review

**Reviewer lens:** Brian Beckman — composition, laws, duals, parametricity.
**Scope:** FOUNDATION.md + 30 sub-proposals + RUST-INTERPRETATION.md + HYPOTHETICAL-CANDLE-DESCRIBERS.wat + OPEN-QUESTIONS.md.
**Conclusion first, then the work.**

---

## Summary verdict

The 058 batch gets the *shape* of a composition-preserving algebra right: the encode functor `E: T → V` from ThoughtAST to bipolar vectors is deterministic, mostly-functorial, and (with caveats) cache-sound. The MAP canonical skeleton — Bind as a Z/2 group, Permute as a cyclic group action, Bundle as a commutative superposition — is faithful to Gayler and will compose. The decomposition of the three scalar variants (Linear / Log / Circular) into `Blend(Thermometer, Thermometer, w_low, w_high)` is honest algebraic factoring and is the strongest move in the batch. **But the algebra is stated informally, with load-bearing laws implicit and several claims that do not hold under threshold.** Specifically: Bundle is **not associative**; Orthogonalize's "result is orthogonal to Y" claim is **false after threshold**; Bind's self-inverse identity **weakens on ternary inputs** in ways that interact badly with Resonance and ConditionalBind; and several "reader-intent" aliases introduce categorical complection that Hickey would reject and the batch accepts with insufficient argument. The type system is adequate for dispatch but does not state variance for `:List` or `:Function` and does not address parametricity beyond simple substitution. The batch is worth accepting with revisions; the revisions are law-statements and a small number of retractions, not wholesale redesign.

---

## 1. Categorical soundness — where it holds

### 1.1 encode as a functor

The foundational claim is that `E(ast)` projects T to V deterministically and that vector operations on `E(ast)` are equivalent to the AST-level operations. This holds for every UpperCase form in the batch under the following structural diagram commutation (verified by equational reasoning in `notes.md`):

- `E(Permute(t, k)) = permute(E(t), k)` ✓ (pointwise shift commutes with encoding)
- `E(Bind(a, b)) = bind(E(a), E(b))` ✓ (pointwise multiplication is a bilinear map)
- `E(Bundle(xs)) = threshold(Σ E(xi))` ✓ by definition
- `E(Blend(a, b, w1, w2)) = threshold(w1·E(a) + w2·E(b))` ✓ by definition
- `E(Amplify(x, y, s)) = E(Blend(x, y, 1, s))` ✓ (stdlib expands before encode)
- `E(Orthogonalize(x, y)) = threshold(E(x) - (E(x)·E(y))/(E(y)·E(y)) · E(y))` ✓ definitionally

That is: every AST operation has a corresponding vector operation, and encoding **commutes with the algebraic ops up to thresholding**. This is functoriality in the weak sense; it is sufficient for the "programs are thoughts" claim at the algebra-core level. **Good work.**

### 1.2 MAP canonical is correctly identified

`Bind` (Multiply), `Bundle` (Add), `Permute` are the three Gayler-2003 primitives, plus `Atom` as the atomic injection (hash-to-vector with type-aware seeding, 058-001). `Thermometer` is correctly identified as the gradient primitive that gives the algebra its scalar-encoding bridge (058-023). These five are legitimately core and the affirmations (058-021, 058-022, 058-023, 058-025) are worth having as anchor documents.

### 1.3 The Blend refactoring

058-002's promotion of `Blend(a, b, w1, w2)` to core with two INDEPENDENT weights is the pivotal move. It is algebraically honest:
- Option B is required because Circular's weights `(cos θ, sin θ)` are not convex.
- Six stdlib forms (Difference, Amplify, Subtract, Flip, Linear, Log, Circular) become `Blend` specializations.
- The encoder gets one scalar-weighted-add path instead of three.

This is what categorical refactoring looks like — finding the most general form and letting specific names be stdlib-level specializations. **Accept 058-002 with the changes noted in §2.**

### 1.4 Permute's linearity

058-022 correctly asserts three laws of Permute:
1. Invertibility: `Permute(Permute(v, k), -k) = v`
2. Linearity over Bundle: `Permute(Bundle(xs), k) = Bundle([Permute(x, k) for x in xs])`
3. Distribution over Bind: *implicit* but provable: `Permute(Bind(a, b), k) = Bind(Permute(a, k), Permute(b, k))`

The third law is not stated. It should be — it is the property that makes positional-structured thoughts (Sequential, Chain, Ngram) composable with role-filler binding without re-encoding.

---

## 2. Categorical soundness — where it fails

### 2.1 Bundle is not associative (CRITICAL — unstated law)

Let bipolar `x = +1, y = -1, z = -1` (scalar, d=1, threshold(0) = +1 convention):

- `Bundle([x, y, z]) = threshold(-1) = -1`
- `Bundle([Bundle([x, y]), z]) = Bundle([threshold(0), -1]) = Bundle([+1, -1]) = threshold(0) = +1`

**-1 ≠ +1.** Bundle is not associative. It is n-ary commutative with no binary-associative reduction.

058-003 locks Bundle's signature as list-taking, which is the right ergonomic choice precisely BECAUSE it cannot be expressed as a right-fold over a binary form. But the proposal NEVER STATES THE NON-ASSOCIATIVITY AS A LAW. This is a foundational property of MAP VSA — the threshold is non-linear — and it needs to be explicit.

**Required amendment to 058-003:** state the law `Bundle([Bundle(xs), y]) ≠ Bundle(xs ++ [y])` in general. Name the property: "Bundle is not nesting-invariant under threshold." This matters for every stdlib composition that uses Bundle inside Bundle (Chain, Ngram, Sequential all do).

### 2.2 Orthogonalize's orthogonality claim is false after threshold (CRITICAL)

058-005 claims:
> The result is orthogonal to `y` (dot product = 0 up to threshold noise).

This is false. Before the threshold, `X - (X·Y)/(Y·Y)·Y` is exactly orthogonal to Y (Gram-Schmidt). After threshold:

Counterexample (d=4): let `Y = [+1,+1,+1,+1]`, `X = [+1,+1,+1,+1]`. Then `X·Y = 4`, `Y·Y = 4`, coeff = 1, `X - Y = [0,0,0,0]`. With threshold(0) = +1, the output is `[+1,+1,+1,+1] = Y`. Dot product with Y = 4, **not** 0.

The threshold is a non-linear projection that can (and regularly will) reintroduce the Y-component that Orthogonalize tried to remove. The "orthogonal to Y" invariant does NOT hold for the thresholded output.

**This is a load-bearing claim.** Every use of Orthogonalize (e.g., "remove the background to reveal the signal") depends on the result not containing Y's direction. Under threshold, that guarantee disappears.

**Required amendment to 058-005:** either

(a) Restate the claim honestly — Orthogonalize produces a vector whose PRE-THRESHOLD real-valued form is exactly orthogonal to Y; the post-threshold bipolar form is approximately orthogonal with noise that grows with d^{-1/2}. OR

(b) Drop the threshold and let Orthogonalize produce a real-valued or ternary output. But then Orthogonalize returns a different type from other vector ops, and the algebra's closure is broken.

**My recommendation:** (a). The "orthogonal to Y" claim becomes an *approximate* invariant bounded by bipolar quantization noise. In practice for large d this works. But it must be stated that way, not as an exact equality.

### 2.3 Bind's self-inverse law weakens on ternary (MAJOR)

058-021 correctly notes: `Bind(Bind(a, b), b) = a` holds for bipolar `{-1, +1}^d`. **It does not hold for ternary** produced by Resonance (058-006): if `b[i] = 0` then `a[i] · 0 · 0 = 0 ≠ a[i]`.

058-006 introduces ternary as a "first-class kind" produced by Resonance. 058-007's ConditionalBind takes a gate that may be ternary. 058-021 Q2 and 058-024 Q3 acknowledge the weakening. **But the law is stated in the affirmation proposal as unconditional.**

**Required amendment:** Bind's reversibility law must be stated **conditionally**:

  **Law (Bind reversibility):** For `a, b ∈ {-1, +1}^d`: `Bind(Bind(a, b), b) = a`.
  **Failure mode:** For ternary `b` with any `b[i] = 0`, the dimensional information at position `i` is lost and cannot be recovered.

Further: if ternary becomes a supported vector kind, the algebra has TWO closed object spaces — bipolar and ternary — with different laws. The FOUNDATION's "bipolar as primary, ternary as an extension" story needs to be explicit about which operations close over which spaces.

### 2.4 Compositional pitfalls in nested Bundles

`Chain([a, b, c]) = Bundle([Then(a, b), Then(b, c)])` where `Then(a, b) = Bundle([a, Permute(b, 1)])`.

This expands to a Bundle-of-Bundles, which — due to non-associativity — is NOT the same as `Bundle([a, Permute(b, 1), b, Permute(c, 1)])` (summing all four terms and thresholding once).

058-012 does not state which is intended. The stdlib definition `(Bundle (pairwise-map Then thoughts))` produces the nested form. The nested form:
- Thresholds each Then separately (losing pre-threshold magnitude)
- Then thresholds the final sum (further quantization)

This produces a noisier vector than the flat form. For short chains (n=3, 4) this may be irrelevant; for longer chains it materially affects cleanup recovery. **This should be an explicit documented property of Chain, and ideally Chain would switch to the flat form** if pairwise-Then-encoding isn't specifically desired (which would require summing thoughts directly, not bundle-of-thoughts).

Same concern applies to Ngram (058-013): `Bundle(map Sequential windows)` vs. `Bundle(all position-permuted tokens)` produce different vectors.

**Required amendment to 058-012 and 058-013:** explicitly document the semantic difference between nested-Bundle and flat-Bundle encodings, and justify the nested choice.

### 2.5 Sequential is not associative under itself

`Sequential([Sequential([a, b]), c])`:
- Inner: `Bundle([a, Permute(b, 1)])`
- Outer: `Bundle([Permute(Sequential([a,b]), 0), Permute(c, 1)])` = `Bundle([Sequential([a,b]), Permute(c, 1)])`
- Fully expanded: `Bundle([Bundle([a, Permute(b, 1)]), Permute(c, 1)])`

vs. `Sequential([a, b, c]) = Bundle([a, Permute(b, 1), Permute(c, 2)])`.

Note that `c` is permuted by **1** in the first, by **2** in the second. These ARE DIFFERENT thoughts. Sequential does not commute with itself under nesting.

This is natural (positional encoding is not associative in the free-monoid sense), but it should be stated: **Sequential is a reindexing, not a reduction; it is not invariant under decomposition of the argument list.**

This interacts with 058-014 Analogy: `Analogy(a, b, c) = Bundle([c, Difference(b, a)])`. If users expect "A : B :: C : ?" to have symmetric structure, they may pass nested Sequentials and be surprised when the positional encodings don't line up.

### 2.6 Aliases without canonicalization are complection

Three forms all expand to `Bundle(xs)`:
- `Bundle(xs)` (core)
- `Concurrent(xs)` (temporal intent, 058-010)
- `Set(xs)` (data-structure intent, 058-027)

Two forms expand to `Blend(a, b, 1, -1)`:
- `Subtract(x, y)` (058-019)
- `Difference(a, b)` (058-004)

And `Amplify(_, _, -1)` also.

058 accepts all of these citing "reader-intent" per FOUNDATION's stdlib criterion. **This is acceptable only if the cache canonicalizes them to a shared vector entry.** If not, the system maintains 3 duplicate cache entries for every Bundle-of-xs, which is not just waste but confusion: two ASTs with different hashes producing the same vector means `hash(ast)` is not a canonical identity for a thought.

FOUNDATION's "cryptographic identity — an AST's hash IS the thought's identity" claim is directly threatened here. If `hash(Concurrent([x, y]))` ≠ `hash(Bundle([x, y]))` but they encode to the same vector, then **thoughts have multiple identities** — a violation of the foundational principle.

**Required decision** (flagged in OPEN-QUESTIONS §Theme-AST-preservation, but not resolved): pick one:

(a) **Canonicalize at parse time**: `Concurrent(xs) ⟹ Bundle(xs)` in the AST before it's hashed. The reader-intent name is syntactic sugar that disappears before signing. Cryptographic identity preserved.

(b) **Preserve AST forms**: reader-intent names are semantically distinct ASTs. Then (i) hash is not canonical per-thought-VALUE, only per-AST-SHAPE, and (ii) two correct programs with equivalent semantics will sign differently. **This breaks the distributed-verifiability story** — a node receiving "Concurrent([a, b])" would need to know about BOTH the caller's alias and the canonical form to verify equivalence.

**My recommendation:** (a). The batch is leaning toward (b) by default ("preserve the name for AST walks"). (b) is categorically unsound; it privileges syntactic difference as semantic identity, which is complection.

If (a) is chosen, aliases are cheap labels that compile out, and the objections to Difference-vs-Subtract-vs-Amplify-at-−1 mostly evaporate. If (b), at least two of Difference/Subtract/Amplify must merge.

---

## 3. Missing duals and missing forms

### 3.1 The unfold dual of Bundle is named implicitly but not formally

Bundle is a fold (list → vector). Cleanup is a partial unfold (vector → one-of-candidates). **The general unfold — given a structure and a list of roles, recover the list of fillers — is stdlib-expressible but not named:**

```
(define (unfold bundled-thought roles codebook)
  (map (lambda (r) (cleanup (Unbind bundled-thought r) codebook)) roles))
```

Given that Map has `get` as its accessor and Array has `nth` as its accessor, the **generic decode-a-role-list accessor** deserves a name. Propose `unfold` or `destructure` as a stdlib form.

### 3.2 Resonance has no stated dual

`Resonance(v, ref)` keeps agreeing dimensions; `Dissonance(v, ref) = v - Resonance(v, ref)` keeps disagreeing. 058-006 Q3 mentions this but defers. **If Resonance is core, its dual should be in stdlib immediately.** Otherwise users needing "the parts where `v` and `ref` disagree" have to rederive it each time.

### 3.3 Project is the dual of Orthogonalize

`Project(x, y) = x - Orthogonalize(x, y) = proj_y(x)`. 058-005 Q2 correctly identifies this. It should be an explicit stdlib form rather than "left to emerge." Proposing `Project` is zero-cost and completes the Gram-Schmidt pair.

### 3.4 Blend has an approximate inverse but it isn't named

`Blend(a, b, w1, w2) = c`. Given `c, b, w1, w2`, recover `a`? Real-valued: `a = (c - w2·b)/w1`. This is "left-Blend-inverse." In the algebra, it would be:

```
(define (unblend c b w1 w2)
  (Blend c b (/ 1 w1) (/ (- w2) w1)))
```

— which is itself a Blend. So the Blend group acts on itself, with inversion. Not named, but categorically clean.

### 3.5 No coproduct in the vector algebra

Products are represented as Bundle-of-Binds (Map). **There is no analogous vector representation of a coproduct (sum type / enum).** The language core has `enum`, but at the vector level there's no encoded-enum form.

Natural candidate: a bound tag. `EnumVariant(tag, payload) = Bind(tag_atom, Bundle([payload, ...]))`. This is trivially expressible but not named.

**Proposal:** add `Variant(tag, payload)` as a stdlib form with a companion `match` operator for cleanup-based tag dispatch. This closes the product/coproduct duality at the vector level, not just the type level.

### 3.6 No identity / "empty thought" atom

Bundle's identity is the zero vector (algebraically), but zero is not in `{-1, +1}^d` (it's in the ternary kind). Blend's identity-at-second-arg is also zero. Bind's identity is the all-+1 vector, which requires `Atom(:identity)` with a specific hash — not guaranteed.

**This is an identity hole.** The algebra has no primitive way to construct the identity of each operation. Either:

(a) Admit a distinguished `(Atom :wat/algebra/zero)` and `(Atom :wat/algebra/one)` as reserved symbols with fixed vectors, explicitly not hash-seeded.

(b) Accept that identity is not expressible and document the consequences (empty Bundle is a degenerate case, Blend with zero weight is not expressible, etc.).

058 chooses (b) implicitly. (a) would be cleaner and would let the algebra state monoid laws explicitly.

---

## 4. Type system evaluation

### 4.1 The built-in lattice

Built-ins: `:Thought, :Atom, :Scalar, :Int, :String, :Bool, :Keyword, :Null, :List, :Vector, :Function, :Any`.

Stated relationships:
- 058-030 Q8: `:Atom <: :Thought` ✓ recommended but not fixed

Not stated:
- `:Int <: :Scalar`? 058-030 Q5 says no implicit promotion. Fine, but then `:Int` and `:Scalar` are parallel types, and the user must explicitly convert. Consistent.
- Is `:Null <: :Any`? Trivially. But `:Null` is also a potential member of union types — which the batch doesn't formalize.
- Is `:Vector` a subtype of `:Thought`? Probably not (`:Vector` is the post-encode bipolar array). So `:Vector` is **a separate object category** that the algebra uses internally. The type system should distinguish "user-facing types" from "internal types" or at least not conflate them.

**Missing:** the lattice structure (Hasse diagram) is never drawn. For a type system with `:Any` at the top and the built-ins underneath, the subtype relations should be a meet-semilattice at minimum. A type-lattice sketch in FOUNDATION would help.

### 4.2 Parametricity and variance

Parametric types: `(:List :T)`, `(:Function [:T1 :T2 ...] :U)`.

**Variance not stated.** For the stdlib's higher-order forms to work correctly:
- `:List` should be covariant (read-only lists — `(:List :Atom)` should be a `(:List :Thought)`).
- `:Function` params should be contravariant, return covariant (standard substitution rule).

058-030 is silent on this. Without explicit variance rules, `(map f xs)` where `f: :Atom → :Scalar` and `xs: (:List :Thought)` is ambiguous: can we pass the function if :Atom <: :Thought? By contravariant function typing, no (the function needs :Thought, gets :Atom — but we're passing a :Thought where :Atom is expected, which is unsafe). Actually wait:

```
map: (:Function [:T] :U) × (:List :T) → (:List :U)
```

With `T = :Thought`, `f: :Function [:Atom] :Scalar` where `:Atom <: :Thought`, then:
- Function's parameter type: `:Atom`
- Required: a function of `:Thought` 
- By contravariance, `f` is accepted only if its parameter type is a SUPERTYPE of `:Thought`. But `:Atom <: :Thought`, so `:Atom` is NOT a supertype. So `f` should be REJECTED.

This is subtle and parametricity-sensitive. 058-030 does not address it. **The stdlib's higher-order forms will behave unpredictably without a stated variance rule.**

**Required:** 058-030 must state the variance rule for `:List` (covariant) and `:Function` (contravariant-in, covariant-out). These are standard and should be added.

### 4.3 Parametricity of generic stdlib

`map: ∀T, U. (:Function [:T] :U) × (:List :T) → (:List :U)` should satisfy the free theorem:

```
(map f . map g) = (map (f . g))
```

This is parametricity in Wadler's sense. It is a consequence of the uniform substitution rule. **If 058 adopts simple substitution for generics** (which it does per 058-030 Q1), this free theorem automatically holds.

But the theorem should be STATED. It is the reason vocab authors can rely on `map (Amplify _ y s) xs` behaving as a valid Functor-mapping: because `Amplify(_, y, s)` is a thought-to-thought function and `map` preserves its composition.

### 4.4 `:Any` as escape hatch

058-030 admits `:Any` for Cleanup's heterogeneous candidates. This is fine pragmatically but categorically it is the terminal object of the type lattice — everything subtypes it. **Uses of :Any should be tracked**; if stdlib uses :Any in positions other than Cleanup, the system is leaking types.

---

## 5. Per-proposal verdict table

| # | Form | Class | Verdict | Reasoning |
|---|---|---|---|---|
| 001 | Atom typed literals | CORE | **ACCEPT** | Type-aware hash is categorically sound; expansion preserves functoriality of encode. Answer Q1: type-first-then-value is correct; it preserves injectivity on the (tag, value) space. |
| 002 | Blend | CORE | **ACCEPT** | Pivotal, algebraically clean. Option B is correct (Circular requires it). Caveat: state that Blend is NOT commutative in the vector arguments when w1 ≠ w2 (proposal Q1 notes this; should be a stated LAW). |
| 003 | Bundle list sig | CORE | **ACCEPT-WITH-CHANGES** | Lock the list signature. BUT also STATE the non-associativity law. See §2.1. |
| 004 | Difference | STDLIB | **ACCEPT-WITH-CHANGES** | Only if cache canonicalization is resolved as per §2.6. Otherwise REJECT as complection with Subtract. |
| 005 | Orthogonalize | CORE | **ACCEPT-WITH-CHANGES** | Rewrite the invariant claim — "orthogonal to Y" holds pre-threshold only. See §2.2. |
| 006 | Resonance | CORE | **ACCEPT** | Genuinely new operation; ternary output justified. MUST be paired with explicit statement that this introduces a second object kind (ternary) with weakened laws on downstream ops (see §2.3). |
| 007 | ConditionalBind | CORE | **UNCONVINCED** | A valid operation, but Select(x, y, gate) (058-007 Q3) is strictly more primitive and would let ConditionalBind become stdlib (`Select(Bind(a,b), a, gate)`). The question isn't "is it useful?" — it's "is this the right abstraction level?". Recommend: propose Select first, then ConditionalBind as stdlib. |
| 008 | Linear (stdlib) | STDLIB | **ACCEPT** | Clean factoring. Dependency on Blend resolved correctly. |
| 009 | Sequential reframing | STDLIB | **ACCEPT** | Ends grandfathering honestly. Non-associativity of Sequential under nesting should be stated as a law (see §2.5). |
| 010 | Concurrent | STDLIB | **ACCEPT-WITH-CHANGES** | Only if cache canonicalizes to Bundle (see §2.6). |
| 011 | Then | STDLIB | **ACCEPT** | Clean binary atom for pairwise temporal relation. |
| 012 | Chain | STDLIB | **ACCEPT-WITH-CHANGES** | Document that nested-Bundle encoding loses information vs. flat (§2.4). |
| 013 | Ngram | STDLIB | **ACCEPT-WITH-CHANGES** | Same as 012. Also: n=0 and n>len edge cases should be specified (defaults to empty Bundle = zero vector = NOT in bipolar kind). |
| 014 | Analogy | STDLIB | **ACCEPT** | Canonical VSA form; clean composition over Bundle + Difference. |
| 015 | Amplify | STDLIB | **ACCEPT-WITH-CHANGES** | Only if cache canonicalizes — otherwise overlaps with Subtract at s=-1 and Flip at s=-2 (§2.6). |
| 016 | Map | STDLIB | **ACCEPT** | Role-filler dictionary is the canonical VSA structure. |
| 017 | Log (stdlib) | STDLIB | **ACCEPT** | Clean factoring like Linear. |
| 018 | Circular (stdlib) | STDLIB | **ACCEPT** | Circular's cos/sin weights are the justification for Blend Option B. |
| 019 | Subtract | STDLIB | **ACCEPT-WITH-CHANGES** | See 015. Either canonicalize or pick one of Subtract/Difference. |
| 020 | Flip | STDLIB | **ACCEPT-WITH-CHANGES** | The `-2` weight needs its "minimum inversion weight" derivation stated as a proof, not a convention. See §6.2. |
| 021 | Bind | CORE | **ACCEPT-WITH-CHANGES** | Self-inverse law must be stated conditionally: holds for bipolar only (§2.3). |
| 022 | Permute | CORE | **ACCEPT-WITH-CHANGES** | State the three laws (invertibility, linearity over Bundle, distribution over Bind) explicitly. See §1.4. |
| 023 | Thermometer | CORE | **ACCEPT** | Canonical scalar gradient primitive. Atom-to-position mapping must be documented (Q2) — it is part of the algebra's determinism story. |
| 024 | Unbind | STDLIB | **ACCEPT-WITH-CHANGES** | Unbind ≡ Bind on bipolar; the alias is reader-intent only. Under ternary, they DIVERGE. The proposal must state which behavior Unbind has on ternary inputs (which is needed if Resonance produces gates that are then Unbind-inputs). |
| 025 | Cleanup | CORE | **ACCEPT-WITH-CHANGES** | Cleanup IS categorically distinct — it's a selector, not a morphism. Affirm as core. Future: decompose into Similarity + Argmax per 058-025 Q2 — this is the cleaner factoring. |
| 026 | Array | STDLIB | **ACCEPT-WITH-CHANGES** | Only if cache canonicalizes (§2.6). Also: nth's bounds-checking semantics (Q4) should be specified, not "user's responsibility". |
| 027 | Set | STDLIB | **ACCEPT-WITH-CHANGES** | Same as 010/026. |
| 028 | define | LANG CORE | **ACCEPT** | Sound; required for stdlib to exist. |
| 029 | lambda | LANG CORE | **ACCEPT** | Clean decomposition (lambda + registration = define). Closure capture is well-understood. |
| 030 | types | LANG CORE | **ACCEPT-WITH-CHANGES** | Add: (a) variance rules for :List (covariant) and :Function (standard); (b) parametricity statement — free theorems hold for polymorphic stdlib; (c) type-lattice diagram in FOUNDATION. |

**Summary counts:** ACCEPT 9, ACCEPT-WITH-CHANGES 20, UNCONVINCED 1, REJECT 0.

---

## 6. Answers to the 178 questions (categorical filter)

I answer only the questions where my lens gives a clear answer, cited by proposal-number / question-number.

### 058-001 (Atom)
- **Q1 (type-aware hash soundness):** Type-first-then-value is categorically correct. It makes Atom's domain `(TypeTag × Bytes)` injective on the quotient that merges bytes-equal-within-type. `Atom(1) ≠ Atom("1") ≠ Atom(1.0)` is the right rule.
- **Q3 (Null as atom):** Accept `Atom(Null)` as a first-class atom. It is the initial object of the literal space (vacuous payload) and is needed for the :Option type in 030. Rejecting it means representing absence structurally, which complicates every option-returning function.
- **Q6 (type erasure on vector side):** Correct model. Encoding is a lossy projection; recovery requires either the AST or a cleanup codebook. This is a fundamental feature of VSA and should not be "fixed."

### 058-002 (Blend)
- **Q1 (distinct source category):** YES — scalar-weighted combination is a linear-map-like operation; Bundle is a monoid; they are different categorically.
- **Q2 (Option A vs B):** Option B. Circular's weights rule out Option A.
- **Q3 (negative weights):** Allow. Mathematics is consistent; the "blurring" concern is naming, not algebra.
- **Q4 (variadic temptation):** Reject. Variadic Blend would subsume Bundle, but Bundle's non-associativity (§2.1) means n-ary Bundle is not binary-Blend-foldable. Keeping them separate preserves the MAP canonical set.

### 058-005 (Orthogonalize)
- **Q1 (core vs widened Blend):** Core. Widened Blend with computed weights changes Blend's character from "literal weight Blend" to "general linear-combination-with-computed-scalars", which is a larger proposal. Keep Orthogonalize focused.
- **Q2 (Project as companion form):** YES. Propose it. Zero-cost and completes the Gram-Schmidt pair.
- **Q4 (zero-magnitude y):** Return `x` unchanged. Document as an explicit edge case in the semantics, not "the implementation must handle."

### 058-006 (Resonance)
- **Q1 (ternary as supported kind):** Formalize ternary as a SECOND object kind in the algebra. FOUNDATION should have a section on object kinds; stating "everything is bipolar" is false once Resonance is core.

### 058-007 (ConditionalBind)
- **Q3 (Select as the primitive):** Yes — propose Select, let ConditionalBind be stdlib. This is the cleaner factoring.

### 058-014 (Analogy)
- **Q5 (Plate/Kanerva formulations):** The Bundle-based `c + (b - a)` formulation is what Kanerva/Plate call "addition-based analogy" and works well when the codebook for cleanup is known. It does NOT work under pure circular-convolution VSA (Plate HRR) without adaptation. Since holon is MAP VSA, the proposal's form is correct for the substrate.

### 058-022 (Permute)
- **Q2 (permutation choice):** Cyclic shift is conventional and is what holon-rs uses. Standardize it in FOUNDATION. Non-cyclic permutations (fixed random) are a perf/entropy tradeoff but don't add algebraic power.
- **Q5 (invertibility as hard requirement):** YES, hard requirement. Every stdlib positional form (Sequential, Array, nth) requires it. A non-invertible Permute would break the algebra.

### 058-025 (Cleanup)
- **Q2 (decompose into Similarity + Argmax):** YES, but as a future proposal. The decomposition is categorically cleaner (Similarity is a natural transformation, Argmax is a selector over finite families), but the current monolithic Cleanup is useful as-is. Don't block on this.

### 058-030 (types)
- **Q1 (generics scope):** Minimal is fine; add variance rules per §4.2.
- **Q8 (subtype hierarchy):** `:Atom <: :Thought` yes. Add full lattice diagram in FOUNDATION.

### Cross-cutting: Theme "AST preservation vs eager expansion"
**Answer:** Eager expansion (canonicalization) for aliases. Otherwise cryptographic identity breaks (§2.6). The "preserve name for readable AST walks" argument is a tooling concern that should be handled by separate pretty-printing metadata, not by letting the AST carry multiple names for the same thought.

### Cross-cutting: Theme "Naming — alias proliferation"
**Answer:** Given canonicalization, aliases are cheap. Accept all of them. Without canonicalization, pick ONE per equivalence class (Subtract OR Difference, not both).

### Cross-cutting: Theme "Ternary / non-bipolar"
**Answer:** Formalize ternary as a second object kind. Document which ops close over which kinds. Bind's self-inverse law is conditional on bipolar inputs.

---

## 7. Laws that should be stated and aren't

Every algebraic proposal should carry a **laws section** with explicit equations. The 058 batch is remarkably close to doing this but leaves many laws implicit. Here is the minimum set that should be stated explicitly:

### Bind (058-021)
- **L1:** For `a, b, c ∈ V_bipolar`: `Bind(a, Bind(b, c)) = Bind(Bind(a, b), c)` (associativity in the multiplicative group).
- **L2:** `Bind(a, b) = Bind(b, a)` (commutativity).
- **L3:** `Bind(a, 1_d) = a` where `1_d` is the all-+1 vector (identity).
- **L4 (self-inverse, qualified):** For `a, b ∈ V_bipolar`: `Bind(Bind(a, b), b) = a`.
- **L4' (ternary degradation):** For `b ∈ V_ternary` with `b[i] = 0`, L4 fails at position `i`.

### Bundle (058-003)
- **L5 (commutativity):** `Bundle(xs)` is invariant under permutations of `xs`.
- **L6 (NON-associativity):** `Bundle([Bundle(xs), y]) ≠ Bundle(xs ++ [y])` in general. Bundle is n-ary, not fold-able over a binary form.
- **L7 (zero-elem handling):** `Bundle([])` is a degenerate case; the zero vector is not in the bipolar kind. Either define a "null bundle" atom or document as UB.

### Permute (058-022)
- **L8 (group action):** `Permute(Permute(v, j), k) = Permute(v, j + k)` mod d.
- **L9 (invertibility):** `Permute(Permute(v, k), -k) = v`.
- **L10 (linearity over Bundle):** `Permute(Bundle(xs), k) = Bundle([Permute(x, k) for x in xs])`.
- **L11 (distribution over Bind):** `Permute(Bind(a, b), k) = Bind(Permute(a, k), Permute(b, k))`.

### Blend (058-002)
- **L12 (pre-threshold commutativity for equal weights):** `Blend(a, b, w, w) = Blend(b, a, w, w)`.
- **L13 (non-commutativity for unequal weights):** `Blend(a, b, w1, w2) ≠ Blend(b, a, w1, w2)` when `w1 ≠ w2`.
- **L14 (Blend is NOT a monoid):** there is no Blend-identity in the bipolar kind.
- **L15 (specialization to Bundle):** `Blend(a, b, 1, 1) = Bundle([a, b])`.

### Orthogonalize (058-005)
- **L16 (pre-threshold orthogonality):** The real-valued projection-subtracted vector is exactly orthogonal to Y.
- **L17 (post-threshold approximate orthogonality):** The bipolar-thresholded vector is approximately orthogonal to Y with error `O(d^{-1/2})` in cosine. NOT EXACTLY ZERO.

### Resonance (058-006)
- **L18 (idempotence):** `Resonance(Resonance(v, ref), ref) = Resonance(v, ref)`.
- **L19 (output kind):** `Resonance: V_bipolar × V_bipolar → V_ternary`.

### encode functoriality
- **L20:** For every algebra operation `op(x, y, ...)`, `encode(op(x, y, ...)) = op_vector(encode(x), encode(y), ...)`.
  - Holds for Atom, Bind, Bundle, Permute, Blend, Thermometer, Orthogonalize, Resonance, ConditionalBind.
  - Does NOT hold for eval or any reduction operation (encode is not reduction-invariant).

### Parametricity (058-030)
- **L21 (List covariance):** If `T <: T'`, then `(:List T) <: (:List T')`.
- **L22 (Function variance):** `(:Function [T_in] T_out) <: (:Function [T'_in] T'_out)` iff `T'_in <: T_in` (contravariant in) and `T_out <: T'_out` (covariant out).
- **L23 (free theorem for map):** `map (f ∘ g) = (map f) ∘ (map g)` up to extensional equality.

---

## 8. Constructions I would propose

### 8.1 A distinguished `:wat/algebra/zero` atom

Let the algebra reserve `(Atom :wat/algebra/zero)` as the constant all-zeros vector (or all-+1 for Bind's identity, `:wat/algebra/one`, depending on which identity). This gives:

- Bundle has an explicit right-identity: `Bundle([t, Atom(:wat/algebra/zero)]) = t`
- Blend has explicit identity behavior at zero-weight positions

Without this, the algebra cannot state `Bundle([]) = identity`; it has to state "Bundle over empty is UB."

### 8.2 `Project(x, y)` as explicit stdlib form

Dual of Orthogonalize. `Project(x, y) = Blend(x, Orthogonalize(x, y), 1, -1)` (approximately). Useful on its own.

### 8.3 `Dissonance(v, ref)` as explicit stdlib form

Dual of Resonance. `Dissonance(v, ref) = Blend(v, Resonance(v, ref), 1, -1)` (in real-valued; bipolar after threshold).

### 8.4 `Select(x, y, gate)` as the primitive, ConditionalBind as stdlib

`Select(x, y, gate)[i] = x[i] if gate[i] > 0 else y[i]`.

Then `ConditionalBind(a, b, gate) = Select(Bind(a, b), a, gate)`. More primitive; more composable; enables other per-dimension operations (Mask, IfElseVector).

### 8.5 `unfold(bundled-thought, roles, codebook)`

The generic decode-to-list accessor. Formalizes the inverse of Map-construction.

### 8.6 Add object-kind declaration

FOUNDATION should name the two vector kinds explicitly:

- **`V_bipolar` = {-1, +1}^d** — output of Bind, Bundle (via threshold), Permute, Blend (via threshold), Thermometer, Atom.
- **`V_ternary` = {-1, 0, +1}^d** — output of Resonance; can be input to Bind/Bundle (with law degradations).

Stating these is essential for reasoning about when laws hold.

### 8.7 Canonicalization pass in the AST pipeline

Before hashing and caching, normalize all aliases to their canonical form:
- `Concurrent(xs) → Bundle(xs)`
- `Set(xs) → Bundle(xs)`
- `Array(xs) → Sequential(xs)`
- `Difference(a, b) → Blend(a, b, 1, -1)`
- `Subtract(a, b) → Blend(a, b, 1, -1)`
- `Amplify(x, y, 1) → Bundle([x, y])` (and similar collapses)

This is ~50 lines of Rust in the wat-vm and preserves the cryptographic-identity story.

---

## 9. Closing

The 058 batch is a serious algebraic design document. The authors have internalized the composition-first perspective and the 30-proposal-per-form discipline is a good way to surface laws. My pushback is not on direction but on **rigor of statement**: laws that hold should be written down; laws that fail (like Bundle-associativity, post-threshold-orthogonality, ternary-Bind-reversibility) must be stated with their failure modes; aliases without canonicalization threaten the foundational cryptographic-identity claim.

If the batch incorporates:

1. A law-table in FOUNDATION with L1–L23 above.
2. The Orthogonalize claim correction (§2.2).
3. The ternary-kind formalization (§2.3, §8.6).
4. A canonicalization pass for aliases (§2.6, §8.7).
5. Variance rules for the type system (§4.2).
6. A type-lattice diagram.

— then I believe the algebra is categorically sound and the implementation in the Rust wat-vm is supported by a faithful mathematical specification. As currently stated, it is 80% there. The remaining 20% is where the composition actually has to work, so it matters.

*— the categorical reviewer*

**Addendum:** the HYPOTHETICAL-CANDLE-DESCRIBERS.wat example is mathematically sound: each describer produces a thought, scoring is cosine against the candle's own thought-encoding, alive-filter eliminates `Atom(:null)` outputs, ranking is a deterministic sort. The `Atom :null` sentinel depends on 058-001 Q3's resolution (accept Null as atom). The rest composes cleanly. One note: `:demo/on-candle` returns `:Option :Function` but the `:Option` type is only mentioned in the proposal as an example `deftype`; it needs to be in the loaded type universe for the example to typecheck. Nit.
