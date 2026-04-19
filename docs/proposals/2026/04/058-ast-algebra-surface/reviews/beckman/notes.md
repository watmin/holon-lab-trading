# Beckman Round 3 — working notes

## Orientation

Round 3 has done substantial work. Let me catalog what has landed vs what remains.

### What's different from Round 2

1. **Similarity-measurement reframe.** FOUNDATION §"The algebra is similarity-measured, not elementwise-exact" + §"Bind as query" + §"Algebraic laws under similarity measurement" explicitly acknowledge Bundle's non-associativity AT THE ELEMENTWISE LEVEL and state associativity UNDER SIMILARITY MEASUREMENT AT HIGH d. The Round-2 counter-example is preserved verbatim in FOUNDATION line 1560-1565.

2. **Reject + Project stdlib.** 058-005 ACCEPTED as stdlib macros over Blend + a new scalar measurement primitive `:wat/algebra/dot`. Algebra core shrinks 7 → 6.

3. **Ten forms REJECTED**: Resonance, ConditionalBind, Flip, Chain, Concurrent, Then, Unbind, Cleanup, Difference, Linear. Analogy DEFERRED.

4. **Parametric polymorphism substrate.** 058-001 Atom accepted as `:Atom<T>`. 058-030 types parametric. 058-032 typed macros parametric. Programs-ARE-Atoms corollary added.

5. **Sequential reframed to bind-chain.** 058-009 ACCEPTED with expansion:
   `Sequential([a,b,c]) = Bind(Bind(a, Permute(b,1)), Permute(c,2))` — compound, not superposition.

6. **Thermometer contradiction resolved.** CORE-AUDIT names 3-arg form `(Thermometer value min max)` as authoritative. FOUNDATION body matches.

7. **Measurement tier added.** `cosine` and `dot` as scalar-returning primitives, orthogonal to HolonAST-producing forms. Explicit in FOUNDATION §"Algebra Measurements."

8. **Blend accepted as Option B.** Two independent real-valued weights, negative allowed, binary arity.

## Round-2 Finding Resolution Audit

### Finding NEW-1 (critical): "Bundle is associative" was false

**Round-2 counter-example:** at d=1, ternary threshold, `Bundle([+1, +1, -1])`:
- Flat: `threshold(+1) = +1`
- Left: `Bundle([threshold(+2), -1]) = Bundle([+1, -1]) = threshold(0) = 0`
- Right: `Bundle([+1, threshold(0)]) = Bundle([+1, 0]) = threshold(+1) = +1`
- Three routes, two answers.

**Round-3 response (FOUNDATION lines 1556-1569):** The counter-example is PRESERVED VERBATIM in FOUNDATION with the explicit admission "Associativity does NOT hold elementwise under ternary thresholding." The claim is weakened to "Under similarity measurement, Bundle IS associative at high d."

Let me check this rigorously.

**The claim to verify:** at d=10,000 with bundle sizes within the ~100-item capacity budget, `cosine(Bundle([Bundle([a,b]), c]), Bundle([a,b,c])) > 5σ ≈ 5/√d = 0.05`.

**Quick sketch:** for bundles within capacity, the fraction of dimensions where partial-sum magnitudes exceed ±1 during left-association is bounded. Specifically, at each position i, the pre-threshold flat sum is `s = x[i] + y[i] + z[i]` with `s ∈ {-3,-2,-1,0,1,2,3}`. The left-association result is `threshold(threshold(x[i]+y[i]) + z[i])`. For `s = ±3`: flat=±1, left=±1 (same). For `s = ±1`: flat=±1, left depends on inner sum. For `s = 0`: flat=0, left depends.

Concretely at d=1 with K=3 dense-bipolar items:
- 8 possible sign combinations of `(x[i], y[i], z[i])`; flat vs left-assoc match in 6 of 8, differ in 2.
- Over d positions with independent signs, expected disagreement fraction = 2/8 = 0.25.
- For dense-bipolar random inputs, `dot(flat, left) ≈ d · (1 - 2·0.25) = 0.5d`.
- `cosine ≈ 0.5`, well above noise floor 0.05. OK.

So at d=10,000 the similarity-associativity claim holds for K=3 bundles. BUT the claim generalizes: as K grows, the disagreement fraction at each position grows. For deep nesting (say N levels deep of pair-Bundles), the accumulated disagreement matters.

