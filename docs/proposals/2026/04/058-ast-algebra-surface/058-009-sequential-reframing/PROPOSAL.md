# 058-009: `Sequential` — Reframe as Pure Stdlib

**Scope:** algebra
**Class:** STDLIB (reclassification from current CORE variant)
**Parent:** 058-ast-algebra-surface
**Foundation:** ../FOUNDATION.md

## Reclassification Claim

The current `HolonAST` enum has a `Sequential(Vec<HolonAST>)` variant. FOUNDATION's audit lists it as "CORE (grandfathered)" — acknowledging that it is expressible via existing primitives (Bundle + Permute) but has been preserved for historical reasons.

This proposal argues that the grandfathering should end. `Sequential` should be a pure stdlib macro (per 058-031-defmacro) expanding to a specific Bundle-over-Permute composition, with NO corresponding HolonAST variant.

## The Reframing

`Sequential(list-of-holons)` is position-encoded bundling: each holon `t_i` at position `i` is permuted by `i` steps, and the permuted holons are bundled.

```scheme
(:wat/core/defmacro (:wat/std/Sequential (holons :AST) -> :AST)
  `(:wat/algebra/Bundle
     (map-with-index
       (:wat/core/lambda (t i) (:wat/algebra/Permute t i))
       ,holons)))
```

Or, thought of with explicit index iteration:

```scheme
;; conceptual unrolling of the emitted expansion for a known-length list:
(:wat/algebra/Bundle
  (:wat/core/list (:wat/algebra/Permute (:wat/std/nth holons 0) 0)
        (:wat/algebra/Permute (:wat/std/nth holons 1) 1)
        (:wat/algebra/Permute (:wat/std/nth holons 2) 2)
        ...))
```

Where `(Permute t 0)` is a no-op (identity permutation), so the first element passes through unchanged; the second is permuted once; the third twice; and so on. `map-with-index` is a regular runtime stdlib function, not a macro — it iterates the list at vector-evaluation time inside the expanded form. The `Sequential` macro itself only emits the canonical `(Bundle (map-with-index ...))` shape.

### Semantics

The permutation by position makes dimension-i distinguishable from dimension-j: two sequences that contain the same items in different orders produce different vectors. This is the "positional signature" of the list.

## Why This Reframing Earns Stdlib Status

**1. It is trivially expressible in existing primitives.**

`Bundle` is core. `Permute` is core. `map-with-index` is a generic Lisp-ish combinator (or a wat-level loop). Their combination is the entire definition of Sequential. No new algebraic capability is introduced.

The only reason Sequential was ever a variant is optimization: avoid building an intermediate list, just dispatch directly to a specialized encoder. That is an implementation concern, not an algebraic truth.

**2. FOUNDATION's criterion ("CORE = new algebraic operation") fails.**

A form that decomposes into `Bundle(map Permute)` is not introducing a new algebraic operation — it is composing two existing operations. Under FOUNDATION's criterion, it belongs in stdlib.

The grandfathering was historical courtesy, not principled classification. Removing the grandfather clause makes the audit honest.

**3. The stdlib form is more useful than the variant.**

As a stdlib macro, Sequential is visible in the wat source, inspectable, extensible:

```scheme
;; user can define related macros:
(:wat/core/defmacro (:my/vocab/ReverseSequential (holons :AST) -> :AST)
  `(:wat/std/Sequential (reverse ,holons)))

(:wat/core/defmacro (:my/vocab/SequentialFromN (start :AST) (holons :AST) -> :AST)
  `(:wat/algebra/Bundle (map-with-index (:wat/core/lambda (t i) (:wat/algebra/Permute t (:wat/core/+ i ,start))) ,holons)))
