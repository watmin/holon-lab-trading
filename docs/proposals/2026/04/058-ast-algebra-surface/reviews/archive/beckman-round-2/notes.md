# Beckman Round-2 Scratch — equational reasoning

## Summary of the round-2 changes

Claim (per README): the five round-1 findings are resolved via:

1. **Bundle non-associativity** → ternary threshold with `threshold(0) = 0`
2. **Orthogonalize post-threshold orthogonality** → same ternary rule (X=Y produces all-zero)
3. **Bind self-inverse on ternary** → reframed as capacity budget
4. **Alias hash-collision** → `defmacro` expansion at parse time
5. **Variance silence** → 058-030 now states covariance for `:List`, contra-in/co-out for `:Function`

Let me check each rigorously.

---

## #1 — Does `threshold(0) = 0` actually make Bundle associative?

### The claim (FOUNDATION lines 1318–1325)

> For `x = +1, y = -1, z = -1`:
>   `Bundle([x,y,z]) = threshold(-1) = -1`
>   `Bundle([Bundle([x,y]), z]) = Bundle([threshold(0), -1]) = Bundle([0, -1]) = threshold(-1) = -1`

### Let me check several cases for d=1, threshold(0) = 0:

**Case A: `x = +1, y = -1, z = -1`**
- `Bundle([x,y,z]) = threshold(-1) = -1` ✓
- `Bundle([Bundle([x,y]), z]) = Bundle([0, -1]) = threshold(-1) = -1` ✓
  Match.

**Case B: `x = +1, y = -1, z = +1`**
- `Bundle([x,y,z]) = threshold(+1) = +1`
- `Bundle([Bundle([x,y]), z]) = Bundle([0, +1]) = threshold(+1) = +1` ✓
  Match.

**Case C: `x = +1, y = -1, z = 0` (ternary)**
- `Bundle([x,y,z]) = threshold(0) = 0`
- `Bundle([Bundle([x,y]), z]) = Bundle([0, 0]) = threshold(0) = 0` ✓
  Match.

**Case D: `x = +1, y = +1, z = -1`**
- `Bundle([x,y,z]) = threshold(+1) = +1`
- `Bundle([Bundle([x,y]), z]) = Bundle([threshold(+2), -1]) = Bundle([+1, -1]) = threshold(0) = 0`
  **MISMATCH. +1 ≠ 0.**