At the capacity limit (~100 items per frame), what's `cosine(flat, fully-left-nested)`? Rough estimate: each threshold-at-intermediate step with >1 item above introduces approximately O(1/K) noise per dimension. For K=100 items fully left-nested, cumulative drift per dimension... this gets complicated. The FOUNDATION claim "at high d with bundle sizes inside the capacity budget, cosine(nested, flat) > 5σ" is a plausible but unproven empirical claim, NOT a theorem.

**Verdict on Round-2 NEW-1:** The non-associativity is now HONESTLY STATED. The stronger "similarity-associative at high d" claim is plausible and pragmatic but is stated without a proof. This is acceptable as a substrate property — VSA literature contains this pattern — but it is a CAPACITY CLAIM, not a categorical associativity claim. Beckman-honest framing:

> "Bundle is a commutative n-ary operation. It is not an elementwise associative monoid. Under cosine similarity with K ≤ capacity(d), different bracketings produce vectors whose pairwise similarity stays above the 5σ noise floor — enough for downstream presence measurement to be bracket-invariant in practice."

That matches FOUNDATION's language. Good. Round 2's concern DISSOLVES under the reframe, not because the algebra became associative but because the claim was properly weakened to what the substrate actually guarantees.

**Subtle point:** FOUNDATION also says "Chain, Ngram, Sequential, HashMap are DESIGNED to avoid unnecessary nesting: they produce one Bundle per form, flattening internally." This is a PRODUCTION DISCIPLINE, not an algebra law. The algebra does NOT enforce that users avoid nesting. That's OK as long as it's explicit. FOUNDATION is explicit. Accept.

### Finding NEW-2 (critical): Thermometer signature contradiction

Round 2: FOUNDATION said `(Thermometer value min max)` 3-arg; 058-023/008 said `(Thermometer atom dim)` 2-arg.

Round-3: CORE-AUDIT.md Thermometer entry (lines 152-218) — 3-arg form is canonical. FOUNDATION line 2336-2352 matches. 058-008 (Linear) REJECTED as redundant with Thermometer itself (because under 3-arg form, Linear IS Thermometer with min=0). This is self-consistent.

**Verdict:** RESOLVED. Thermometer has one signature: `(Thermometer value min max)` with canonical layout (first N=round(d·t) dimensions are +1, rest -1). This gives exact linear cosine geometry. Clean.

### Finding NEW-3: HYPOTHETICAL old-syntax

Need to check. Let me note as TODO.

### Finding NEW-4: Capacity-budget bundles three distinct phenomena

Round-2 noted that Bundle crosstalk (noise ~ 1/√K), sparse-key Bind decode (recovery ~ √p), Bundle non-associativity (magnitude loss), and Orthogonalize residual are all "similarity-measured" but are DIFFERENT mathematical phenomena.

Round-3 response: FOUNDATION §"Capacity is the universal measurement budget" lines 1577-1594 explicitly names these as "the SAME substrate property: signal-to-noise at high dimension, characterized uniformly by Kanerva's formula, measured uniformly by cosine." The document IS clear that they are distinct formulas on common framework, saying "not separate phenomena or separate 'algebraic flaws'" - which is arguably still oversmoothing. But pragmatically it's an honest operational framing. User doesn't need per-phenomenon formulas in prose; the substrate measures cosine; cosine > 5σ or not. Accept with note that the per-phenomenon formulas should eventually appear in a Laws appendix. Same lens as Round 2.

### Finding NEW-5: defmacro Q5 hash over expansion vs source

The cryptographic verification across the expansion/source boundary wasn't fully specified in Round 2. Let me check if resolved... Not load-bearing for algebraic composition; defer. The hash identity = expanded form is clean; source-level signing is a separate concern.

### Finding NEW-6: inventory count mismatch

Language core count 8 vs 9. Check INDEX.md — says "Language core: 5 forms" in summary. FOUNDATION §"Algebra — Complete Forms" says "Language Core (8 forms)". Still has drift. Minor.

---

## NEW Round-3 issues

### Issue R3-1: Sequential bind-chain vs bundle-sum mechanical inconsistency

**FOUNDATION line 2405 shows the OLD bundle-sum expansion:**
```
(:wat/core/define (:wat/std/Sequential list-of-holons)
  ;; positional encoding
  ;; each holon permuted by its index (Permute by 0 is identity)
  (:wat/algebra/Bundle
    (map-indexed
      (:wat/core/lambda (i h) (:wat/algebra/Permute h i))
      list-of-holons)))
```

**058-009 PROPOSAL.md (ACCEPTED) uses bind-chain:**
```
(:wat/std/Sequential [a b c]) = Bind(Bind(a, Permute(b, 1)), Permute(c, 2))
```