```

As a variant, Sequential's behavior is hidden in Rust encoder dispatch. Users can't trivially produce related forms without compiling new Rust.

**4. Removing the variant shrinks the AST.**

One less variant to pattern-match, one less cache-key discriminator, one less case for AST-walking code. Small win but real — and consistent with the direction of the scalar-encoder reframings in 058-008/017/018 (reduce variants, grow stdlib).

## Arguments Against

**1. Performance.**

Currently `Sequential(holons)` dispatches to a specialized Rust encoder that computes the result in one pass. The stdlib form builds an intermediate list (`map-with-index` output), then passes it to `Bundle`, which then iterates. Two passes minimum.

**Mitigation:**
- The intermediate list has `O(k)` entries for `k` holons (not `O(d)` — each entry is a small HolonAST, not a vector). The overhead is bounded.
- The ACTUAL vector-level work is identical: for each of `k` holons, encode, permute by `i`, accumulate into running sum, threshold at end. Whether this is driven by one specialized encoder or by macro-emitted primitives, the vector ops are the same.
- Macro-emitted Bundle can cache each permuted holon independently. Specialized Sequential encodes everything in one shot and caches only the final result. The macro version has FINER-GRAINED cache — better reuse when two Sequentials share sub-sequences.

**2. Loss of semantic name in AST — resolved by parse-time expansion.**

A `Sequential([a, b, c])` AST node clearly reads as "this is a sequence." Under `defmacro`, the parse-time expansion replaces the `Sequential` node with the canonical `Bundle(map-with-index ...)` form BEFORE hashing. The hashed AST sees only the canonical shape — this is the intended behavior; it means `hash((Sequential xs)) = hash((Bundle (map-with-index ... xs)))`, closing finding #4 for this alias alongside the others.

**Mitigation:** source-level tooling (formatters, error messages) preserves the pre-expansion `Sequential(...)` form via source maps. This is a standard Lisp-macro tooling concern. Consistent with the treatment of Linear/Log/Circular/Concurrent macro reframings.

**3. Grandfathering exists for a reason.**

Historical code, tests, and examples use `Sequential` as a variant. Removing it is a breaking change to the Rust enum.

**Mitigation:** migration is mechanical — replace variant pattern matches with macro expansions at parse time. Any existing `wat` code that writes `(Sequential ...)` keeps working (the name just resolves to the macro at parse time instead of a variant match at eval time). Rust code that constructs `HolonAST::Sequential(...)` directly must change to construct the expanded Bundle/Permute form, OR route the construction through the wat macro-expansion pass.

## Comparison to Related Reframings

| Form | Status before 058 | Status after 058 | Expansion |
|---|---|---|---|
| `Linear(...)` | CORE (variant) | STDLIB | Blend over Thermometers |
| `Log(...)` | CORE (variant) | STDLIB | Blend over Thermometers |
| `Circular(...)` | CORE (variant) | STDLIB | Blend over Thermometers |
| `Sequential(...)` | CORE (grandfathered variant) | STDLIB (this) | Bundle over Permutes |

All four are "variants that dispatch to a composition of other primitives." All four become stdlib. The variant enum shrinks by four.

## Algebraic Question

Does the reframing break the algebra?

No. Sequential's semantics are unchanged — the expansion produces byte-for-byte identical vectors. All downstream operations continue to work.

Is it a distinct source category?

No. Sequential is a composition of Bundle and Permute with index-based parameterization. It is an IDIOM, not a primitive.

## Simplicity Question

Is this simple or easy?

Simpler. One less variant. The operation's structure (Bundle of indexed Permutes) is made explicit rather than hidden behind a variant name.

Is anything complected?

Removes a small complection: the variant mixes "this is a positional composition of holons" with "I dispatch to a specialized encoder." Separating them puts the operation in stdlib (where it belongs) and leaves the encoder general-purpose.

Could existing forms express it?

Yes — this is the entire claim. `Bundle` + `Permute` + `map-with-index` is sufficient.

## Implementation Scope

**holon-rs changes** — remove the variant:

```rust
pub enum HolonAST {
    // remove: Sequential(Vec<HolonAST>),
    // keep everything else
}
```

Delete the Sequential encoder match arm (~15-20 lines including tests).

**wat stdlib addition** — one macro, ~5 lines:

```scheme
;; wat/std/sequences.wat (or equivalent)
(:wat/core/defmacro (:wat/std/Sequential (holons :AST) -> :AST)
  `(:wat/algebra/Bundle
     (map-with-index (:wat/core/lambda (t i) (:wat/algebra/Permute t i)) ,holons)))
```

Registered at parse time (per 058-031-defmacro): every `(Sequential ...)` invocation is rewritten to the canonical `(Bundle (map-with-index ...))` form before hashing. `map-with-index` itself remains a regular runtime list combinator, not a macro.

**Other stdlib forms that currently delegate to Sequential variant:**

- `Chain`, `Ngram`, `Concurrent`, and similar list-operating stdlib macros that internally call Sequential (per 058-010, 058-012, 058-013) remain unchanged — they emit `(Sequential ...)` in their expansions, which in turn expands in the same parse-time pass to the canonical Bundle-over-Permute form.
- `Array` (058-026) uses Sequential internally for indexed encoding and keeps working transparently — its macro expansion emits `(Sequential ts)`, which is further expanded by the same pass.

## Questions for Designers

1. **Does `map-with-index` exist in the wat stdlib?** The expansion assumes a `map-with-index` combinator (or equivalent iteration primitive). If the wat stdlib does not yet have one, this proposal depends on its addition — either a proposal to add it, or folding the expansion to use explicit index arithmetic (less elegant but works without `map-with-index`).

2. **Is the permutation indexing 0-based or 1-based?** Convention here is 0-based (first element gets `Permute by 0` = identity). Some implementations might use 1-based. Pick one, document it.

3. **Should the AST preserve `Sequential` as a semantic name?** As with Linear/Log/Circular, preserving stdlib forms in AST walks keeps semantics visible. Cache keys can be on the stdlib form or on the expanded form. Decision should be consistent across all reframings.

4. **Relationship to `Array` (058-026).** Array is also an indexed list-of-holons form. Does Array's expansion internally rely on Sequential, or does Array have its own independent expansion? If Array uses Sequential, making Sequential stdlib is prerequisite for Array's stdlib form.

5. **Historical note: why was Sequential grandfathered?** Understanding why it was kept as a variant originally (perf? clarity?) helps decide if this reframing is the right call or if there's a forgotten reason for the special case. If the reason was just "we had it before we had Permute as a clean variant," grandfathering can end cleanly.
