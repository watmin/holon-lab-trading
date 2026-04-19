# 058 — Consolidated Open Questions for Designers

**Purpose:** single-scan sheet of every designer-facing question across the 29 sub-proposals. Each question preserved verbatim with its source proposal noted. Audited primitives (Bind, Permute, Thermometer) have no open questions — see `CORE-AUDIT.md`. FOUNDATION's own Open Questions (Q1–Q7) and their resolutions live in `FOUNDATION.md` (`## Open Questions`).

**Generated from:** sub-proposals' "Questions for Designers" sections.

---

## 058-001: Atom — Typed Literals

1. **Is the typed hash categorically sound?** The hash input is `(type_tag, literal_bytes)`. Different types with identical bytes produce different vectors. Is this the right axis of distinction — type first, then value — or should it be inverted (value first, then type), or collapsed (bytes only, letting the user provide a type-prefixed string if they want distinction)?

2. **Should `Atom` remain one variant, or should typed atoms be distinct variants?** Option A: `Atom(AtomLiteral)` — one variant, internally tagged. Option B: `AtomStr(String)`, `AtomInt(i64)`, `AtomFloat(f64)`, etc. — separate variants. Option A is simpler and keeps the ThoughtAST enum small. Option B allows pattern-matching on literal type without destructuring the inner `AtomLiteral`. Which fits the algebra better?

3. **What about `Null` as an atom?** FOUNDATION's foundational principle says literals live on AST nodes. A null/none literal raises a question: is "no value" a first-class atom, or should it be represented structurally (absence of a Bind, or a specific absence marker)? Holon traditionally has no `nil` — absence is structural. Does allowing `(Atom null)` break this convention?