**FOUNDATION line 1961 comment says "(macro, bind-chain)"** — acknowledging what it should be — but the actual code at 2405 is wrong.

Also FOUNDATION line 2956 (in "What 058 Argues" inventory):
```
(:wat/std/Sequential list)              ; 058-009  — reframing: Bundle of index-permuted
```
Also wrong. Still says "Bundle of index-permuted."

**This matters categorically** because Bind-chain and Bundle-of-Permutes are DIFFERENT OPERATIONS with different composition properties:
- **Bind-chain** produces a *compound* vector — strict sequence identity; two sequences differing in one item have very dissimilar compounds.
- **Bundle-of-Permutes** produces a *superposition* — approximate recovery of items at positions via unbind; softer matching; different cosine behavior.

The compound has dense-bipolar output (Bind of bipolar inputs stays bipolar). The bundle-of-Permutes has ternary output with cancellations. These don't even live in the same density regime.

**This is a load-bearing mechanical bug in FOUNDATION.** The proposal is accepted with one expansion; FOUNDATION still shows the other. Reviewers/implementers reading FOUNDATION first will get a different operation than what was accepted. The docs are inconsistent with themselves.

### Issue R3-2: Sequential bind-chain has no identity

Under the new bind-chain expansion:
- `Sequential([a]) = a` (identity — one-item case is trivial)
- `Sequential([a,b]) = Bind(a, Permute(b, 1))`
- `Sequential([])` = ?

What is Sequential of an empty list? Bind has no natural identity in the ternary algebra (would need all-+1 vector, which is not a reserved atom). Bundle's identity is the all-zero vector. The proposal doesn't specify. This matters for Ngram's edge case: `Ngram(n, xs)` where `n > length(xs)` produces an empty bundle; but also, Ngram produces bundle-of-Sequentials; if any window were empty that would be Sequential([]).

Looking at 058-013: "n > length produces an empty bundle (zero vector) per Bundle's empty-input behavior." OK so empty list through `map` → empty list → `Bundle([])` = zero vector. That works because windows of size n over a list of length k produce max(0, k-n+1) windows; fewer than 1 window means `map` returns empty list; `Bundle([])` = 0. OK.

**But** the atomicity of Sequential([]) is undefined. Accept this as a minor edge case — stdlib can refuse empty lists to Sequential at macro expand time or document the undefined behavior. Not a blocker.

### Issue R3-3: Parametric Atom recursion — Atom<Holon> where Holon contains Atom

**The setup.** `(Atom x)` is parametric over T. T can be any primitive, any `:Holon` (including another Atom), any user type. `:Holon` is the union of algebra AST variants including Atom. So we have:

```
Atom : T → Holon
Holon = Atom<T> | Bind(Holon, Holon) | Bundle(List<Holon>) | ...
```

This is a recursive type. Mathematically: `Holon` is the fixed point of the functor `F(X) = Atom<T> ⊔ Bind(X, X) ⊔ Bundle(List<X>) ⊔ ...` where `T` itself can be `X`. So `Atom<Holon>` is `Atom<μX. F(X))` = `Atom<Holon>`. Standard ADT recursion.

**Is this sound?**

Yes — it's just an ADT with a recursive variant. Same as `List<T>` being `Cons<T, List<T>> | Nil`, or any tree type. No paradox. EDN serialization handles the recursion fine (EDN serializes arbitrary nested structures).

**Is hashing a functor of T?**

The hash is `hash(type-tag, canonical-EDN(value))`. For `T = Holon`, EDN of a Holon is recursive. Claim: `hash_T(x) = hash(type-tag(T), edn(x))` is well-defined because EDN is well-defined for any T in the universe. Check. Is it natural with respect to T? A type tag is needed so that `Atom<i64>(0)` ≠ `Atom<String>("0")`. The type-tag-aware hash is exactly the tagged-union encoding — a coproduct of all possible T's, with the tag selecting the variant.

Categorically: `Atom : Type → (T: Type) → Holon` where the outer `Type` is a syntactic kind. The hash is a natural transformation from the serialization-type functor to the vector-space. I think this is sound.

**The subtle bit — Atom<Holon> vs direct encoding.**

A Bundle `b = (Bundle [x y z])` encodes via children composition to a structural vector with density and structure preserved. But `(Atom b)` encodes via `hash(type-tag(Holon), edn(b))` → a SEEDED RANDOM vector. These are DIFFERENT vectors for the same underlying holon!

