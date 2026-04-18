# 058-010: `Concurrent` — Bundle-Aliasing Stdlib Form

**Scope:** algebra
**Class:** STDLIB
**Parent:** 058-ast-algebra-surface
**Foundation:** ../FOUNDATION.md

## The Candidate

A wat stdlib macro (per 058-031-defmacro) that expresses "these holons happen simultaneously, at the same moment, with no ordering among them":

```scheme
(defmacro (Concurrent (xs :AST) -> :AST)
  `(Bundle ,xs))
```

Identical expansion to `Bundle`, identical vector output. The ONLY difference is the name at source level — expansion happens at parse time, so `hash(AST)` sees only the canonical `(Bundle ...)` form.

### Semantics

Bundle is the core superposition primitive — commutative, order-insensitive, element-wise sum with threshold. Concurrent asserts a READER INTENT: "the things in this list occur together in time, and the bundle encodes their co-occurrence."

## Why Stdlib Earns the Name

Under FOUNDATION's stdlib criterion, a named form earns its place if:

1. **Its expansion uses only existing core forms.** Bundle is core. Expansion is `(Bundle xs)` verbatim. Criterion satisfied.

2. **It reduces ambiguity for readers.** A vocab module that says `(Concurrent (list price-rising rsi-extended volume-thin))` communicates "these three observations are about the SAME moment." A Bundle call with the same arguments communicates "these three things are summed together, semantics up to reader." The named form asserts temporal co-occurrence as the reason for bundling.

Both criteria met.

## Arguments For

**1. Vocab modules distinguish co-occurrence from aggregation.**

A trading vocab module might produce:
- A `Concurrent` holon: "at this candle, price is rising AND rsi is extended AND volume is thin"
- A `Pattern` holon: "this is a head-and-shoulders shape"
- A `Signal` holon: "entry triggered"

All three are Bundles under the hood. The NAMES carry the semantic distinction — the reader understands that Concurrent encodes simultaneity, Pattern encodes shape, Signal encodes decision. Without the names, a reader sees three `Bundle(...)` calls and must infer the purpose from context.


**2. Concurrent pairs conceptually with Then (058-011) and Sequential.**

- `Concurrent(a, b, c)` — at the same time
- `Sequential((list a b c))` — in this order
- `Then(a, b)` — after a, b follows

These three forms carve up the temporal semantics space. Concurrent is the "no ordering" case. Its presence completes the vocabulary.

**3. Holon library precedent.**

Holon's Python and Rust libraries expose Concurrent as a named operation alongside Sequential. Having the wat algebra match this naming reduces translation friction and keeps the vocabulary familiar.

**4. The expansion is trivial — the name is the cost.**

```scheme
(defmacro (Concurrent (xs :AST) -> :AST)
  `(Bundle ,xs))
```

One line. No implementation risk, no perf cost, no cache complication (parse-time expansion eliminates the cache-key concern raised in earlier drafts — see Arguments Against #2). The cost is just "a name exists in stdlib."

## Arguments Against

**1. Trivial expansion — is the name earning its keep?**

`(Concurrent xs)` vs `(Bundle xs)` is a five-character difference (adjusting for the rename). The named form adds zero algebraic information. A reader who knows Bundle is commutative already knows "order does not matter" — the name Concurrent is semantic sugar only.

**Counter:** the stdlib criterion explicitly admits reader-clarity as a reason for a name. The same argument applies to Difference (058-004): `(Difference a b)` vs `(Blend a b 1 -1)` is also sugar. If we accept Difference, we accept Concurrent.

The Hickey-ian test: does the name communicate something the expansion does not? Yes — Concurrent asserts temporal co-occurrence as the intent. Bundle is neutral about intent. The stdlib form names the intent.

**2. Cache key duplication — RESOLVED by parse-time expansion.**

Under the original `(define ...)` framing, `(Concurrent xs)` and `(Bundle xs)` would have different AST shapes and thus different cache keys. With `defmacro` (058-031), expansion runs at parse time: the `Concurrent` invocation is rewritten to `(Bundle xs)` BEFORE any hashing or caching occurs. One cache entry; one hash. Finding #4 (alias hash collision) from the designer review is resolved.

**3. Proliferation risk.**

If we accept `Concurrent`, do we also accept `Simultaneous`, `Parallel`, `Together`, `CoOccurrence`, `AtTheSameTime`? Each is a synonym for "order-insensitive bundling." Where does the proliferation stop?

**Mitigation:** FOUNDATION's stdlib criterion is "named forms that improve reader clarity, expanding to core forms." The bar is not "any synonym gets a name" but "names that carry distinct semantic intent." `Concurrent` (temporal co-occurrence) and `Bundle` (generic superposition) carry different intents. `Simultaneous` and `Concurrent` are synonyms — only one should exist.

The question then is: which word? `Concurrent` matches holon's precedent and reads cleanly. Adopt it and reject synonyms.

## Comparison

| Form | Class | Semantic intent | Expansion |
|---|---|---|---|
| `Bundle(xs)` | CORE | Generic superposition | primitive |
| `Concurrent(xs)` | STDLIB (this) | Co-occurrence | `(Bundle xs)` |
| `Sequential(xs)` | STDLIB (per 058-009) | Ordered composition | Bundle of Permutes |
| `Set(xs)` | STDLIB (per 058-027) | Unordered collection | `(Bundle xs)` |

`Concurrent` and `Set` also both expand to Bundle. See 058-027 for Set's distinction — Set is a collection type (data structure), Concurrent is a temporal assertion. Different reader intent, same expansion.

## Algebraic Question

Does Concurrent compose with the existing algebra?

Trivially — it IS Bundle. All downstream operations (similarity, bind, further bundle) work without modification.

Is it a distinct source category?

No. Algebraically identical to Bundle. The distinction is at the semantic layer (reader intent), not the algebraic layer.

## Simplicity Question

Is this simple or easy?

Simple — one-line stdlib. The only question is whether the name earns its place, which is a reader-clarity judgment, not a complexity judgment.

Is anything complected?

Potentially. If `Concurrent`, `Set`, and plain `Bundle` all expand identically, that's three names for one operation. Mitigated by distinct reader intent — but the risk of "alias proliferation" is real. Keep the canonical names minimal: `Bundle` (the primitive), `Concurrent` (temporal), `Set` (data structure). No further aliases.

Could existing forms express it?

Yes — `(Bundle xs)`. The stdlib form asserts reader intent.

## Implementation Scope

**Zero Rust changes beyond 058-031-defmacro's macro-expansion pass.** Pure wat.

**wat stdlib addition** — one macro, registered at parse time:

```scheme
;; wat/std/sequences.wat (or similar)
(defmacro (Concurrent (xs :AST) -> :AST)
  `(Bundle ,xs))
```

Registration is parse-time (per 058-031-defmacro): the macro is loaded during the startup expansion pass, and every `(Concurrent ...)` invocation in source is rewritten to `(Bundle ...)` before hashing.

## Questions for Designers

1. **Synonym policy.** If `Concurrent` is accepted, are `Simultaneous`, `Parallel`, `Together`, etc. DOCUMENTATION ALIASES (multiple macros resolve to the same expansion) or REJECTED (only one canonical name)? This proposal leans toward rejected — one canonical name keeps the vocabulary lean.

2. **Should Bundle be reserved for primitive use and everything else go through named macros?** An alternative style: vocab modules NEVER call `Bundle` directly, they always go through `Concurrent`, `Set`, `Pattern`, etc. Bundle is the primitive, the named macros are the surface. Pros: clear layer separation. Cons: requires a proliferation of names to cover all intents.

3. **Cache canonicalization — resolved.** Parse-time expansion (058-031-defmacro) means `Concurrent` and `Bundle` invocations collapse to the same canonical AST before hashing; they share one cache entry automatically. No tooling decision needed.

4. **Dependency on Set and Sequential.** This proposal groups Concurrent with other "list-operating Bundle wrappers." If Set (058-027) is rejected, Concurrent might want to absorb that role. If Sequential (058-009) stays as its current variant, the trio is less symmetric. These three should resolve together.

5. **Is "Concurrent" the right word?** In programming contexts, "concurrent" often implies parallelism, interleaving, or race conditions. In the temporal semantics used here, it means "at the same time." Could be confusing for readers with systems programming backgrounds. Alternatives: `Simultaneous`, `SameMoment`, `Coincident`. Recommendation: accept `Concurrent` (matches holon precedent, short, readable) and explicitly document the meaning.
