# 058-026: `Array` — Stdlib Indexed-List Constructor

**Scope:** algebra
**Class:** STDLIB (alias for Sequential with data-structure intent)
**Parent:** 058-ast-algebra-surface
**Foundation:** ../FOUNDATION.md
**Depends on:** 058-009-sequential-reframing, 058-022-permute, 058-025-cleanup
**Companion proposals:** 058-016-map, 058-027-set

## The Candidate

A wat stdlib function that constructs an encoded indexed list from a list of thoughts:

```scheme
(define (Array thoughts)
  (Sequential thoughts))
```

Identical expansion to `Sequential` (058-009). The only distinction is reader intent: `Array` communicates "data-structure: ordered indexed list," while `Sequential` communicates "positional encoding of a temporal or ordered sequence."

### Semantics

`Array` encodes a list of thoughts where each element at position `i` is permuted by `i` steps, and all elements are bundled. Indexed retrieval is possible via inverse permutation and cleanup:

```scheme
;; Build an array:
(define fruits
  (Array (list apple banana cherry date)))

;; Retrieve position 2 (cherry):
(define position-2
  (cleanup (Permute fruits -2) fruit-vocabulary))
```

### The `nth` accessor

```scheme
(define (nth array-thought index candidates)
  (cleanup (Permute array-thought (- 0 index)) candidates))

;; Raw variant (no cleanup):
(define (nth-raw array-thought index)
  (Permute array-thought (- 0 index)))
```

`nth` inverts the position-permutation. The index's negation pulls position `i`'s contribution to position 0 (the "unpermuted" alignment for cleanup).

## Why Stdlib Earns the Name

Under FOUNDATION's stdlib criterion:

1. **Its expansion uses only existing core/stdlib forms.** Sequential is stdlib (058-009); transitively, Array expands to Bundle over Permute, both core.

2. **It reduces ambiguity for readers.** `(Array fruits)` communicates "an indexed list of fruits." `(Sequential fruits)` communicates "the order of these fruits matters." Same vector, different reader framings.

Both criteria met.

## Arguments For

**1. Data-structure framing distinct from temporal framing.**

`Sequential` reads as "temporal/ordered sequence." `Array` reads as "data container indexed by integers." A vocab module encoding a time series uses Sequential; a vocab module encoding a list of options uses Array. Same underlying encoding; different reader intents.

Examples:
- `(Sequential stages-of-formation)` — "these stages happened in this order"
- `(Array candidate-moves)` — "these are the moves, indexed 0 through 3"

**2. Pairs naturally with `nth` for read/write symmetry.**

Just as Map pairs with `get`, Array pairs with `nth`. Indexed retrieval from an Array is a common operation that deserves a named accessor.

**3. Consistent with holon-rs's `Array` concept.**

Holon libraries treat arrays as indexed collections separate from temporal sequences. Having both `Array` and `Sequential` in wat matches the existing library surface.

**4. Composes with other data-structure stdlib forms.**

- `Map` of Arrays: records with list fields
- Array of Maps: tables
- Array of Arrays: 2D grids
- `Set` of Arrays: unordered collection of ordered lists

All expressible because Array is a wat function.

## Arguments Against

**1. Alias for Sequential — is the name earning its place?**

`Array` and `Sequential` produce identical vectors. Both take lists. Both encode position. Same math.

**Counter:** same argument as Concurrent/Bundle, Set/Bundle, Subtract/Difference. Reader intent carries load-bearing information; naming the intent is a legitimate stdlib purpose. FOUNDATION's criterion admits reader-clarity as sufficient justification.

**2. Alias proliferation.**

Three stdlib forms for "list of thoughts in order":
- `Sequential` (temporal encoding intent)
- `Array` (data-structure intent)
- Possibly `List` or `Vector` (other language conventions)

Where does the proliferation stop?

**Mitigation:** two canonical aliases — `Sequential` for temporal, `Array` for data-structure. No further aliases. `List` and `Vector` are ambiguous (vector conflicts with VSA vectors; list conflicts with the underlying argument type).