So Bundle is **STILL NOT ASSOCIATIVE** under ternary thresholding. The fix resolved ONE case (round-1's counter-example) but NOT the general problem.

The issue: thresholding discards magnitude. `Bundle([+1,+1]) = +1` (after threshold), so when re-bundled with `-1`, the inner `+1`'s magnitude of `+2` is lost. The outer bundle becomes `threshold(+1 - 1) = threshold(0) = 0`, but the full-sum route gives `threshold(+1) = +1`.

**Ternary thresholding only solves the `threshold(0)` ambiguity at the MIDDLE step. It does NOT restore associativity for cases where magnitude greater than 1 is lost at an intermediate threshold.**

Let me construct a clean counter-example at d=1:
- `x = +1, y = +1, z = -1`
- `Bundle([x,y,z]) = threshold(1+1-1) = threshold(1) = +1`
- `Bundle([Bundle([x,y]), z]) = Bundle([threshold(2), -1]) = Bundle([+1, -1]) = threshold(0) = 0`
- `Bundle([x, Bundle([y,z])]) = Bundle([+1, threshold(0)]) = Bundle([+1, 0]) = threshold(1) = +1`

**Three different results** depending on association: `+1, 0, +1`. Bundle is NOT associative.

The FOUNDATION's counter-example was carefully chosen (`+1, -1, -1`) where all intermediate threshold results happen to agree. But with any mix that produces an intermediate sum of magnitude ≥ 2, the threshold lossiness breaks associativity.

**Verdict on #1: UNRESOLVED. Ternary threshold fixes the particular round-1 example but does NOT make Bundle associative in general. The FOUNDATION's claim of associativity (line 1318) is false.**

The Capacity-as-budget reframing (FOUNDATION §"Capacity is the universal measurement budget") might be the more honest framing: Bundle is similarity-measured, not elementwise-exact; non-associativity is capacity consumption under Kanerva's bound. But then the FOUNDATION's specific claim "Bundle is associative" should be dropped, not asserted.

---

## #2 — Does ternary make Orthogonalize's orthogonality exact?

### The claim (058-005 line 27–29)

> `X - projY(X)` produces zero at a dimension, `threshold(0) = 0` preserves that zero, so the result contributes nothing at those positions. `result · Y = 0` exactly, not "up to threshold noise."

### The degenerate case X = Y

For `X = Y = [+1,+1,+1,+1]`: projection coeff = 1, `X - Y = [0,0,0,0]`, threshold → `[0,0,0,0]`. Dot with Y = 0. ✓ **This case is fixed.**

### What about other near-degenerate cases?

Let me try `d=4`, `X = [+1,+1,+1,-1]`, `Y = [+1,+1,+1,+1]`.
- `X·Y = 1+1+1-1 = 2`
- `Y·Y = 4`
- coeff = 2/4 = 0.5
- `X - 0.5·Y = [+1-0.5, +1-0.5, +1-0.5, -1-0.5] = [+0.5, +0.5, +0.5, -1.5]`
- `threshold = [+1, +1, +1, -1]`
- `result · Y = +1 + +1 + +1 + -1 = 2`. **NOT ZERO.**

So the real-valued `X - projY(X)` is exactly orthogonal to Y (has dot product 0):
- Check: `[+0.5, +0.5, +0.5, -1.5] · [+1,+1,+1,+1] = 0.5+0.5+0.5-1.5 = 0` ✓

But after ternary threshold, the dot product is 2, not 0. **Post-threshold orthogonality fails.**

The FOUNDATION's fix (ternary threshold) only handles the case where ALL components of `X - projY(X)` are exactly zero (i.e., `X = Y` up to sign). In general, the projection-subtracted real vector has fractional entries that threshold to ±1, and the ternary thresholding doesn't preserve orthogonality.

**Counter-example for post-threshold orthogonality claim:** any X that has non-zero non-integer projection-subtracted components.

**Verdict on #2: RESOLVED-WITH-CAVEAT for the specific edge case `X = Y` only. UNRESOLVED for the general post-threshold orthogonality claim.**

058-005 line 27: "result · Y = 0 exactly, not 'up to threshold noise'" — this claim is FALSE for the general case. It holds only at the `X = Y` edge case.

The proposal needs to be restated: orthogonality is EXACT pre-threshold; POST-threshold, orthogonality is approximate (O(d^{-1/2}) noise) EXCEPT in the degenerate case X = Y.

---

## #3 — Capacity-budget reframing of Bind's self-inverse weakening

### The reframing (FOUNDATION §"Capacity is the universal measurement budget")

> Bind's self-inverse property is elementwise exact at dense operands and capacity-consuming at sparse operands — not a "weakening," just consumption from the budget.

### Is this mathematically sound?

Let's check:
- `Bind(Bind(a, b), b)[i] = a[i] · b[i]²`
- For `b[i] ∈ {-1, +1}`: `b[i]² = 1` → recovery of `a[i]` exactly ✓
- For `b[i] = 0`: `b[i]² = 0` → output is 0 at position i, not `a[i]`

At sparse `b` (fraction `p` non-zero), the recovered vector has `a[i]` at `p·d` positions and `0` at `(1-p)·d` positions. The cosine similarity between recovered and `a` is:

  `cos = (recovered · a) / (|recovered| · |a|) = (p·d) / (√(p·d) · √d) = √p`

So sparse Bind decode degrades cosine similarity proportionally to `√p`. Above 5σ noise threshold (conventionally, the recovery works if `cos > 5/√d`), we need `√p > 5/√d`, i.e., `p > 25/d`.

At d=10,000 and a sparsity of e.g. `p = 0.01` (1% non-zero): `cos = 0.1`, noise floor is `5/100 = 0.05`. Similarity survives, just barely.

**The reframing IS mathematically sound.** Sparse-key decode IS a form of capacity consumption — it effectively decodes at a reduced-dimensional subspace.

BUT: the claim that this is "the same phenomenon as Bundle crosstalk" is an *analogy*, not an equality. Kanerva's bound `d / (2·ln(K))` is for Bundle capacity. Sparse-key decode has its own noise formula `√p`. They are both similarity-measured phenomena, but they are DIFFERENT functions of the substrate parameters.

### Does this weaken any guarantee?

**Yes — it weakens the guarantee that was claimed in round 1.** In round 1, Bind was claimed to be self-inverse unconditionally: `Bind(Bind(a,b), b) = a`. Round 2 restates this as "self-inverse on non-zero positions of b" with "capacity consumption" at zero positions. The guarantee shifted from "elementwise equality" to "similarity above noise threshold."

This is a genuine restatement. The algebra is now explicitly similarity-measured, not elementwise-exact. That is the honest framing — but it must be STATED as such. Old code that assumed elementwise equality no longer has that guarantee.

**Verdict on #3: RESOLVED-WITH-CAVEAT.** The reframing is mathematically sound. But it IS a semantic change: from elementwise-exact to similarity-measured recovery. Users relying on the old elementwise guarantee need to know this. The FOUNDATION does state this explicitly (which is good).

However, the framing "not a weakening, just capacity consumption" is partly rhetorical. It IS a weakening of the literal elementwise guarantee; it's just that the ALGEBRA is now reframed to not have made that guarantee.

---

## #4 — Does `defmacro` actually resolve the alias hash-collision?

### The claim (058-031 + FOUNDATION startup pipeline)

1. Macros register at parse time.
2. Expansion pass walks the AST until fixpoint, rewriting macro calls to canonical forms.
3. Hashing happens AFTER expansion.

Under this pipeline, `hash((Concurrent xs)) = hash((Set xs)) = hash((Bundle xs))` because all three expand to the same canonical `(Bundle xs)` AST.

### Does it actually work?

**Yes, mechanically.** The parse-time expansion pass IS the right solution. It is the well-known Lisp solution to source-level aliases with canonical semantics.

### Edge cases to check:

**Case 1 — argument evaluation order.** Are macro arguments passed as ASTs (unevaluated) or as evaluated values?
058-031 line 60 specifies: **arguments are passed as ASTs (unevaluated).** This is correct for a classical Lisp macro. Good.

**Case 2 — nested macros.** `Chain` uses `Then` which uses `Bundle` and `Permute`. Does the expansion fully resolve?
058-031 line 71 specifies: expansion continues until fixpoint. Good.

**Case 3 — macros with parameterized expansion.** `Amplify(x, y, s)` → `Blend(x, y, 1, s)`. If `s = 1`, the expansion becomes `Blend(x, y, 1, 1)` which has the same VECTOR as `Bundle([x, y])` but a DIFFERENT AST hash. Is this a collision?

Actually no — this is intended. `Amplify(x, y, 1)` (source) expands to `Blend(x, y, 1, 1)` (canonical AST). `Bundle([x, y])` expands to `Bundle([x, y])` (different canonical AST). **They produce the same VECTOR but have different ASTs.**

Wait — is that a collision that matters? FOUNDATION claims `hash(AST) IS the thought's identity.` If two ASTs produce the same vector but have different hashes, they are DIFFERENT THOUGHTS. That's the position. But it contradicts the round-1 complaint: if `Concurrent` and `Bundle` both denote "superposition of xs," should they not ALSO be the same thought?

The macro expansion makes this consistent: two source aliases for THE SAME canonical AST shape share identity. Two source forms that expand to DIFFERENT canonical shapes (Blend(_,_,1,1) vs Bundle([_,_])) are DIFFERENT thoughts, even if their vectors coincide.

This is the right semantics. Identity = AST shape after expansion; vectors can coincide without thoughts being identical (just as in music, different notes can sound similar).

**Case 4 — macros with captured variables (hygiene).** 058-031 line 234: "start with unhygienic macros." This means user-defined macros can accidentally capture variable names from the caller's scope. This is a known Lisp tradition but can be a bug source.

The stdlib macros are well-controlled (they only use gensym-free, scope-clean expansions). For user-defined macros, hygiene is a future concern. Not a blocker.

**Case 5 — macro application with wrong arity.** What if someone writes `(Subtract x y z)` when Subtract expects 2 args?
058-031 Q3: typed macro parameters (every arg `: AST`, return `-> :AST`). Type-checking catches arity mismatch at startup. Good.

**Case 6 — alias of alias.** `Set → Bundle`, `Array → Sequential → Bundle-of-Permutes`. Multi-level expansion should reach fixpoint. Per the pipeline, yes. Good.

**Case 7 — what about `Difference` vs `Subtract`?** Both expand to `Blend(a,b,1,-1)`. Per README, `Difference` is REJECTED, `Subtract` is canonical. So no collision at the macro level — there's only one macro. ✓

### A genuine concern: the defmacro body type

The macro body is specified as typed `:AST → :AST`. But the macro body is itself Lisp code that runs at parse time. Can the body call macros of its own? Can it introspect?

058-031 Q4: `macroexpand` is an introspection tool. So yes, macros can be introspected. But can a macro's body call OTHER macros at expansion time? This is the Racket-style "phase separation" question. Not explicitly resolved in 058-031.

**Verdict on #4: RESOLVED (for the specific collision concern). The defmacro solution is categorically correct and is the standard Lisp answer.** Minor concerns about hygiene and phase separation remain as future questions, but the round-1 finding is resolved.

---

## #5 — Variance rules

### The claim (058-030 lines 162–188)

- `(:List :T)` is covariant in T.
- `(:Function args... -> return)` is contravariant in args, covariant in return.
- No implicit subtyping between Rust primitives.

### Check: Liskov substitutability

**List covariance check:**
If `:A :is-a :B` and xs : `(:List :A)`, does `(map f xs)` typecheck where `f : :B → :U`?
- Under covariance: `(:List :A) :is-a (:List :B)`, so xs is usable as `(:List :B)`. Map's signature: `(:Function :B → :U) × (:List :B) → (:List :U)`. Matches. ✓

Is this *safe*? Covariance is safe for read-only lists. If the list is mutable (in-place update), covariance is UNSAFE (Java's covariant arrays have this bug). The wat algebra's "algebra is immutable" principle (FOUNDATION) resolves this — lists are values; mutation doesn't happen. So covariance is sound. ✓

**Function contravariant-in:**
If `:A :is-a :B`, is `(:Function :B → :U) :is-a (:Function :A → :U)`?
- The contravariant rule says YES: a function that accepts `:B` (more general) can be substituted where a function accepting `:A` (more specific) is expected.
- Intuition: you're calling the function with an `:A` value, which is already a `:B`, so the `:B`-accepting function can handle it. ✓

**Function covariant-out:**
If `:C :is-a :D`, is `(:Function :T → :C) :is-a (:Function :T → :D)`?
- Covariant: YES. A function returning `:C` (more specific) can be substituted where a function returning `:D` (more general) is expected — the caller just gets a more specific type than expected. ✓

Both rules are STANDARD Liskov.

### Edge cases:

**Case 1: Type parameters appear in BOTH positions.** `(:Function :T → :T)` where T is a type variable. Is this invariant?
The proposal doesn't address type-parameter variance in user-defined parametric types. Only built-ins are specified. So `(:Function :Thought → :Thought)` is handled by the built-in rule. But a user type `(:MyContainer :T)` — what's its variance? Not specified.

058-030 says "User parametric types (future; not in scope for 058)". So user types have no variance rules. This means user-defined generic types are effectively invariant (the safest default). Not a bug, but a limit.

**Case 2: Rust primitive strictness.** `:i32` is not a subtype of `:i64`. So a function taking `:i64` won't accept an `:i32` — explicit conversion required. This matches Rust's semantics. Rust also has no variance for primitives; there's no subtyping to variance over. ✓

**Case 3: Thought subtype hierarchy.** `:Atom :is-a :Thought`, `:Bundle :is-a :Thought`, etc. This creates a flat hierarchy under `:Thought`. What about variance of operations that take `:Thought`?
- `(:Function :Thought → :Thought)` accepts any ThoughtAST variant as input (because they all `:is-a :Thought`). That's OK — the function treats them all as `:Thought`.
- Can a function of type `(:Function :Bundle → :Bundle)` be substituted for `(:Function :Thought → :Thought)`?
  - Input: contravariant. Need: `:Thought :is-a :Bundle`? NO — :Bundle is MORE SPECIFIC than :Thought. So NO, the contravariance fails.
  - Output: covariant. Need: `:Bundle :is-a :Thought`? YES. OK.
  - So `(:Function :Bundle → :Bundle)` is NOT substitutable where `(:Function :Thought → :Thought)` is expected. Correct — Liskov is unhappy.

**Verdict on #5: RESOLVED for the built-in parametric types. Covariance of List and the contra-in/co-out of Function are standard Liskov. No issues I can find.**

The open question: user-defined parametric types have no variance rules. This is fine (default invariance is safe), but vocab authors writing generic containers will need variance in the future. Not a blocker.

---

## Additional Issues I Noticed

### A. Thermometer signature contradiction

**FOUNDATION line 1775:** `(Thermometer value min max)` — 3 args: value, min, max.

**058-023 line 13:** `(Thermometer atom dim)` — 2 args: atom, dim.

**058-008 line 35:** `(Thermometer ,low-atom dim)` — 2 args: atom, dim.

**HYPOTHETICAL-CANDLE-DESCRIBERS.wat line 44:** `(Thermometer 0 0 1)` — 3 args: value, min, max.

**This is a contradiction within the batch.** Either Thermometer takes (atom, dim) and Linear internally supplies the anchors, OR Thermometer takes (value, min, max) and internally determines the anchors and position.

Looking at 058-023's semantics:
> `Thermometer(atom, d)[i] = +1 if i < (d * t(atom))`, else `-1`
> "Where `t(atom)` is some atom-dependent position in `[0, 1]`"

And FOUNDATION's Thermometer use via Linear:
> `(define (Linear v scale) (Thermometer v 0 scale))` (FOUNDATION 1816)

These are two different primitives with the same name. The FOUNDATION defines `Thermometer(value, min, max)` as a scalar-value encoder; 058-023 defines `Thermometer(atom, dim)` as an anchor vector seeded by an atom.

**This is a substantive contradiction that needs to be resolved.** Under FOUNDATION's version, Linear is `Thermometer(value, min, max)` and Thermometer itself does the scalar encoding (and thus is the whole scalar primitive). Under 058-023's version, Thermometer is an anchor (seeded by atom), and Blend-over-anchors does the scalar interpolation (with Linear computing the weights).

The 058-023/008 version is the more categorically honest one: Thermometer is the anchor primitive; Blend is the combiner; Linear is the weight-computing stdlib. The FOUNDATION's 3-arg version conflates the anchor with the weight computation.

**Recommendation:** unify on 058-023's `(Thermometer atom dim)` signature. Update FOUNDATION and the HYPOTHETICAL example. Otherwise the algebra has TWO Thermometer primitives and the 058-023 affirmation is aspirational not actual.

### B. `->` syntax inconsistency in HYPOTHETICAL

Per 058-030 and 058-028, the new syntax is:
```
(define (name [arg : Type] -> :ReturnType) body)
```

But HYPOTHETICAL-CANDLE-DESCRIBERS.wat uses the OLD syntax:
```scheme
(define (:demo/desc/doji [c : :demo/market/Candle]) : Thought   ; line 38
```

The `: Thought` is OUTSIDE the signature parens. This is the round-1 syntax. The example wasn't updated to use `-> :Thought` inside parens.

This is a documentation bug — the example file needs to be updated to the current syntax. Not an algebraic problem, but an inconsistency that a reviewer should flag.

### C. ConditionalBind vs Select — still unresolved

Round-1 review recommended: propose `Select(x, y, gate)` as the primitive and let `ConditionalBind(a, b, gate) = Select(Bind(a, b), a, gate)` be stdlib. This is a cleaner factoring — Select is more primitive.

Round-2 hasn't acted on this. ConditionalBind is still core. Since 058-031 introduces macros, `ConditionalBind` could be EASILY expressed as a macro over `Select + Bind` if Select is core. The fact that Select is not proposed means ConditionalBind remains a narrower primitive than it could be.

**Not a blocker, but a missed refactoring opportunity.** Round-1's UNCONVINCED verdict on ConditionalBind stands — but the case has not gotten worse, just not better.

### D. Resonance STILL lacks a dual in stdlib

Round-1 recommended `Dissonance(v, ref) = Blend(v, Resonance(v, ref), 1, -1)` as a stdlib dual.

Round-2 has defmacro now — Dissonance could be trivially added as a macro. But it isn't. This is a missed opportunity for categorical duality.

### E. The `Blend` identity

Round-1 flagged: "Bundle's identity is the zero vector, but zero is not in `{-1, +1}^d`."

Under the new ternary output space `{-1, 0, +1}^d`, the zero vector IS in the space. So `Bundle([zero, x]) = x` (exact). Bundle now has an identity element: the all-zero vector.

**This is a genuine win.** The ternary output space restores the monoid structure (commutative + identity) for Bundle. Even though associativity still fails (see #1 above), identity is resolved.

But there's still no explicit way to NAME the zero vector in the source language. `Atom(:wat/algebra/zero)` is not a reserved atom with the all-zero vector; it's just an atom with some hash-seeded non-zero vector.

To actually use Bundle's identity, you'd need either:
- A reserved atom for the zero vector
- A `(zero-vector)` primitive that produces all-zeros

Neither exists. So the identity is theoretically accessible but not practically writable. Round-1's §8.1 suggestion (distinguished `:wat/algebra/zero` atom) still stands.

### F. Project as dual of Orthogonalize — still stdlib only, still not named

Round-1 §8.2 recommended `Project(x, y) = Blend(x, Orthogonalize(x, y), 1, -1)` as an explicit stdlib form. With defmacro available, this is a one-line macro:

```scheme
(defmacro Project [x : AST] [y : AST] -> :AST
  `(Blend ,x (Orthogonalize ,x ,y) 1 -1))
```

Not proposed. Gram-Schmidt pair remains asymmetric.

### G. Empty-case semantics (`Bundle([])`, `Sequential([])`, etc.)

Round-1 §7 flagged: what is the identity/empty case?

FOUNDATION now says that the algebra's output is ternary and includes zero. `Bundle([])` = zero vector (the empty sum, identity).

This is ACTUALLY RESOLVED by the ternary output space. The zero vector IS in the algebra's object space now. `Bundle([])` = `[0,0,...,0]`. No more UB.

But it's still not STATED as a law anywhere. The law "`Bundle([]) = 0⃗`" should be explicit.

### H. Sequential NOT associative (under itself)

Round-1 §2.5 flagged: `Sequential([Sequential([a,b]), c]) ≠ Sequential([a,b,c])`.

This is STILL TRUE under ternary. Sequential uses Permute indices — nesting produces different positional encodings, which are literally different vectors.

Round-2 doesn't address this. Not a regression; still stands. Sequential is a REINDEXING, not a reduction. Should be stated as a law.

---

## Summary of equational findings

| Finding | Claim | Round-2 resolution | My verdict |
|---|---|---|---|
| #1 Bundle associativity | ternary fixes it | NO — fails for (+1,+1,-1) case | UNRESOLVED |
| #2 Orthogonalize post-threshold | ternary fixes it | ONLY for X=Y edge case | RESOLVED-WITH-CAVEAT |
| #3 Bind self-inverse on ternary | capacity-budget reframing | mathematically sound reframing | RESOLVED |
| #4 Alias hash-collision | defmacro parse-time expansion | correct, standard Lisp | RESOLVED |
| #5 Variance silence | covariance for :List, contra-in/co-out for :Function | standard Liskov, correct | RESOLVED |

New issues:
- A. Thermometer signature contradiction (3-arg FOUNDATION vs 2-arg 058-023) — NEW ISSUE
- B. `->` syntax not applied in HYPOTHETICAL example — doc bug
- C. Select vs ConditionalBind — still unresolved (round-1 concern)
- D. Dissonance — still missing (round-1 concern)
- E. Bundle identity writable? — not yet (round-1 §8.1)
- F. Project still missing (round-1 §8.2)
- G. Empty-case now well-defined but not stated as law
- H. Sequential self-non-associativity still unstated

---

## The reframing issue — is the "capacity budget" actually honest?

FOUNDATION's new framing: all decode noise is "capacity consumption" under Kanerva's bound.

This is elegant but it bundles three distinct phenomena:
1. Bundle crosstalk: superposition of K items, each decode has noise ~ 1/√(K)
2. Sparse-key decode: Bind with sparse b has recovery cosine ~ √p where p is density
3. Bundle non-associativity: magnitude-loss at intermediate thresholds

These are DIFFERENT functions of substrate parameters. Claiming they are "the same phenomenon" is a rhetorical simplification. The MATHEMATICS disagrees — they have different formulas.

But the reframing works OPERATIONALLY: all of them are similarity-measured, all of them degrade gracefully, all of them are bounded by Kanerva-style capacity. For practical high-d (d ≥ 10000), the noise in each case is well within working headroom.

**The reframing is pragmatically sound but mathematically imprecise.** It is reasonable for a user-facing document. But the equations for each phenomenon should be separately stated in the laws table.

---

## What I would recommend adding

1. **Correct the Thermometer signature contradiction.** Pick (atom, dim); update FOUNDATION and HYPOTHETICAL.

2. **Correct the Bundle associativity claim.** Either:
   (a) State that Bundle is NOT associative in general, but only for specific input distributions. Provide a concrete law: `Bundle(Bundle(xs), y) = Bundle(xs + [y])` IFF no intermediate threshold produces magnitude ≥ 2. OR
   (b) Drop the claim entirely; state that "Bundle's laws are similarity-measured; non-associativity is bounded within capacity budget."

3. **Correct Orthogonalize post-threshold claim.** State precisely: orthogonality is EXACT pre-threshold AND at the `X = Y` edge case. For general X ≠ Y, post-threshold orthogonality is approximate with noise bound.

4. **State variance of user parametric types.** Either declare them invariant (safe default) or require users to declare variance at `deftype` time.

5. **Add `Project`, `Dissonance`, `Select` as macros or primitives.** All three are categorical duals with trivial expansions under defmacro.

6. **Fix the HYPOTHETICAL example's `->` syntax.** Mechanical fix; keeps the example consistent with current spec.

7. **Add a LAWS TABLE in FOUNDATION.** Round-1 §7 listed 23 laws that should be explicit. Many still implicit.
