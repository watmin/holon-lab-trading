# 058-027: `Set` — Stdlib Unordered-Collection Constructor

**Scope:** algebra
**Class:** STDLIB (macro alias for Bundle with data-structure intent)
**Parent:** 058-ast-algebra-surface
**Foundation:** ../FOUNDATION.md
**Depends on:** Bundle (CORE, 058-003 for signature)
**Companion proposals:** 058-016-map, 058-026-array

## The Candidate

A wat stdlib macro (per 058-031-defmacro) that constructs an encoded unordered collection from a list of thoughts:

```scheme
(defmacro Set [xs : AST] -> :AST
  `(Bundle ,xs))
```

Identical expansion to `Bundle` and to `Concurrent` (058-010, also a macro). The only distinction is reader intent at source: `Set` communicates "data-structure: unordered collection," while `Bundle` communicates "superposition primitive" and `Concurrent` communicates "temporal co-occurrence." All three collapse to the same canonical AST after parse-time expansion, so `hash((Set xs)) = hash((Concurrent xs)) = hash((Bundle xs))` — no alias collision.

### Semantics

`Set` encodes a collection of thoughts where order does NOT matter. The encoding is Bundle's commutative elementwise sum — `Set([a, b, c])` and `Set([c, b, a])` produce the same vector. Set membership can be tested via cosine similarity (is this member's vector aligned with the bundled set?), though cleanup is recommended for crisp answers.

### Membership test

```scheme
;; Build a set:
(define fruits
  (Set (list apple banana cherry date)))

;; Test whether a candidate is in the set (noisy — use a threshold):
(define fruit-likeness
  (cosine-similarity fruits apple))        ; high if apple is in the set

;; Cleanup-based retrieval — does the set contain any of these?
(define contained
  (cleanup fruits fruit-vocabulary))
```

No dedicated `contains` accessor because Set doesn't encode position or role — it only encodes membership via superposition. Similarity tests are the natural query.

## Why Stdlib Earns the Name

Under FOUNDATION's stdlib criterion:

1. **Its expansion uses only existing core forms.** Bundle is core.

2. **It reduces ambiguity for readers.** `(Set fruits)` communicates "an unordered collection of fruits." `(Bundle fruits)` communicates "the superposition primitive applied to fruits" — a reader must infer the collection intent.

Both criteria met.

## Arguments For

**1. "Unordered collection" is distinct from "superposition" and "co-occurrence."**

Three reader intents for the same expansion:
- `Bundle`: "the primitive superposition" — you're directly invoking the algebra
- `Concurrent`: "these things happen at the same time" — temporal framing
- `Set`: "these things are a collection" — data-structure framing

Three legitimate reader contexts. Each earns its name through distinct intent.

**2. Set membership tests have a natural semantics.**

`Set(xs)` is the superposition of the xs. Testing whether `y` is a member means testing similarity with `y`:
- High similarity: `y` contributes strongly to the superposition, likely a member
- Low similarity: `y` is orthogonal to the superposition, likely not a member

For small sets (under Bundle's capacity bound), cleanup against a candidate vocabulary gives crisp "is this in the set?" answers. For larger sets, the noisy similarity is still informative.

**3. Pairs with other data-structure stdlib.**

Map, Array, Set — the three basic data structures. Each has a reader-intent distinguishing it from raw Bundle/Sequential/Bind expressions. Consistent vocabulary.

**4. Composes with other structures.**

- `Set` of Maps: unordered collection of records
- Map from key to `Set`: multi-valued dictionary
- Array of Sets: ordered list of collections

All expressible through the stdlib layering.

## Arguments Against

**1. Is it just Bundle with a different name?**

Mechanically identical to Bundle. Two names for one operation (three, counting Concurrent).

**Counter:** the same argument applied to every intent-alias. FOUNDATION's stdlib criterion admits reader clarity as sufficient justification. Set passes that criterion through its data-structure reader intent — distinct from Bundle's primitive-operation intent and from Concurrent's temporal intent.

**2. Alias proliferation with Concurrent.**

Set and Concurrent both alias Bundle. Three names for one expansion:
- `Bundle` — primitive
- `Concurrent` — temporal
- `Set` — data-structure

Where does proliferation stop?

**Mitigation:** stop here. `Bundle` is the primitive; `Concurrent` is the temporal alias; `Set` is the data-structure alias. No further aliases (reject `Group`, `Collection`, `Multiset`, etc. unless they earn a distinct reader intent).

**3. No dedicated accessor.**

Map has `get`. Array has `nth`. Set has... similarity tests. This asymmetry may feel incomplete.

**Counter:** Set is fundamentally different from Map and Array. It has NO key or index — only membership. Similarity testing IS the accessor. If a dedicated `contains?` wrapper is useful, it can be added:

```scheme
(define (contains? set-thought candidate)
  (> (cosine-similarity set-thought candidate) threshold))
