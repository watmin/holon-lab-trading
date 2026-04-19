# 058-026: `Vec` — Stdlib Integer-Keyed HashMap

> **STATUS: SUPERSEDES the original `Vec` proposal** (2026-04-18 Rust-surface naming sweep).
>
> The form previously called `Array` is now named `Vec` — matching Rust's `std::vec::Vec` directly. The wat UpperCase constructor, the type annotation `:Vec<T>`, and the runtime backing all share one name. One name per concept across algebra, type annotation, and runtime.
>
> **Also:** `nth` is retired. Use `get` — `(get my-vec i)` with an integer index returns `:Option<Holon>`.

**Scope:** algebra
**Class:** STDLIB (runtime constructor building a HashMap with integer keys)
**Parent:** 058-ast-algebra-surface
**Foundation:** ../FOUNDATION.md
**Depends on:** 058-016-map (now HashMap), 058-021-bind, 058-003-bundle-list-signature
**Companion proposals:** 058-027-set (now HashSet)
**Supersedes:** earlier framing of Array as "Sequential alias" — dropped; see Reclassification Note

---

## HISTORICAL CONTENT — SUPERSEDED BY BANNER ABOVE

The sections below were written before the 2026-04-18 rename + `get`-unification sweep. They reference `nth` as the accessor and describe an earlier Sequential-alias encoding. **Both are REPLACED.** `nth` is retired — use `get` with an integer index, returning `:Option<Holon>` through the runtime's Rust `Vec<T>` backing. The banner at the top of this file is authoritative; the content below is preserved as audit record only.

---

## Reclassification Note

Earlier drafts proposed Array as a macro alias for `Sequential` (the positional-encoding primitive). During round-2 designer review, the builder noticed that when we have the AST, we don't need cleanup-based retrieval for a data structure. Integer-keyed containers use exact lookup via the HashMap's runtime backing — the same mechanism as HashMap's `get` — and don't need the Sequential encoding at all.