FOUNDATION acknowledges this (lines 350-355): "Two encodings of the same composite — both valid." Direct = structure recoverable; Atomized = opaque identity. OK.

**Is this categorically sensible?**

Yes. `Atom<_>` is an *identity-forming* functor — it takes a thing and gives you a fresh hash identity, losing all interior structure in the vector projection (but retaining full interior recoverability in the AST — `atom-value` unwraps). The operation is a kind of quotienting: `Atom(x)` is x's content-hashed name, not x's structure.

In category-theory terms: consider the category of Serializable things + morphisms that preserve content. `Atom<_>` is a functor from this category to the category of Vectors + cosine. It's not structure-preserving at the vector level (different bundles give different atom-vectors uncorrelated with the bundle's structure), but it's identity-preserving (same EDN → same hash → same vector).

The encoding has TWO legitimate modes: the structural encode E and the atomic encode A. For any composite h, these produce different vectors. The algebra treats both as valid. This is not a contradiction — it's an honest acknowledgment that you can measure "is this the same program by identity" (use A) or "is this program structurally similar" (use E).

**Verdict on parametric Atom:** categorically sound. The recursion in `Atom<Holon>` is just ADT recursion. The two-encoding ambiguity is a feature, not a bug, as long as applications know which they're calling.

**Remaining concern:** what if somebody computes `Atom(Atom(x))`? That's `Atom<Atom<T>>`. Each wrap produces a new opaque vector. `hash(Atom, hash(Atom, value))`. Well-defined, but does it compose meaningfully? `atom-value(atom-value(Atom(Atom(x)))) = x`. The extraction composes — it's the inverse functor. OK.

### Issue R3-4: Measurement tier — categorical soundness

The measurement tier is `cosine : Holon × Holon → f64` and `dot : Holon × Holon → f64`.

These are bilinear (dot) and nearly-bilinear (cosine, after normalization). They're NOT HolonAST producers; they're scalar-returning. This is a clean categorical separation:

- **Holon-producing operations** form a category `C1` with Holons as objects and the algebra ops as morphisms (sort of — the algebra is closed under these).
- **Measurement operations** form a functor `M: C1 × C1 → f64` mapping pairs of Holons to reals.

This is a separation of "structure-producing" from "structure-measuring" tiers. Categorically clean.

**Does the measurement tier preserve the algebra's independence?**

Yes and no. `dot` is used INTERNALLY by stdlib macros Reject and Project. These macros produce Holons whose expansions reference `dot` as a WEIGHT computation. So the HolonAST variant `Blend(a, b, w1, w2)` with `w2 = -dot(a,b)/dot(b,b)` has scalar weights computed from a measurement.

Does this couple the tiers? Categorically:

- Before: Blend's weights are literal f64 (constants at AST construction time).
- After: Blend's weights can be arbitrary f64-producing expressions, including measurement calls.

This means the AST no longer contains constant weights — it contains expressions for weights. The AST structure is richer. When a `Reject(x, y)` macro expands to `Blend(x, y, 1, -dot(x,y)/dot(y,y))`, the resulting AST has DOT call sites embedded inside it. The weight is not a scalar literal but a scalar expression.

**Implication for hash identity:** `hash(Reject(x, y))` = `hash(expanded-Blend-with-dot-expressions)`. This works as long as the expansion is deterministic and the dot-expression's AST is canonically representable. Should be fine.

**Implication for encoding:** when encoding `Reject(x, y)`, the weight must be computed from `x` and `y`. But `dot(x, y)` depends on the vector forms of x and y — which require encoding them first. So the encoding of Reject has a dependency: encode(x), encode(y), compute dot, compute weight, compute Blend. Order of evaluation matters but the result is deterministic.

Categorically this is fine — it's a dependent computation: encoding a Blend with computed weights requires first encoding the operands. No circularity. OK.

**Is there a parametricity concern?**

`cosine : Holon × Holon → f64` is polymorphic only over the trivial sense that it takes any two holons. No type variables to instantiate. Similarly dot. Good — these are monomorphic at the Holon × Holon level. No naturality concerns beyond the fact that cosine is invariant under permutation of arguments (`cosine(a, b) = cosine(b, a)`) and scaling.

**Verdict:** measurement tier is categorically clean and orthogonal to the vector-producing tier. The Reject/Project stdlib macros couple the tiers via dot-valued weights, but this is a dependent-weight pattern, not a categorical complection. The algebra core stays Holon-producing; the measurement tier stays scalar-producing; macros compose across them.