**3. Accessor requires a codebook.**

`nth` uses cleanup, which requires a candidate vocabulary. Same issue as `get` for Map.

**Mitigation:** provide both `nth` (with cleanup) and `nth-raw` (without). Same pattern as Map.

**4. `nth`'s negation can be confusing.**

`(nth arr 2)` expands to `(Permute arr -2)`. The negative index means "undo 2 steps of forward permutation." Readers unfamiliar with the convention may find this counter-intuitive.

**Mitigation:** document clearly — Array encoding permutes each item by its position; `nth` inverts by permuting backward by the same count. The negation is a mechanical necessity of the inverse permutation.

## Comparison

| Form | Class | Expansion | Reader intent |
|---|---|---|---|
| `Sequential(ts)` | STDLIB (058-009) | Bundle of index-permuted items | Temporal/ordered sequence |
| `Array(ts)` | STDLIB (this) | `Sequential(ts)` | Data-structure: indexed list |
| `nth(a, i, cb)` | STDLIB helper (this) | cleanup(Permute(a, -i), cb) | Array accessor |
| `nth-raw(a, i)` | STDLIB helper (this) | Permute(a, -i) | Raw Array accessor |
| `Concurrent(ts)` | STDLIB (058-010) | Bundle(ts) | Temporal co-occurrence |
| `Set(ts)` | STDLIB (058-027) | Bundle(ts) | Data-structure: unordered collection |

Array and Sequential share an expansion; Concurrent and Set share an expansion. Four data-structure-ish stdlib forms, two underlying encodings, distinguished by reader intent.

## Algebraic Question

Does Array compose with the existing algebra?

Trivially — it IS Sequential. All downstream operations work.

Is it a distinct source category?

No. Stdlib alias.

## Simplicity Question

Is this simple or easy?

Simple. One-line expansion.

Is anything complected?

The alias pair (Array ≡ Sequential) risks confusion. Mitigated by clear intent-distinction documentation.

Could existing forms express it?

Yes — directly via Sequential. Named form earns its place via data-structure reader intent.

## Implementation Scope

**Zero Rust changes.** Pure wat.

**wat stdlib addition** — `wat/std/structures.wat`:

```scheme
(define (Array thoughts)
  (Sequential thoughts))

(define (nth array-thought index candidates)
  (cleanup (Permute array-thought (- 0 index)) candidates))

(define (nth-raw array-thought index)
  (Permute array-thought (- 0 index)))
```

## Questions for Designers

1. **Array vs Sequential: keep both or unify?** Same expansion, different reader intents. Recommendation: keep both; the intent distinction is real in vocab code.

2. **Accessor naming.** `nth` is Lisp-idiomatic for positional retrieval. Alternative: `get-at`, `index`, `[]`-style operator. Recommendation: `nth` — matches Lisp tradition.

3. **Negative indices (from end).** Python-style `arr[-1]` for last element. Would require knowing the array length at retrieval time (not directly in the encoded AST without metadata). Explicit positive indices only, for now.

4. **Bounds checking.** `(nth arr 999)` when arr has 4 elements — what happens? Unbind-then-cleanup will return a noisy vector that may still match some candidate, producing an incorrect result. Document as user responsibility; consider a `nth-safe` variant that requires length metadata.

5. **Array length.** Can an encoded Array expose its length? Not directly — the length is not in the encoding unless deliberately added. A `(pair length array-ast)` pattern might be needed for bounds-checked access. Future work.

6. **2D Array (tables).** `Array` of `Array` works but is awkward. A first-class 2D table structure might be a useful stdlib addition later. Out of scope for this proposal.

7. **Dependency on 058-009-sequential-reframing.** If Sequential stays as a variant (reframing rejected), Array's definition unfolds to the expanded Bundle+Permute directly. Resolution order: 058-009 first, then this proposal aligns.