**Vec is now a stdlib constructor that produces a HashMap with integer keys.** Sequential (058-009) stays as a separate primitive for a different purpose: positional encoding where similarity reflects order. Vec is the DATA STRUCTURE (Rust's `Vec<T>`); Sequential is the SIMILARITY ENCODING. Different tools, different uses.

## The Candidate

A wat stdlib function that builds an integer-keyed Map from a list of Holons:

```scheme
(:wat::core::define (:wat::std::Vec (items :Vec<Holon>) -> :Holon)
  (:wat::algebra::Bundle
    (map-with-index
      (:wat::core::lambda ((item :Holon) (i :usize) -> :Holon)
        (:wat::algebra::Bind (:wat::algebra::Atom i) item))
      items)))
```

Expands at call time to: `(:wat::algebra::Bundle (:wat::core::vec (:wat::algebra::Bind (:wat::algebra::Atom 0) items[0]) (:wat::algebra::Bind (:wat::algebra::Atom 1) items[1]) ...))`. The integer at each position is the KEY atom; each item is bound to its index.

### Semantics

`Vec` produces a Holon that is structurally a Map — a Bundle of Bind pairs — where the keys are integer atoms `0, 1, 2, ...`. There is NO positional encoding via permutation; there is NO similarity-preserved order. The resulting Holon is a data structure with random-access-by-integer-key.

**Every operation is AST walking.** No cleanup required. No similarity measurement for exact access.

```scheme
;; Build an array:
(:wat::core::define :my::app::fruits
  (:wat::std::Vec (:wat::core::vec apple banana cherry date)))

;; fruits' AST is structurally:
;;   (:wat::algebra::Bundle (:wat::core::vec (:wat::algebra::Bind (:wat::algebra::Atom 0) apple)
;;                 (:wat::algebra::Bind (:wat::algebra::Atom 1) banana)
;;                 (:wat::algebra::Bind (:wat::algebra::Atom 2) cherry)
;;                 (:wat::algebra::Bind (:wat::algebra::Atom 3) date)))
```

### `nth` retired

`nth` was redundant with the unified `get` introduced in the 2026-04-18 sweep. Use `get` directly:

```scheme
(:wat::std::get my-vec 3)                 ;; returns :Option<Holon>
;; equivalent to the old (:wat::std::nth my-vec 3)
```

`get` with a `:usize` locator goes through the Vec's Rust `Vec<Holon>` backing for O(1) indexing. Returns `(Some v)` at valid indices, `:None` out of range. Same signature as `get` on HashMap (hash lookup) and HashSet (hash membership). One name, three containers.

### Other operations

All expressible through the Map API:

```scheme
;; Append (cheap — new integer key is just count(arr))
(:wat::core::define (:wat::std::append (arr :Holon) (item :Holon) -> :Holon)
  (assoc arr (:wat::algebra::Atom (:wat::std::count arr)) item))

;; Redefine at index (moderate — AST walk to find and replace)
(:wat::core::define (:wat::std::set-at (arr :Holon) (i :usize) (v :Holon) -> :Holon)
  (assoc arr (:wat::algebra::Atom i) v))

;; Remove at index (moderate — AST walk to remove)
(:wat::core::define (:wat::std::remove-at (arr :Holon) (i :usize) -> :Holon)
  (dissoc arr (:wat::algebra::Atom i)))

;; Count
(:wat::core::define (:wat::std::count (arr :Holon) -> :usize)
  (map-count arr))                  ; number of Bind nodes in the Bundle
```

### Front-insert: expensive but supported

Inserting at position 0 requires **renumbering every existing entry** — each current key `i` becomes `i + 1`, then the new item gets key `0`. The identity of every existing binding changes (different key atom), so the old bindings are removed and new ones are added.

```scheme
(:wat::core::define (:wat::std::cons-front (arr :Holon) (item :Holon) -> :Holon)
  (:wat::core::let ((n (:wat::std::count arr)))
    ;; Step 1: collect all existing items with their old keys
    ;; Step 2: rebuild the array with keys shifted by 1 and the new item at key 0
    (:wat::std::Vec (:wat::core::cons item
                 (:wat::core::map (:wat::core::lambda ((i :usize) -> :Holon) (:wat::std::get arr (:wat::algebra::Atom i)))
                      (range n))))))
```

**Cost: O(N).** Every binding is rebuilt. This is the structural cost of a data structure that doesn't reserve space at the front.

**Recommendation: don't use `cons-front` in hot paths.** Prefer `append` (O(1)-ish — just a new Bind added). When you need front-insertion frequently, use a different data structure that's designed for it (a future `:Deque` or similar, or reverse the convention so the "front" is the high-key end).

### Why this is a runtime function, not a macro

Array's argument is a `:Vec<Holon>` — a runtime list, potentially unbounded. The macro expansion would need to iterate the list at parse time to generate `Bind(Atom 0, x_0)`, `Bind(Atom 1, x_1)`, etc. — but the list might be computed from runtime data. Macros run at parse time on the source AST only; they can't enumerate a runtime list.

So Array is a RUNTIME FUNCTION. It produces a Holon (a Bundle-of-Binds) at runtime from the given list. The Holon has exact AST structure; subsequent accesses walk that structure.

If we wanted a compile-time Array macro for literal input (small known-at-parse-time lists), we could add one later as a separate form. Not needed for 058.

## Why Stdlib Earns the Name

**1. Array isn't algebraically distinct from Map.** It's a specific use of Map where keys happen to be integers. Same algebra; reader-intent naming.

**2. The stdlib criterion says:** if a form's expansion uses only core forms, and the name reduces ambiguity, it earns stdlib status. Array expands to Map (which expands to Bundle-of-Bind) via runtime enumeration. Uses only core. The name "Array" reads as "indexed collection" where "Map" reads as "named dictionary." Distinct reader intent.

**3. Sequential (058-009) stays separate.** Sequential is the similarity-preserving positional encoding. Array is the data structure. Not aliases; different purposes.

## Arguments For

**1. Uses only existing primitives.** No new algebra needed — Array is Bind + Bundle + an enumeration helper.

**2. AST-walkable access.** No cleanup. No similarity measurement. Exact get/set via the AST.

**3. Honest about cost.** Front-insertion is expensive; document it. Append is cheap; it's the natural operation.

**4. Matches Clojure's vector / Rust's Vec / Python's list semantics.** Programmers from those languages understand it instantly.

## Arguments Against

**1. Array and Map look almost identical at the call site.**

`(Array items)` constructs integer-keyed; `(Map kv-pairs)` constructs arbitrary-keyed. The underlying Holon structure is the same family (Bundle of Binds). Readers must know which form to use based on whether they care about integer keys vs. arbitrary keys.

**Counter:** the distinction IS meaningful — integer-keyed collections are a common case with their own operations (nth, append). A separate name for the common case is worth it.

**2. Front-insert cost is a gotcha.**

Programmers used to linked-list front-insert (O(1)) will be surprised by O(N) cost.

**Counter:** document it prominently; guide users toward `append`. If front-insert patterns are common, a future Deque primitive handles them efficiently.

**3. Array of Arrays gets nested; cost of nested access compounds.**

`(nth (nth matrix row) col)` is O(N_row + N_col) AST walks. For large matrices, not efficient.

**Counter:** for large multi-dimensional data, a proper matrix representation (a single Map keyed by (row, col) pairs, or a dedicated tensor type) is appropriate. Array handles small indexed collections natively.

## Comparison

| Form | Expansion | Access path | Ordering |
|---|---|---|---|
| `Array(items)` | Bundle of `Bind(Atom i, item_i)` for i in 0..N | `get arr (Atom i)` — AST walk | Keys are integers; no inherent ordering in the Bundle |
| `Map(kv-pairs)` | Bundle of `Bind(k, v)` per pair | `get map k` — AST walk | Keys are any atoms; no inherent ordering |
| `Sequential(items)` | Bundle of `Permute(item_i, i)` for each i | Inverse permutation + cleanup | Positionally encoded; similarity reflects order |
| `Set(items)` | `(Bundle items)` | `cosine set query` — similarity | Unordered; membership test |

**Array and Map share a structure (Bundle of Binds); they differ only in what keys are used.** Sequential and Set are fundamentally different encodings with different access patterns.

## Algebraic Question

Does Array compose with the existing algebra?

Trivially — it IS Map, so every Map operation works on Array.

Is it a distinct source category?

No — it is a specialization of Map with a naming convention. Stdlib.

## Simplicity Question

Is this simple or easy?

Simple. One constructor function. Operations delegate to Map. No new algebraic content.

Is anything complected?

No. Array has one role ("integer-indexed collection"), one construction path, one access mechanism (AST walk via Map's get).

## Implementation Scope

**Zero Rust changes.** Pure wat stdlib.

**wat stdlib addition:**

```scheme
;; wat/std/structures.wat (or similar)

(:wat::core::define (:wat::std::Vec (items :Vec<Holon>) -> :Holon)
  (:wat::algebra::Bundle
    (map-with-index
      (:wat::core::lambda ((item :Holon) (i :usize) -> :Holon)
        (:wat::algebra::Bind (:wat::algebra::Atom i) item))
      items)))

(:wat::core::define (:wat::std::nth (arr :Holon) (i :usize) -> :Option<Holon>)
  (:wat::std::get arr (:wat::algebra::Atom i)))

(:wat::core::define (:wat::std::append (arr :Holon) (item :Holon) -> :Holon)
  (assoc arr (:wat::algebra::Atom (:wat::std::count arr)) item))
```

Ships as wat code once `define`, `lambda`, Bundle/Bind/Atom/Map/get are in.

## Questions for Designers

1. **Is Array worth a named stdlib form, or should users just call `Map` with integer keys directly?** This proposal argues yes — the common-case naming ergonomics justify the separate name. But it IS reader-intent naming on top of Map; pure primitive minimalists could reject it.

2. **Front-insertion policy.** This proposal supports `cons-front` with O(N) cost. Should we:
   - (a) Document the cost prominently but provide the operation (current proposal — "you can but shouldn't")
   - (b) Refuse to provide it; users write their own if they need it
   - (c) Provide a Deque primitive that supports efficient front-insert and rename this structure

   Recommendation: (a) matches the user's direction — "append to front IS possible.. you gotta eat the cost... we can support it."

3. **Should `Vec` be a reserved naming convention for integer-keyed Maps, or just a stdlib function?** If the former, it becomes a linter convention ("if keys are integers, use `Vec`"). If the latter, it's just one possible way to construct an integer-keyed Map.

4. **Relationship to `Sequential` (058-009).** These are NOT aliases anymore. Sequential is positional encoding; Array is integer-keyed Map. Vocab modules pick based on need: Sequential when similarity should reflect position, Array when random-access-by-integer is the goal.

5. **Front-insert alternatives — a future `Deque`?** Not proposed here. When the trading enterprise or other application shows a need for efficient front-insert, propose Deque as a separate primitive. Until then, Array-with-O(N)-front-insert is documented and supported.

6. **`count` implementation.** `(count arr)` returns the number of Bind nodes in the Bundle. This walks the AST (O(N)). Is that acceptable, or should we carry a `:count` metadata on the Bundle's AST node?

   Recommendation: start without metadata; add if performance demands it.