4. **Keyword naming conventions — no namespace mechanism.** The language does NOT have namespaces as a structural feature. Slashes in keyword names are just characters — `:wat/std/cos-basis` is a single keyword whose name is `wat/std/cos-basis`. FOUNDATION uses the `:wat/std/...` prefix as a stdlib naming discipline to avoid collision with user atoms. Is naming convention alone sufficient, or does the language need a more robust collision-avoidance mechanism? (The type-aware hash ensures `(Atom :foo)` and `(Atom "foo")` differ; same-type collision is the user's responsibility.)

5. **Backward compatibility.** Existing code uses `(Atom "string")` exclusively. The generalization is additive — all existing atoms remain valid. Is there any need to migrate existing string atoms to other types (e.g., atoms that represent integers-as-strings), or is the expectation that existing code continues to work unchanged while new code uses the right type?

6. **Type erasure on the vector side.** The vector is bipolar regardless of the literal's type. If someone has ONLY a vector (no AST), they cannot recover the literal's type from the vector — cleanup against a codebook returns a candidate AST node, from which the literal (with type) can be read. Is this the right model, or should the type be recoverable from the vector somehow (seems impossible with deterministic hashing)?

---

## 058-002: Blend

1. **Is scalar-weighted vector addition a distinct source category from unweighted bundling?** The argument: Bundle's weights are implicitly uniform (+1); Blend's weights are parametric. Bundle is a monoid operation; Blend is parameterized by scalar weights and is not commutative in the vector arguments (`Blend(a, b, w1, w2)` ≠ `Blend(b, a, w1, w2)` unless `w1 = w2`). Different categorical nature. Is this enough to earn core status?

2. **Option A (convex, single alpha) vs Option B (two independent weights)?** Option A is simpler and matches existing holon `blend`. Option A captures Linear but NOT Circular (trig weights aren't convex). Option B captures both plus more. Which is the right level of generality for a core form? Option A with Circular staying core? Option B with full unification?

3. **Should negative weights be allowed?** With Option B allowing negative weights, `Blend(x, y, 1, -1)` = Negate-subtract-mode. Does this blur the semantic distinction between "blend" and "subtract"? Or is it fine — the mathematics is consistent, and the stdlib names the specific use cases (Amplify, Subtract) for readability.

4. **Variadic temptation — where do we stop?** Once you have Blend(a, b, w1, w2), do you generalize to Blend(pairs) variadic? This would subsume Bundle (all weights +1) as a special case. Is that the right direction, or does it dissolve the MAP canonical set? I argue stay binary; variadic proposes separately if ever.

5. **Implementation impact on holon-rs.** Is ~20 lines of Rust (new `blend_weighted`, existing `blend` becomes a wrapper) an acceptable change? Any concern about cache key encoding for f64 weights?

6. **If rejected, what is the recommended path for Linear and Circular?** They remain core and duplicate the scalar-weighted-add logic. Is that acceptable? Is there a different way to consolidate them without introducing Blend?

---

## 058-003: Bundle — List Signature

1. **Is the list form the right ergonomic tradeoff?** List-taking composes cleanly with `map` and `filter`, but requires `(list ...)` for literal cases. Does this serve the common use case well, given that vocab modules almost always generate Bundle inputs via list-producing operations?

2. **Should the parser accept both forms as aliases?** Lenient parsing would accept `(Bundle a b c)` and internally wrap into `(Bundle (list a b c))`. Strict parsing would reject variadic form. Lenient is user-friendly; strict preserves the one-form-one-meaning principle.

3. **Does this constrain future extensibility?** If we ever wanted Bundle to take additional parameters (e.g., `(Bundle list options)` for hypothetical parameterization), would the list-taking form make that addition awkward? Probably not — options could be a map parameter, same pattern as `Ngram n list`.

4. **Other list-operating forms.** Sequential, Concurrent, Chain, Ngram, Array, Set, Map — do all of them follow the list-taking convention, and is this proposal implicitly locking the convention across all of them? FOUNDATION.md uses the list form throughout; this proposal formalizes it.

5. **Is this worth its own proposal?** The change is small (documentation + possible parser strictness). Could have been bundled into a broader "wat form conventions" proposal. Arguments for its own proposal: the ambiguity was visible enough to be worth a named decision; the designers should review the form convention explicitly rather than having it slide in with other changes.

---

## 058-004: Difference

1. **Should `Difference` and `Subtract` both exist?** Same math. Different reader intent. Case for both: serves readers scanning for different patterns. Case for one: avoid complection by redundancy. Which way does Hickey's simplicity principle lean here?

2. **If only one, which?** "Subtract" is imperative-ish. "Difference" is noun-ish. The stdlib of most Lisps would use `Subtract` for the operation and `Difference` for the result of applying it to observations. Under that convention, `Subtract` might be the primary name and `Difference` a documentation alias.

3. **Dependency on Blend's resolution.** This sub-proposal CANNOT resolve before 058-002-blend. If Blend is rejected, Difference must re-propose as a core variant (subtraction is then genuinely a new operation not expressible in existing primitives). Should the resolution of this sub-proposal be explicitly deferred until Blend resolves?

4. **Stdlib name for the `Analogy` context.** Analogy needs a named delta operation: `C + (B - A)`. Both `Difference(B, A)` and `Subtract(B, A)` work mathematically. The Analogy sub-proposal (058-014) should be consistent with whichever stdlib name wins here.

5. **Classification change precedent.** This sub-proposal was moved from CORE to STDLIB during sub-proposal review, after realizing the Blend dependency. Is this the right procedure — reclassifying mid-review when downstream effects become clear — or should it have been anticipated earlier? Lessons for future batch proposals.

---

## 058-005: Orthogonalize

1. **Orthogonalize as core vs. widened Blend with computed weights.** The trade-off: Orthogonalize as its own variant (concrete, focused) vs. Blend with expression-valued weights (unifies but widens scope). Which is the right level of generality?

2. **Should `Project` also be proposed?** Related operation — the projection itself, rather than the complement. Can be stdlib (`Project = x - Orthogonalize(x, y)`), but some applications want the projection directly. Worth a first-class form, or let stdlib handle it?

3. **Naming: `Orthogonalize` or `Reject`?** Holon calls this operation `reject` (rejection of y's component from x). "Orthogonalize" describes what the result IS (orthogonal to y); "Reject" describes what the operation DOES (rejects y's component). Which name serves the wat reader better?

4. **Handling of zero-magnitude y.** If `y` is the zero vector, `Y·Y = 0` and the projection coefficient is undefined. The implementation must handle this edge case — probably by returning `x` unchanged (nothing to project out). Should this be explicit in the semantics?

5. **Classification reconsideration.** This sub-proposal NARROWED the original Negate proposal to just the orthogonalize mode. Subtract mode went to 058-019-subtract, flip mode went to 058-020-flip. Is this the right split, or should Negate have been preserved as a single multi-mode core form?

---

## 058-006: Resonance

1. **Ternary output as a supported kind.** Resonance is the first core form producing `{-1, 0, +1}` output. Do we formalize ternary vectors as a distinct kind in the algebra, or do we treat the zeros as "encoded-as-zero but still conceptually bipolar"? The former is cleaner categorically; the latter avoids cascading type changes.

2. **Should `Mask`/`Gate` be the primitive instead?** A more general `Mask(x, boolean-vector)` primitive would make Resonance stdlib. Is the right level of generality "sign-agreement masking" (Resonance, concrete) or "arbitrary masking" (Mask, more general)?

3. **Complement form `AntiResonance` or `Dissonance`?** "Keep only the dimensions that DISAGREE" — `Dissonance(v, ref) = v - Resonance(v, ref)`. Can be stdlib once Resonance and Blend exist. Worth a first-class form for symmetry, or let stdlib handle it?

4. **Relationship to `threshold`.** If we pass Resonance output through threshold (rounding 0 → +1), we lose the "no information" semantics. Should threshold be aware of ternary input and leave zeros alone, or is it purely a `x<0 → -1, x≥0 → +1` mapping with no nuance?

5. **Holon's `attend` vs this `Resonance`.** Holon's `attend` is related but not identical (attend uses magnitude-weighted filtering, not just sign-agreement). Is this proposal naming the operation correctly, or should it reference `attend`'s exact definition? Clarify the lineage.

---

## 058-007: ConditionalBind

1. **Is functional update at this granularity the right level?** ConditionalBind enables "update one role's binding in a bundled structure." Is this the kind of operation the algebra should expose, or is it too close to imperative thinking?

2. **Gate semantics: sign-based or magnitude-based?** Convention in this proposal: `gate[i] > 0` triggers bind. Alternatives: `gate[i] == +1` (strict), or `|gate[i]| > threshold`. Strict sign-based is simplest; consistent with bipolar vector conventions.

3. **Should `Select(x, y, gate)` be the more general primitive instead?** `Select` is lower-level ("choose x or y per dimension"); ConditionalBind is higher-level idiom. Case for Select: more primitive, enables more derived operations. Case for ConditionalBind: captures the common case (update via bind) without requiring composition. Which belongs in core?

4. **Relationship to `Resonance` (058-006).** Both are per-dimension operations with one vector as a "control." Should they share a conceptual category in FOUNDATION — "gated/masked operations"? Would make the algebra more organized.

5. **Ternary gate handling.** If `gate` is produced by `Resonance` (can contain zeros), the rule "gate > 0 → bind, else pass-through" means zero dimensions pass through. Is this the right default, or should zeros have distinct behavior (e.g., output zero)?

6. **Holon's precedent.** Does the holon library have a direct analog to ConditionalBind, and if so, what does it call it? The name here is descriptive but could align with existing terminology (e.g., `bind_masked`, `selective_bind`).

---

## 058-008: Linear

1. **Is Thermometer itself core?** This reframing assumes Thermometer stays core. 058-023-thermometer treats Thermometer as the primitive. Confirm.

2. **Should stdlib forms be preserved in AST or eagerly expanded?** Preserving keeps the semantic name in AST walks. Eager expansion collapses cache keys to canonical Blend. Either works; consistency across Linear/Log/Circular is the key.

3. **Are there hidden differences between the current variant implementation and the reframing?** Float-to-integer rounding, clipping, specialized arithmetic — audit before committing to confirm the reframing is byte-for-byte equivalent to the current Linear encoder.

4. **Dependency on 058-002-blend.** If Blend is rejected, Linear stays core. Should resolution be explicitly deferred until Blend resolves?

5. **Scale argument shape.** `scale` here is a list `(min max)`. Is this the conventional shape across Linear/Log/Circular? Log also uses min/max; Circular uses a single period. Inconsistent shapes may complicate stdlib code. Confirm per-encoder conventions.

---

## 058-009: Sequential — Reframing

1. **Does `map-with-index` exist in the wat stdlib?** The expansion assumes a `map-with-index` combinator (or equivalent iteration primitive). If the wat stdlib does not yet have one, this proposal depends on its addition — either a proposal to add it, or folding the expansion to use explicit index arithmetic (less elegant but works without `map-with-index`).

2. **Is the permutation indexing 0-based or 1-based?** Convention here is 0-based (first element gets `Permute by 0` = identity). Some implementations might use 1-based. Pick one, document it.

3. **Should the AST preserve `Sequential` as a semantic name?** As with Linear/Log/Circular, preserving stdlib forms in AST walks keeps semantics visible. Cache keys can be on the stdlib form or on the expanded form. Decision should be consistent across all reframings.

4. **Relationship to `Array` (058-026).** Array is also an indexed list-of-thoughts form. Does Array's expansion internally rely on Sequential, or does Array have its own independent expansion? If Array uses Sequential, making Sequential stdlib is prerequisite for Array's stdlib form.

5. **Historical note: why was Sequential grandfathered?** Understanding why it was kept as a variant originally (perf? clarity?) helps decide if this reframing is the right call or if there's a forgotten reason for the special case. If the reason was just "we had it before we had Permute as a clean variant," grandfathering can end cleanly.

---

## 058-010: Concurrent

1. **Synonym policy.** If `Concurrent` is accepted, are `Simultaneous`, `Parallel`, `Together`, etc. DOCUMENTATION ALIASES (multiple names resolve to the same stdlib function) or REJECTED (only one canonical name)? This proposal leans toward rejected — one canonical name keeps the vocabulary lean.

2. **Should Bundle be reserved for primitive use and everything else go through named aliases?** An alternative style: vocab modules NEVER call `Bundle` directly, they always go through `Concurrent`, `Set`, `Pattern`, etc. Bundle is the primitive, the named forms are the surface. Pros: clear layer separation. Cons: requires a proliferation of names to cover all intents.

3. **Cache canonicalization.** Should `Concurrent` and `Bundle` share cache entries (eager expansion, canonical AST) or have separate cache entries (preserve the semantic name)? This mirrors the same decision for Linear/Log/Circular in 058-008/017/018.

4. **Dependency on Set and Sequential.** This proposal groups Concurrent with other "list-operating Bundle wrappers." If Set (058-027) is rejected, Concurrent might want to absorb that role. If Sequential (058-009) stays as its current variant, the trio is less symmetric. These three should resolve together.

5. **Is "Concurrent" the right word?** In programming contexts, "concurrent" often implies parallelism, interleaving, or race conditions. In the temporal semantics used here, it means "at the same time." Could be confusing for readers with systems programming backgrounds. Alternatives: `Simultaneous`, `SameMoment`, `Coincident`. Recommendation: accept `Concurrent` (matches holon precedent, short, readable) and explicitly document the meaning.

---

## 058-011: Then

1. **Permutation count convention.** This proposal uses `(Permute b 1)`. Is 1 the right convention, or should it be a larger gap (e.g., 7, 13) for better dimensional decorrelation? Small permutations may not mix dimensions enough for downstream cleanup to distinguish positions. Should the stdlib form use a carefully-chosen constant, or always 1?

2. **Relationship to `Sequential` at length 2.** `(Then a b) = (Sequential [a b])` if both use the same permutation scheme. Should they be enforced-equivalent at this length, or could their implementations diverge (different permutation choices)? Consistency seems valuable.

3. **Should Then also have a reverse form (`After(b, a) = Then(a, b)`)?** "A happens after B" is sometimes more natural than "B happens, then A." Same operation from the opposite reading. Worth a separate stdlib name, or too much alias proliferation?

4. **Chaining `Then` operations.** `(Then (Then a b) c)` creates a nested structure with TWO levels of permutation (b permuted once inside, the whole `(Then a b)` permuted once more when combined with c). Is this the intended recursive structure, or should `Chain` (058-012) handle multi-step chains flat? This proposal assumes `Chain` handles flat chains; nested Then is structurally meaningful but less common.

5. **Application to event sequences.** Vocab modules encoding event sequences (candle → indicator → signal → entry) would chain Thens. At what point does the recursive Then structure break down dimensionally? Small vectors (d=1024) may not support deep chains before cleanup fails. Worth noting in documentation.

---

## 058-012: Chain

1. **Edge case semantics.** What does `(Chain [])` produce? What does `(Chain [a])` produce? Proposal: empty → zero vector (or error, matching Bundle's empty behavior); singleton → `a` unchanged. Confirm conventions.

2. **Dependency on Then's resolution.** If Then (058-011) is rejected, Chain must re-express directly. Should this sub-proposal be explicitly deferred until Then resolves, or should both be reviewed together?

3. **Bounded vs. unbounded chain length.** For very long chains (hundreds of thoughts), the bundle's capacity is exhausted and individual transitions may not be recoverable via cleanup. Should Chain carry a length warning/limit, or is this a documentation concern only?

4. **Position information or not.** Chain encodes pairwise transitions but loses absolute position information (transition `a→b` in a long chain is indistinguishable from `a→b` at the start of a short chain). Is this the right tradeoff, or should Chain optionally encode starting position too?

5. **Relationship to Sequential.** Both are ordered encodings of lists. Should vocab modules prefer Chain (transition-aware) or Sequential (position-aware), and under what circumstances? Documentation guidance would help vocab authors choose.

6. **`Chain2`, `Chain3`, etc.?** If Chain becomes too restrictive (always pairwise), there may be pressure to add `Chain3` (triplet adjacency) and beyond. Ngram (058-013) generalizes this — the n=2 case is Chain, higher `n` is Ngram. Resolve by keeping Chain as the n=2 idiom and using Ngram for everything else.

---

## 058-013: Ngram

1. **Window encoding: Sequential or custom?** The cleanest definition uses Sequential to encode each window. If 058-009 keeps Sequential as a stdlib form, this is clean. If Sequential is rejected (stays as variant), Ngram's internal window encoding inlines the Bundle+Permute pattern.

2. **Edge cases.** What does `(Ngram 0 xs)` produce? `(Ngram 5 [a b c])`? `(Ngram 2 [])`? Proposal: `n=0` is error, `n > length` is empty bundle (zero vector), `xs = []` is empty bundle. Confirm conventions.

3. **Specialized names for small `n`: `Bigram`, `Trigram`?** Pros: readable for the common cases. Cons: name proliferation. Recommendation: keep only `Ngram` as the parameterized form, and `Chain` as the `n=2` specialization (already in 058-012). Avoid `Bigram`/`Trigram` unless they earn distinct semantic intent beyond "Ngram with specific n."

4. **Stdlib dependencies.** `n-wise-split`, `take`, `length`, `map`, `rest` — these are standard list operations that Ngram depends on. Are all present in the current wat stdlib, or does this proposal need to bring them in as prerequisites?

5. **Performance.** An Ngram over a list of length `k` with window `n` produces `k-n+1` windows, each requiring a Sequential encoding. This is `O(k·n)` sub-AST construction and encoding, plus one top-level Bundle of `k-n+1` items. Acceptable for reasonable `k, n`; could be expensive for long lists. Document the scaling.

6. **Relationship to the generalist-observer's rhythm encoding.** The holon-lab-trading project uses an n-gram-like approach for indicator rhythms (bundled bigrams of trigrams). Is this proposal's `Ngram` the right primitive to replace that bespoke encoding, or is the trading-specific encoding subtly different?

---

## 058-014: Analogy

1. **Dependency on 058-004's delta name.** This proposal uses `Difference`. If 058-019 names it `Subtract` instead, the expansion changes to `(Subtract b a)` or `(Blend b a 1 -1)` direct. The resolution should be consistent — one delta name in stdlib, used by Analogy.

2. **Argument order convention.** The standard `(a, b, c)` is "a is to b as c is to ?". Could alternatively be `(a, b, c, d)` returning a cleanup match, or `(from, to, apply-to)` with keyword-ish naming. Recommendation: stick with the three-term positional form, document clearly.

3. **Should the stdlib also provide the four-term `AnalogyCleanup`?** A convenience form that runs cleanup against a candidate pool:

```scheme
(:wat/core/define (:my/vocab/AnalogyCleanup a b c candidates)
  (cleanup (:wat/std/Analogy a b c) candidates))
```

Over-naming risk, but this is the most common use case. Worth a second named form, or let users compose cleanup around Analogy manually?

4. **Domain applications.** In holon-lab-trading, are there specific analogy use cases? E.g., "trend phase X was to breakout as trend phase Y is to ?" This proposal's existence opens the door; concrete vocab applications should be tracked.

5. **Relationship to Plate/Kanerva's formulations.** Different VSA literature has subtly different analogy completions (circular convolution-based, binding-based, etc.). Is this formulation (Bundle-based with Difference) compatible with all of them? Document the chosen formulation.

---

## 058-015: Amplify

1. **`s = 1` degeneracy.** `(Amplify x y 1)` ≡ `(Bundle [x y])`. Should Amplify document this, or restrict `s ≠ 1`? Recommendation: document, don't restrict.

2. **Negative `s` overlap with Subtract / Flip.** `(Amplify x y -1)` ≡ `(Subtract x y)`, `(Amplify x y -2)` ≡ `(Flip x y)`. Recommendation: freely allow overlap; stylistic preference picks the most specific name.

3. **Attenuation variant?** Some applications want "reduce `y`'s contribution" specifically (`0 < s < 1`). Could be a named variant `Attenuate` for clarity. Recommendation: no — avoid further proliferation. `(Amplify x y 0.5)` suffices; if users want a name for attenuation they can define their own stdlib alias.

4. **Dependency on Blend.** If 058-002 rejects, Amplify cannot exist. Resolution order: Blend first.

5. **Related trading-domain idioms.** In holon-lab-trading, the manager aggregates observer opinions — an Amplify pattern (observer X is weighted higher based on its conviction). Does this vocab fit Amplify cleanly? Concrete usage would validate the form.

---

## 058-016: Map

1. **Duplicate keys.** `(Map [[:a 1] [:a 2]])` produces noisy cleanup for key `:a`. Document the behavior as "Map does not deduplicate; pre-filter if needed," or add an automatic deduplication pass? Recommendation: document, don't automate.

2. **Accessor variants.** `get` (with cleanup) vs `get-raw` (without). Both useful. Keep both with these names? Or use `get` for raw and `get-cleanup` for the cleanup variant? Recommendation: `get` is the common case (with cleanup); `get-raw` for the raw case.

3. **Key type constraints.** Map keys are often keyword atoms (`:color`, `:price`). Can keys also be integers, strings, composite ASTs? Per 058-001, Atom accepts typed literals; any atom can be a key. Per 058-007-conditional-bind, full ASTs can be used as binding operands. Confirm: Map keys can be any thought.

4. **Performance for large Maps.** Bundle's capacity is bounded (~d / ln(K) items for reliable cleanup). Maps with many keys exceed capacity and produce noisy retrieval. Document the capacity bound; stdlib could provide a `LargeMap` variant using partitioning if demand arises.

5. **Nested Maps.** `(Map [[:user (Map [[:name "alice"] [:age 30]])]])` nests dictionaries. `get`s compose: `(get (get root :user cb) :name cb)`. Or a `deep-get` stdlib variant for path-based access. Out of scope for this proposal but worth noting as a likely next stdlib addition.

6. **Empty Map.** `(Map [])` produces an empty Bundle — an all-zeros or undefined vector. Document the degenerate case or forbid it.

7. **Dependency ordering.** Map depends on Bundle and Bind (both core). `get` depends on Unbind (058-024) and Cleanup (058-025). If any prerequisite is rejected, Map and its accessors change. Explicit dependency statement: this proposal assumes all four primitives are available.

---

## 058-017: Log

1. **Is `log` in the wat stdlib?** The expansion depends on natural log (or log with a base, though the base cancels out of the ratio). If not available, this proposal depends on adding log primitives to wat.

2. **Numerical preconditions.** `min, max, value` must all be positive (log requires positive arguments). Should the stdlib Log enforce this, or treat violations as undefined?

3. **Log base choice.** Natural log is conventional; base-10 or base-2 produce the same result (the base cancels in the ratio). Does holon-rs have a preference?

4. **Same consistency concerns as 058-008.** AST preservation, cache keys, encoder audit — resolve uniformly across all three scalar-encoder reframings.

5. **Alternatives: `LogLinear`, `Exponential`?** Log is one log-scale encoder. Others (log-sigmoid, stretched-log, signed-log for values crossing zero) are plausible stdlib additions. Linear's reframing opens the door; does Log have a family of companions?

---

## 058-018: Circular

1. **Are `sin`, `cos`, `pi` available in the wat stdlib?** Required for the expansion. If not, add as prerequisites.

2. **Scale argument shape.** Circular's `scale = (period,)` differs from Linear/Log's `scale = (min, max)`. Unify (e.g., `(0, period)` for Circular) or document per-encoder? Consistency may help readability.

3. **Blend Option B verification.** Circular is the test case for Option B's independent weights. Any Blend implementation must correctly handle negative weights. Confirm this is in the Blend acceptance criteria.

4. **Angle conventions.** This proposal uses `angle = 2π · value / period` — standard radians, counterclockwise from 0. Alternative conventions (degrees, clockwise, phase offset) are possible. Document the choice.

5. **Starting angle offset.** Some applications want `value = 0` to correspond to a specific position (e.g., "noon" maps to angle 0, "midnight" maps to π). This is an offset parameter. Should Circular's stdlib form support it, or should users write a variant?

6. **Same consistency concerns as 058-008 and 058-017.** AST preservation, cache keys, encoder audit — resolve uniformly across all three scalar-encoder reframings.

7. **New circular encoders.** "Half-circle" (values in `[0, π]`), "cyclic-Gaussian" (peaked at some phase), "wavelet" — all potential stdlib extensions once Circular is reframed. Not in this proposal's scope but opens the door.

---

## 058-019: Subtract

1. **Subtract vs Difference: keep both or unify?** Same math. Different reader intents. This proposal keeps both. Alternative: pick one, deprecate the other. Recommendation: keep both; the cost is trivial and the clarity gain is real.

2. **Naming: `Subtract` or `Remove`?** "Subtract" has mathematical connotations; "Remove" has more direct intent ("remove the noise"). Recommendation: keep `Subtract` — aligns with holon-rs's `subtract` function; readers recognize it.

3. **Imperative `Subtract!` variant for in-place?** In some languages, exclamation suffix denotes mutation. Here all operations are pure (ASTs are immutable). Irrelevant, noted for consistency.

4. **Dependency on 058-002-blend.** If rejected, Subtract re-proposes as core (it is one of the three original Negate modes, per FOUNDATION's history). Resolution order: Blend first.

5. **Subtract's relationship to Orthogonalize (058-005).** Subtract removes `y` linearly. Orthogonalize removes `y`'s DIRECTION proportionally. Different operations, different invariants. Subtract is stdlib; Orthogonalize is core (has a computed weight). Documentation should make the distinction explicit to avoid confusion.

---

## 058-020: Flip

1. **Naming: `Flip` or alternative?** "Flip" overloads with "negate a vector" in general VSA usage. Alternatives: `Invert`, `Counter`, `Oppose`. Recommendation: keep `Flip` to match holon's existing naming; document clearly.

2. **Rigor of the `-2` weight.** Flip's weight `-2` is the MINIMUM value that flips agreed dimensions. Larger negative weights (`-3`, `-4`) produce the same flipped sign but differ in pre-threshold magnitude. Should Flip's stdlib form offer a strength parameter (`Flip(x, y, strength)`) or fix at `-2`? Recommendation: fix at `-2` (canonical minimum); users wanting stronger inversion use Amplify with their chosen negative weight.

3. **Usage patterns in holon-lab-trading.** Are there domain vocabularies that need Flip specifically? If not, the stdlib name is theoretical — useful for completeness but not load-bearing for current work.

4. **Dependency on 058-002-blend.** If rejected, Flip re-proposes as part of a core Negate variant (reverts to FOUNDATION's original 3-mode plan).

5. **Relationship to Orthogonalize.** Flip is linear inversion; Orthogonalize removes the projected direction. Flip is cheap; Orthogonalize requires a dot product. Documentation should distinguish when to use each — "are you removing y linearly (Flip) or removing y's direction geometrically (Orthogonalize)?"

6. **Is Flip the right completion of the Negate trilogy?** Original Negate had subtract/flip/orthogonalize modes. This proposal completes the trilogy with Flip as the stdlib companion to Subtract and the non-core companion to Orthogonalize. Are designers satisfied with this split, or would they prefer a different decomposition?

---

## 058-021, 058-022, 058-023 — Audited in CORE-AUDIT.md

Bind, Permute, and Thermometer are affirmed core primitives already present in holon-rs. The affirmation proposals had no open designer-facing questions — every entry was self-answering ("Is this proposal needed? … or is an audit entry sufficient?"). All three have been collapsed into `CORE-AUDIT.md`, which records operation, canonical form, MAP/VSA role, and downstream conventions. No open questions remain.

---

## 058-024: Unbind

1. **Accept the alias or reject it?** The operation is mathematically Bind. This proposal argues the reader-intent distinction earns the alias. Alternative: document that "unbind is Bind" and have vocab code always call Bind. Recommendation: accept Unbind; the clarity gain is load-bearing for accessor stdlib forms like `get`.

2. **Cache canonicalization.** Same issue as Linear/Log/Circular from 058-008+. Preserve stdlib form in AST (separate cache, semantic name visible) or eagerly expand (canonical cache, lose name). Consistency across all stdlib aliases is key.

3. **Non-bipolar future.** If Resonance (058-006) or other forms produce ternary/non-bipolar outputs, Unbind may need a NEW implementation separate from Bind. Is this proposal reserving the name for that future, or strictly a bipolar alias?

4. **Naming within accessor stdlib forms.** `get`, `nth`, and any `lookup`-style accessors use Unbind internally. Is the word "Unbind" consistently usable in all their definitions, or does the argument-order convention (composite first vs. key first) vary?

5. **Dependency on 058-021-bind.** If Bind is in some unexpected way modified (e.g., non-bipolar input support), Unbind's alias relationship may change. Confirm Bind's signature and semantics in 058-021 before finalizing Unbind.

6. **Is "Unbind" the right name?** Alternatives: `Probe`, `Decode`, `Extract`, `Recover`. "Unbind" is convention in VSA literature. Recommendation: keep "Unbind" for convention match; document clearly.

---

## 058-025: Cleanup

1. **Is this proposal needed?** Cleanup's core status is universally accepted. Leaves-to-root completeness argues for a doc. Recommendation: accept this doc as affirmation; it clarifies Cleanup's algebraic role even though no change is made.

2. **Should Cleanup decompose into `Similarity` + `Argmax`?** A future proposal could split Cleanup into the scalar similarity primitive and the aggregation over candidates. Pros: cleaner layering, more composable. Cons: changes a well-known primitive's signature. Recommendation: defer to a future proposal; affirm Cleanup as-is for now.

3. **Cleanup as AST variant vs. library function.** Currently holon-rs exposes Cleanup as a library function. Should it also be a ThoughtAST variant (so ASTs can contain Cleanup nodes, and caching applies)? Most cleanup calls are AT RESULT TIME, so AST embedding may not be necessary. But for expressible-in-AST patterns, variant status helps. Design question.

4. **Return type.** Cleanup returns THE best match, or a ranked list, or match-with-score. Different variants in different contexts. Should there be multiple Cleanup forms (`Cleanup`, `CleanupRanked`, `CleanupWithScore`), or one with an options parameter? Recommendation: one primitive returns the match; stdlib `CleanupRanked` and similar are extensions.

5. **Similarity metric convention.** Cosine similarity vs. Hamming distance vs. Euclidean distance. The conventional choice is cosine for continuous bipolar, Hamming for bitwise bipolar. Document the convention; stdlib may expose named-alternative cleanups (e.g., `HammingCleanup`) if needed.

6. **Codebook preprocessing.** Cleanup's performance scales with codebook size. For large codebooks (>10k candidates), eigenvalue-prefiltering (challenge 018) is used. Should this preprocessing be part of the Cleanup contract (always happen), or opt-in? Design choice; likely opt-in via engram libraries.

7. **Relationship to engrams.** Engram caches (L3/L4 per FOUNDATION) are optimized Cleanup targets. Is `EngramCleanup` a distinct stdlib form, or is Cleanup polymorphic over vector-list vs. engram-library candidates? Recommendation: polymorphic — one primitive, multiple acceleration paths.

---

## 058-026: Array

1. **Array vs Sequential: keep both or unify?** Same expansion, different reader intents. Recommendation: keep both; the intent distinction is real in vocab code.

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
   - **Accepted as macros**: 058-012 Chain, 058-013 Ngram, 058-014 Analogy, 058-015 Amplify, 058-019 Subtract, 058-020 Flip, 058-016 HashMap, 058-026 Vec, 058-027 HashSet, 058-017 Log, 058-018 Circular, 058-009 Sequential (reframed).
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

### Theme: Dependency on 058-002 (Blend) resolution
- 058-004 Q3 — Difference cannot resolve before Blend
- 058-008 Q4 — Linear stays core if Blend rejected
- 058-015 Q4 — Amplify cannot exist without Blend
- 058-018 Q3 — Circular is test case for Blend Option B
- 058-019 Q4 — Subtract re-proposes as core if Blend rejected
- 058-020 Q4 — Flip reverts to Negate trilogy if Blend rejected

### Theme: Naming — alias proliferation vs. reader-intent clarity
- 058-004 Q1/Q2 — Difference vs Subtract
- 058-010 Q1/Q5 — `Concurrent` synonyms policy; is the word right
- 058-011 Q3 — reverse form `After` for Then
- 058-019 Q1/Q2 — Subtract vs Difference, Subtract vs Remove
- 058-020 Q1 — Flip vs Invert/Counter/Oppose
- 058-024 Q1/Q6 — accept Unbind alias; is "Unbind" the right name
- 058-026 Q1 — Array vs Sequential
- 058-027 Q1/Q5 — Set as third Bundle-alias; Group/Collection/Multiset

### Theme: Leaves-to-root completeness — "is this proposal needed" for core-affirmation docs
- 058-021 Q1 — Bind already core
- 058-022 Q1 — Permute already core
- 058-023 Q1 — Thermometer already core
- 058-025 Q1 — Cleanup already core

### Theme: Ternary / non-bipolar vectors
- 058-006 Q1 — Resonance produces `{-1, 0, +1}`; formalize ternary kind
- 058-006 Q4 — threshold-aware of ternary input
- 058-007 Q5 — ternary gate handling in ConditionalBind
- 058-021 Q2 — Bind reversibility weakens on ternary input
- 058-023 Q6 — ternary Thermometer extensions
- 058-024 Q3 — non-bipolar future for Unbind

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