```

But the threshold is application-dependent, so this is left for userland stdlib rather than the canonical Set proposal.

**4. Bundle capacity constrains practical set size.**

Kanerva's bound: Bundle reliably superposes ~`d / (2 · ln(K))` items before cleanup starts to fail. For a 10,000-dimensional space, ~100 items per set before reliability breaks down.

Mitigation:
- Sets smaller than capacity: works well
- Sets larger than capacity: use engram libraries (FOUNDATION's memory hierarchy) instead
- Document the capacity bound; unbounded-size sets are not this data structure's use case

**5. Duplicate handling.**

`(Set [:a :a :b])` superposes `:a` twice. The resulting vector has more of `:a`'s signature than a set without duplicates. Is this mathematically a "set" or a "multiset"?

**Counter:** technically a multiset (though the multiplicities are lost in cleanup). For strict set semantics, users deduplicate before calling. Document the behavior; if a `StrictSet` is needed later, add it in userland stdlib.

## Comparison

| Form | Class | Expansion | Reader intent |
|---|---|---|---|
| `Bundle(xs)` | CORE | threshold(Σ xs[i]) | Primitive superposition |
| `Concurrent(xs)` | STDLIB macro (058-010) | `Bundle(xs)` | Temporal co-occurrence |
| `Set(xs)` | STDLIB macro (this) | `Bundle(xs)` | Data-structure: unordered collection |
| `Array(ts)` | STDLIB macro (058-026) | `Sequential(ts)` | Data-structure: indexed list |
| `Map(kvs)` | STDLIB (058-016) | `Bundle(Bind(k,v) for each kv)` | Data-structure: dictionary |

Three Bundle-aliases (two macros + the core primitive), one Sequential-alias macro, one Bind-over-Bundle composition. Five stdlib forms for the common data-structure vocabulary, collapsing to two canonical expansions after parse-time macro expansion.

## Algebraic Question

Does Set compose with the existing algebra?

Trivially — it IS Bundle. All downstream operations work.

Is it a distinct source category?

No. Stdlib alias.

## Simplicity Question

Is this simple or easy?

Simple. One-line expansion.

Is anything complected?

The triple-alias (Bundle / Concurrent / Set) risks reader confusion. Mitigated by documented intent-distinctions.

Could existing forms express it?

Yes — `(Bundle xs)`. Named form earns its place via data-structure reader intent.

## Implementation Scope

**Zero Rust changes beyond 058-031-defmacro's macro-expansion pass.** Pure wat.

**wat stdlib addition** — `wat/std/structures.wat`:

```scheme
(defmacro Set [xs : AST] -> :AST
  `(Bundle ,xs))
```

Registered at parse time (per 058-031-defmacro): every `(Set xs)` invocation is rewritten to `(Bundle xs)` before hashing.

Optional userland helper (not part of this proposal):

```scheme
;; userland: threshold-based membership test — regular function, not a macro
(define (contains? set-thought candidate threshold)
  (> (cosine-similarity set-thought candidate) threshold))
```

## Questions for Designers

1. **Alias acceptance.** Set is the third Bundle-alias (after Bundle itself and Concurrent). Accept the triple-alias for reader clarity, or consolidate to fewer names? Recommendation: accept; each has distinct intent.

2. **Accessor expectations.** Map has `get`, Array has `nth`. Should Set have a dedicated accessor? Proposal: no — similarity testing IS the accessor for Set. Document this asymmetry.

3. **Duplicates vs strict set semantics.** `(Set [:a :a :b])` is technically a multiset (duplicates superpose). Document as "Set does not deduplicate; pre-filter for strict set semantics." Add a `StrictSet` stdlib form only if demand emerges.

4. **Set size capacity.** Bundle's reliable-recovery bound is ~d/(2·ln(K)). For d=10,000 that's ~100 items. Document the limit; large sets use engram libraries instead.

5. **Relationship to `Group` / `Collection` / `Multiset`.** Are any of these distinct enough to warrant their own stdlib names? Recommendation: no — Set covers the data-structure intent; further aliases are redundant.

6. **Set operations (union, intersection).** In classical set theory, `A ∪ B`, `A ∩ B`, `A \ B` are primary operations. For Bundle-encoded sets:
   - Union: `(Set (concat A B))` or `(Bundle [A B])` — works cleanly
   - Intersection: `(Resonance A B)` — keeps dimensions where both sets align (per 058-006)
   - Difference: `(Orthogonalize A B)` or `(Subtract A B)` (058-019) — removes B's contribution from A
   Worth noting as future stdlib idioms but out of scope for this proposal.

7. **Empty set.** `(Set [])` produces an empty Bundle — all-zeros or undefined vector. Document as degenerate case; callers should check for empty before encoding.