### Issue R3-5: Reject (post-threshold) and the similarity-measurement frame

In Round 2 I showed that `Reject(x, y)` (then called Orthogonalize) fails to produce an exactly-orthogonal result post-threshold in general.

FOUNDATION line 1571-1575 restates: "For degenerate X = Y, the result is exactly all-zero... But for general X, Y where the projection coefficient is fractional, the elementwise claim fails... Under similarity measurement, Reject produces a result that is orthogonal to Y up to the capacity budget."

This is the same reframe as Bundle: elementwise law fails, similarity-measured law holds. Counter-example preserved.

**Issue:** the FOUNDATION claim "orthogonal to Y up to the capacity budget" is vague. What's the cosine bound? For my Round 2 counter-example at d=4: `X=[+1,+1,+1,-1]`, `Y=[+1,+1,+1,+1]`, Reject(X,Y) = [+1,+1,+1,-1] = X. cosine(X, Y) = 2/4 = 0.5. Post-threshold the "orthogonal complement" has cosine 0.5 with Y — NOT near-zero.

At d=4 that's above noise floor (noise = 5/√4 = 2.5, but cosines are bounded by 1; this formula breaks at low d). At d=10,000 with random X, Y: the post-threshold Reject has expected cosine ~0 because random high-d vectors are naturally near-orthogonal regardless of the Reject step. The Reject doesn't really DO anything at high d for random inputs — they were already near-orthogonal.

**What does Reject actually do in production?** DDoS sidecar: `reject(packet, baseline_subspace)` where baseline_subspace is a learned subspace (OnlineSubspace). The "subspace" is a set of principal components; Reject iterates across them. For a packet that DOES have significant overlap with the subspace, Reject removes that overlap; the residual has cosine with subspace-component low.

So the claim "Reject produces orthogonal-to-Y within budget" is meaningful for the high-overlap case (the interesting case in practice). For random inputs, the statement is trivially true because they were already orthogonal.

**Categorical judgment:** The reframe is honest but the bound is not given in FOUNDATION. A Beckman-grade FOUNDATION would state:

> "For non-trivial overlap cases (where `|x·y|/(|x|·|y|)| > 5σ`), `Reject(x, y)` post-threshold produces a vector whose cosine with y is at most ~ noise_floor(d). For low-overlap cases, Reject is approximately identity."

That'd be a proper law. Current FOUNDATION gestures at it. Acceptable, not rigorous.

### Issue R3-6: Blend non-commutativity

`Blend(a, b, w1, w2) ≠ Blend(b, a, w1, w2)` when `w1 ≠ w2`. But `Blend(a, b, w1, w2) = Blend(b, a, w2, w1)` — swap args AND swap weights. This is the binary generalization of commutativity for weighted binary ops. Needs explicit statement as a law.

058-002 acknowledges Q1: "non-commutative in the vector arguments when w1 ≠ w2." Good. But doesn't state the swap-weighted symmetry. Minor.

### Issue R3-7: The REJECTED ten — are any of them algebraically necessary?

Let me check each.

1. **Resonance** (sign-agreement mask). Rejected as speculative. Expressible as `Mask(x, threshold(Bind(x, y), +1))` where Mask is... not primitive either. FOUNDATION claims it as a three-primitive composition. Let me think — `Resonance(x, y)[i] = x[i] if sign(x[i]) = sign(y[i]) else 0`. That's `x[i] * (Bind(x,y)[i] > 0 ? 1 : 0)`. Needs a per-dim mask operation. Not trivially available in current algebra. Is it truly REDUNDANT or is it a missing primitive? If not production-cited, rejecting is fine; but the algebra does LACK a per-dim conditional. If needed later, re-propose. OK.

2. **ConditionalBind** — similar. Per-dim gated operation. Not available in core. Rejected as speculative. Same verdict.

3. **Flip** (`Blend(x, y, 1, -2)`). Rejected for magic weight + primer-naming-collision. The primer's single-arg `flip` (negation) would be a legitimate simple operation but wasn't proposed. Accept rejection.

4. **Chain** — redundant with Bigram (= Ngram 2). Accept.

5. **Concurrent** — alias for Bundle. Accept.

6. **Then** — alias for binary Sequential. Accept.

7. **Unbind** — identity with Bind. Accept.

8. **Cleanup** — retrieval via presence measurement, not argmax. Accept the reframe.

9. **Difference** — duplicate of Subtract. Accept keeping Subtract.

