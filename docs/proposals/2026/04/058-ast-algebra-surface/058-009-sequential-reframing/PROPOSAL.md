# 058-009: `Sequential` — Reframe as Pure Stdlib

**Scope:** algebra
**Class:** STDLIB (reclassification from current CORE variant)
**Parent:** 058-ast-algebra-surface
**Foundation:** ../FOUNDATION.md

## Reclassification Claim

The current `ThoughtAST` enum has a `Sequential(Vec<ThoughtAST>)` variant. FOUNDATION's audit lists it as "CORE (grandfathered)" — acknowledging that it is expressible via existing primitives (Bundle + Permute) but has been preserved for historical reasons.

This proposal argues that the grandfathering should end. `Sequential` should be a pure stdlib function expanding to a specific Bundle-over-Permute composition, with NO corresponding ThoughtAST variant.

## The Reframing

`Sequential(list-of-thoughts)` is position-encoded bundling: each thought `t_i` at position `i` is permuted by `i` steps, and the permuted thoughts are bundled.

```scheme
(define (Sequential thoughts)
  (Bundle
    (map-with-index
      (lambda (t i) (Permute t i))
      thoughts)))
```

Or, written with explicit index iteration:

```scheme
(define (Sequential thoughts)
  (Bundle
    (list (Permute (nth thoughts 0) 0)
          (Permute (nth thoughts 1) 1)
          (Permute (nth thoughts 2) 2)
          ...)))
```

Where `(Permute t 0)` is a no-op (identity permutation), so the first element passes through unchanged; the second is permuted once; the third twice; and so on.

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

As a stdlib function, Sequential is visible in the wat source, inspectable, extensible:

```scheme
;; user can define variants:
(define (ReverseSequential thoughts)
  (Sequential (reverse thoughts)))

(define (SequentialFromN start thoughts)
  (Bundle (map-with-index (lambda (t i) (Permute t (+ i start))) thoughts)))
```

As a variant, Sequential's behavior is hidden in Rust encoder dispatch. Users can't trivially produce related forms without compiling new Rust.

**4. Removing the variant shrinks the AST.**

One less variant to pattern-match, one less cache-key discriminator, one less case for AST-walking code. Small win but real — and consistent with the direction of 058-008-scalar-encoder-reframings (reduce variants, grow stdlib).

## Arguments Against

**1. Performance.**

Currently `Sequential(thoughts)` dispatches to a specialized Rust encoder that computes the result in one pass. The stdlib form builds an intermediate list (`map-with-index` output), then passes it to `Bundle`, which then iterates. Two passes minimum.

**Mitigation:**
- The intermediate list has `O(k)` entries for `k` thoughts (not `O(d)` — each entry is a small ThoughtAST, not a vector). The overhead is bounded.
- The ACTUAL vector-level work is identical: for each of `k` thoughts, encode, permute by `i`, accumulate into running sum, threshold at end. Whether this is driven by one specialized encoder or by stdlib-invoked primitives, the vector ops are the same.
- Stdlib-invoked Bundle can cache each permuted thought independently. Specialized Sequential encodes everything in one shot and caches only the final result. The stdlib version has FINER-GRAINED cache — better reuse when two Sequentials share sub-sequences.

**2. Loss of semantic name in AST.**

A `Sequential([a, b, c])` AST node clearly reads as "this is a sequence." After reframing, the AST shape is `Bundle([Permute(a, 0), Permute(b, 1), Permute(c, 2)])`. Reader must recognize the pattern.

**Mitigation:** if stdlib forms are preserved in the AST (per 058-008 Question 2), the `Sequential(...)` form stays visible. Expansion happens only during vector computation. Same argument as Linear/Log/Circular.

**3. Grandfathering exists for a reason.**

Historical code, tests, and examples use `Sequential` as a variant. Removing it is a breaking change to the Rust enum.

**Mitigation:** migration is mechanical — replace variant pattern matches with stdlib function calls. Any existing `wat` code that uses `Sequential` as a stdlib form already keeps working (the name just resolves to the stdlib function instead of a variant match). Rust code that constructs `ThoughtAST::Sequential(...)` directly must change to construct the expanded Bundle/Permute form, OR invoke the stdlib via the wat interpreter.

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

Removes a small complection: the variant mixes "this is a positional composition of thoughts" with "I dispatch to a specialized encoder." Separating them puts the operation in stdlib (where it belongs) and leaves the encoder general-purpose.

Could existing forms express it?

Yes — this is the entire claim. `Bundle` + `Permute` + `map-with-index` is sufficient.

## Implementation Scope

**holon-rs changes** — remove the variant:

```rust
pub enum ThoughtAST {
    // remove: Sequential(Vec<ThoughtAST>),
    // keep everything else
}
```

Delete the Sequential encoder match arm (~15-20 lines including tests).

**wat stdlib addition** — one function, ~5 lines:

```scheme
;; wat/std/sequences.wat (or equivalent)
(define (Sequential thoughts)
  (Bundle
    (map-with-index (lambda (t i) (Permute t i)) thoughts)))
```

**Other stdlib forms that currently delegate to Sequential variant:**

- `Chain`, `Ngram`, `Concurrent`, and similar list-operating stdlib forms that internally call Sequential (if any exist in current wat) remain unchanged — they now invoke the stdlib Sequential rather than the variant, but the call site looks the same.
- `Array` (if it uses Sequential internally for indexed encoding) keeps working transparently.

## Questions for Designers

1. **Does `map-with-index` exist in the wat stdlib?** The expansion assumes a `map-with-index` combinator (or equivalent iteration primitive). If the wat stdlib does not yet have one, this proposal depends on its addition — either a proposal to add it, or folding the expansion to use explicit index arithmetic (less elegant but works without `map-with-index`).

2. **Is the permutation indexing 0-based or 1-based?** Convention here is 0-based (first element gets `Permute by 0` = identity). Some implementations might use 1-based. Pick one, document it.

3. **Should the AST preserve `Sequential` as a semantic name?** As with Linear/Log/Circular, preserving stdlib forms in AST walks keeps semantics visible. Cache keys can be on the stdlib form or on the expanded form. Decision should be consistent across all reframings.

4. **Relationship to `Array` (058-016).** Array is also an indexed list-of-thoughts form. Does Array's expansion internally rely on Sequential, or does Array have its own independent expansion? If Array uses Sequential, making Sequential stdlib is prerequisite for Array's stdlib form.

5. **Historical note: why was Sequential grandfathered?** Understanding why it was kept as a variant originally (perf? clarity?) helps decide if this reframing is the right call or if there's a forgotten reason for the special case. If the reason was just "we had it before we had Permute as a clean variant," grandfathering can end cleanly.