10. **Linear** — under 3-arg Thermometer, identical to Thermometer. Accept.

**Categorical verdict on REJECTED ten:** all rejections are defensible. Two (Resonance, ConditionalBind) reject a primitive the algebra LACKS (per-dim conditional). If a future application needs this, a proposal for a more primitive `Mask` or `Select` operation would be appropriate. Round 2 I flagged Select as a good primitive. Still missing. Not a blocker, but worth noting in the algebra-is-incomplete discussion.

### Issue R3-8: Ngram's empty-window edge case

Under the reframe `Ngram(n, xs) = Bundle (map Sequential (window n xs))`. For `n = 0`: window returns... what? 058-013 says "n=0 is an error." OK.

For `n > length(xs)`: window returns `[]`, Bundle([]) = zero vector. OK, and consistent.

For `n = 1`: windows of size 1 each contain one item; Sequential([a]) = a; `Bundle([a, b, c, ...])` = just the Bundle. So `Ngram(1, xs) = Bundle(xs)`. Fine, reasonable.

For `n = length(xs)`: one window = the whole list; `Bundle([Sequential(xs)])` = `Sequential(xs)` (Bundle of one is identity). OK.

### Issue R3-9: Bind-chain Sequential non-associativity

Sequential itself has this property already (Round 2 FAIL-4):

```
Sequential([Sequential([a,b]), c]) = Bind(Bind(a, Permute(b,1)), Permute(c,1))
Sequential([a, b, c]) = Bind(Bind(a, Permute(b,1)), Permute(c,2))
```

The second element of the outer call gets `Permute(_, 1)`. So nesting DIFFERENT. This is correct — Sequential is a positional encoder; nested sequences get different positions. This is NOT a failure; it's the intended semantics. Round-2 flagged as a LAW to state explicitly. Still worth stating.

### Issue R3-10: FOUNDATION inventory line counts

Line 1797-1798:
```
Stdlib           Sequential, Ngram, Bigram, Trigram,
                 Amplify, Subtract, HashMap, Vec, HashSet, Sequential, Ngram, Bigram, Trigram,
```

Sequential, Ngram, Bigram, Trigram appear TWICE in the stdlib enumeration. Copy-paste drift. Minor.

### Issue R3-11: Programs-ARE-Atoms substrate — what happens with Atom<Atom<T>>?

Iterating: `Atom(Atom(x))` where `x: T`, inner atom `a = Atom(x) : Atom<T>`, outer `A = Atom(a) : Atom<Atom<T>>`.

Hash of outer: `hash(type_tag(Atom<T>), edn(a))` = `hash(type_tag(Atom<T>), edn(Atom(x)))`. The EDN of `Atom(x)` is the serialization of the AST node `(Atom x)` plus the inner x's EDN. So it's `edn = "(Atom " + edn(x) + ")"`.

Hash: `H(tag_Atom<T>, "(Atom " + edn(x) + ")")`. This is distinct from `hash(type_tag(T), edn(x))` = inner atom's hash. So atom-of-atom has distinct identity from its inner atom. Good — idempotence would be wrong here; each wrap adds a layer of identity.

But wait — is this the RIGHT behavior? A "name of a name" IS a different thing from the original name. `Atom("foo")` is the atom "foo". `Atom(Atom("foo"))` is a new opaque identity for the AST "(Atom foo)". These should be different. Check.

`atom-value(Atom(Atom(x))) = Atom(x)`, which is a Holon. `atom-value(Atom(x)) = x`. The wrap/unwrap is inverse at each layer. Good.

**Categorical judgment:** parametric Atom behaves correctly under self-composition. Each wrap is a fresh identity; each unwrap recovers the interior. This IS a proper functor (the unit of a monad over Serializable, modulo details about what a "monad" means here).

Actually — is Atom a monad? `unit : T → Atom<T>` exists (wrap). `bind / flatten : Atom<Atom<T>> → Atom<T>` would flatten. Does the algebra support this?

Looking at extraction: `atom-value : Atom<T> → T`. If T = Atom<U>, then `atom-value : Atom<Atom<U>> → Atom<U>`. That's a JOIN / flatten at the type level. Is it available in the algebra? Yes — `atom-value` is polymorphic. So we have:

- unit: T → Atom<T> (i.e., (Atom x))
- join: Atom<Atom<T>> → Atom<T> (i.e., (atom-value a) where a : Atom<Atom<T>>)

These satisfy the monad laws if:
- `join(unit(a)) = a` — i.e., `atom-value(Atom(a)) = a`. Yes.
- `join(Atom(unit(a))) = a` — i.e., `atom-value(Atom(Atom(a))) = Atom(a)` ≠ a. Hmm.

Wait: `Atom(unit(a)) = Atom(Atom(a))`, then `join = atom-value`, yielding `Atom(a)`. Not `a`. So the second monad law fails.

Actually I was confused. The monad laws are:
- `join ∘ unit = id` (left unit)
- `join ∘ T(unit) = id` (right unit)
- `join ∘ join = join ∘ T(join)` (associativity)

Where T is the functor. For Atom<_>:
- `join(unit(x)) = atom-value(Atom(x)) = x`. ✓
- `join(Atom-map(unit, x))` — Atom-map is the functor action on morphisms. For Atom, does `Atom-map(f) : Atom<T> → Atom<U>` exist as `map f over an atom`? It would need to re-hash the inner value through f. That's not a ring-0 operation; it's a synthesize operation: extract, apply, re-wrap. `(Atom (f (atom-value a)))`. Is this even a morphism-of-atoms? Yes, it's well-defined. So `Atom-map(f, a) = Atom(f(atom-value(a)))`. Monad right law: `join(Atom-map(unit, a)) = join(Atom(unit(atom-value(a)))) = join(Atom(Atom(atom-value(a)))) = Atom(atom-value(a))`... this is `a` only if we're saying `Atom(atom-value(a)) = a`. And indeed by the atom's determinism (same inner → same hash), `Atom(atom-value(a)) = a` exactly. ✓

OK. So Atom is a monad. The programs-are-atoms substrate gives us a proper monad. Nice. This is a good categorical fact that supports the substrate.

**Verdict:** parametric Atom is a MONAD over Serializable. Unit = wrap, join = unwrap. Laws hold. Programs-as-atoms is categorically well-grounded.

### Issue R3-12: `atom-value` type inference

058-001 says: "polymorphic function; type-checker infers T at each call site." With rank-1 HM this requires the call site to fix T via context. If context is ambiguous, type inference fails.

Example: `(let ((x (atom-value a))) ...)`. If `a : Atom<Holon>` and the let binding has no usage of x yet, can T be inferred? Only from downstream use. If x is then passed to `Bind` which expects `:Holon`, unification fixes T = Holon.

Rank-1 HM is known tractable (polynomial in program size). 058-030 commits to rank-1 HM (not higher-ranked). OK.

**Concern:** 058-032 adds parametric macros. A macro whose return type depends on argument types requires the type variable to be carried through macro expansion. This is a bit delicate because macro expansion happens BEFORE type checking. If the macro produces an AST that needs to be type-checked post-expansion, and the macro's return type is declared `:AST<T>` with T a variable, does the type-checker see the full expanded form with T bound?

I think yes — the macro is `defmacro (id (x :AST<T>) -> :AST<T>) body`, so T is a parameter at the macro's definition site. At each call site, T is determined by the argument's type. The expansion uses T to build the output AST. Post-expansion, the resulting AST has concrete types where T was.

This is Racket/Scheme macros with types — an active research area but well-understood. Rank-1 is fine.

**Verdict:** parametric polymorphism commits to a well-understood subset. No red flags.

## Composition check — does the algebra compose?

Let me walk through the six core forms and their composition properties.

### Core (6 forms): Atom, Bind, Bundle, Permute, Thermometer, Blend

**Atom:** `:T → :Holon`. Constant — takes a literal, produces a holon. Composition: `Atom(Atom(x)) : Atom<Atom<T>>`. Parametric. Monadic.

**Bind:** `:Holon × :Holon → :Holon`. Bilinear on vectors (elementwise product). Commutative, self-inverse on dense-bipolar, measurement-based on general.
- `Bind(a, b) = Bind(b, a)` ✓ commutative
- `Bind(a, Atom(ONE)) = a` if ONE is the all-+1 atom (but no reserved such atom)
- `Bind(Bind(a, b), b) ≈ a` under similarity ✓
- `Bind(Bind(a, b), c) = Bind(a, Bind(b, c))` associative ✓ (elementwise product is associative exactly)

**Bundle:** `:List<:Holon> → :Holon`. Elementwise sum + ternary threshold.
- Commutative ✓ (sum commutes, threshold preserves)
- NOT elementwise associative; similarity-associative within capacity ✓ (FOUNDATION is honest)
- Bundle([]) = zero vector (identity) ✓
- Bundle([x]) = x (if threshold(x) = x, which is true for ternary x)

**Permute:** `:Holon × :Integer → :Holon`. Z/dZ group action on dimensions.
- `Permute(v, 0) = v` ✓ identity
- `Permute(Permute(v, j), k) = Permute(v, j+k mod d)` ✓ group
- `Permute(Bind(a, b), k) = Bind(Permute(a, k), Permute(b, k))` ✓ distributes over Bind elementwise (because Permute commutes with elementwise product under same permutation)
- `Permute(Bundle(xs), k) = Bundle([Permute(x, k) for x])` ✓ linear over Bundle sum

Composition of Permute with everything = clean.

**Thermometer:** `:f64 × :f64 × :f64 → :Holon`. Pure scalar encoder. No composition rules beyond determinism. Dense-bipolar output.
- `Thermometer(v, mn, mx)` same for same inputs ✓ deterministic
- Composition: output is a Holon that goes into Bind, Bundle, Blend, Permute. No internal composition structure (Thermometer doesn't take Holons).

**Blend:** `:Holon × :Holon × :f64 × :f64 → :Holon`. Weighted sum + ternary threshold.
- `Blend(a, b, w1, w2) = Blend(b, a, w2, w1)` ✓ swap-weighted symmetry
- `Blend(a, b, w1, w2) ≠ Blend(b, a, w1, w2)` in general ✓ non-commutative in args alone
- `Blend(a, b, 1, 1) = Bundle([a, b])` ✓ specialization
- `Blend(a, b, 1, 0) = a` (if threshold preserves) ✓
- Associative? `Blend(Blend(a, b, w1, w2), c, w3, w4)` — this is `threshold(w3·threshold(w1·a + w2·b) + w4·c)`. The double threshold loses information. NOT associative. Same capacity framing as Bundle. OK, honest about non-associativity under similarity.

### Compositions across operations

**Bundle(list of Binds):** `Bundle([Bind(role_1, filler_1), Bind(role_2, filler_2), ...])` is role-filler encoding. Canonical. Composes cleanly.

**Unbind via Bind:** `Bind(Bundle_of_roles_fillers, role_i)` ≈ filler_i under capacity. Measurement-based. Classical VSA.

**Sequential bind-chain:** as discussed, non-associative in a semantic sense (positional encoder). OK.

**Reject(Reject(x, y), z)** — Gram-Schmidt iteration. Each step removes a direction. Correct composition for subspace removal. Standard.

**Project + Reject = x?** Under similarity yes; elementwise the equation is `Subtract(x, Reject(x, y)) + Reject(x, y) = x`. Let's verify: `Project(x, y) + Reject(x, y) = (x - Reject(x, y)) + Reject(x, y) = x`. Elementwise exact BEFORE any thresholding. After thresholding: approximate.

Except Project expands to `Subtract(x, Reject(x, y))` which is `Blend(x, Reject(x, y), 1, -1)` — this itself thresholds. So `Project(x, y)` is `threshold(x - threshold(x - coeff·y))`. Nested thresholds mean the identity `Project + Reject = x` only holds up to similarity, not elementwise. Same capacity framing.

Under FOUNDATION's similarity-measurement frame: acceptable.

## Summary of categorical holds / fails

### Holds categorically:
- Parametric Atom as substrate (monad over Serializable)
- Bind as self-inverse under similarity (measurement-based)
- Permute as Z/dZ group action (exact)
- Bundle as commutative (exact)
- Bundle as associative UNDER SIMILARITY (capacity-bounded)
- Measurement tier orthogonal to vector-producing tier
- REJECTED ten — all defensible
- Sequential bind-chain as positional encoder (new compound semantics, clean)

### Holds with caveats:
- Reject post-threshold "orthogonal up to capacity" — vague bound
- Blend non-associativity — same capacity framing as Bundle, should be explicit

### Fails or inconsistent:
- **FOUNDATION's Sequential expansion at line 2405 is wrong** — shows old bundle-sum, not bind-chain. Mechanical bug.
- **FOUNDATION line 2956** inventory also wrong.
- **Laws section still missing.** Many laws are stated in prose but not collected. Round-2 recommended a Laws appendix; still not done.
- **Reserved atoms (zero, one) not adopted.** Round-1 and Round-2 both recommended `:wat/algebra/zero` for Bundle identity; still not.

## Summary of composition and laws ledger

Will finalize in REVIEW.md.

## Checking HYPOTHETICAL for old-syntax issue (NEW-3)
