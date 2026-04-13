# Review: Hickey
Verdict: CONDITIONAL — Sequential should not be an AST variant.

## The proposal

The domain content is strong. Pivot biographies, portfolio state,
the series of relationships between consecutive pivots — this is
good data modeling. The vocabulary additions are clean extensions
of what already exists. I have no objections there.

My review concerns only the algebraic question: should `Sequential`
be a seventh AST variant?

No.

## 8. Sequential as AST form

The ThoughtAST has six variants. The first four are leaves — Atom,
Linear, Log, Circular. They name things in the world. The last two
are combinators — Bind and Bundle. They compose things. Every
variant earns its place because it does something the others cannot.

- Atom: a named identity vector. Irreducible.
- Linear/Log/Circular: scalar encoding modes. Each has distinct
  geometry (linear interpolation, logarithmic compression, phase
  rotation). You cannot express Log in terms of Linear. They are
  genuinely different operations.
- Bind: role-filler association. XOR-like. Reversible. Structural.
- Bundle: superposition. Majority vote. Unordered composition.

Now: `Sequential(Vec<ThoughtAST>)`. What does it do? It permutes
each child by its index, then bundles. That is: `Bundle` of
`permute(child, i)` for each `i`. The proposal says this plainly.

The question is whether "order matters" deserves a slot in the AST,
or whether it belongs in the vocabulary that produces the AST.

It belongs in the vocabulary.

Here is why. Permute is a transformation on vectors. It is not a
new mode of composition. Bind composes two things into a structural
pair. Bundle composes N things into a superposition. Permute
*rotates a vector* — it is a unary operation, not a binary
combinator. Adding Sequential to the AST complects the concept of
"ordered collection" with the mechanism of "cyclic shift." If
tomorrow you want a different positional encoding — binding with
position atoms, n-gram windows, chained binding — you would need
another AST variant for each. The AST becomes a menu of encoding
strategies rather than a minimal algebra.

The desugared form is:

```rust
ThoughtAST::Bundle(
    pivots.iter().enumerate().map(|(i, pivot)| {
        // Bind the position atom to the pivot thought.
        // Position is data. The AST expresses it as data.
        ThoughtAST::Bind(
            Box::new(ThoughtAST::Atom(format!("pos-{}", i))),
            Box::new(pivot_thought(pivot)),
        )
    }).collect()
)
```

This uses only existing AST variants. It makes the positional
encoding explicit and visible. The position atoms are deterministic
— `pos-0`, `pos-1`, etc. — so they cache cleanly. The vocabulary
function that builds this is three lines. The intent is equally
visible: you see `pos-0` bound to the first pivot, `pos-1` bound
to the second. "This is ordered" is stated by the data, not by a
special form.

The permute approach and the bind-with-position-atom approach
produce different geometry. That is fine. The question is not
"which encoding is better" — measure that. The question is "should
the AST know about it." The AST should not. The AST is the
algebra. Permute is an encoding strategy. Strategies live in the
vocabulary.

If you want `permute` specifically — because you have measured it
and it outperforms position-atom binding — then the vocabulary
produces a helper function:

```rust
fn sequential(encoder: &ThoughtEncoder, items: Vec<ThoughtAST>) -> (Vector, Vec<CacheMiss>) {
    let mut vecs = Vec::new();
    let mut misses = Vec::new();
    for (i, item) in items.iter().enumerate() {
        let (v, m) = encoder.encode(item);
        vecs.push(Primitives::permute(&v, i as i32));
        misses.extend(m);
    }
    let refs: Vec<&Vector> = vecs.iter().collect();
    (Primitives::bundle(&refs), misses)
}
```

This is a function, not an AST node. It composes existing
primitives. It lives where the decision to use positional encoding
is made — in the vocabulary, not in the algebra. The encoder does
not need to know that order matters. The vocabulary knows. That is
the right place for this knowledge.

The proposal itself says: "Sequential is a composition of existing
primitives, not a new primitive. The algebra doesn't change." If
the algebra does not change, the AST should not change. The AST
IS the algebra.

## 9. Composability

Permuted elements compose cleanly with non-permuted elements in a
bundle. Permute is a cyclic rotation of the vector's components.
It produces a vector in the same space, with the same norm, but
orthogonal to the original (at sufficient dimension). Bundling
permuted vectors with non-permuted vectors is algebraically sound
— the majority vote does not care whether its inputs were rotated.

The concern is subtler. When the Sequential's output — a bundle of
permuted children — is itself bundled with other thoughts (trade
atoms, market extraction), the permuted components inside the
Sequential are already "inside" a bundle. The outer bundle sees one
vector. The positional structure is preserved within that vector
but is not extractable by the outer context. This is correct
behavior. The sequence is an opaque thought. The outer bundle
treats it as one contributor. No interference.

But: if the vocabulary produces explicit `Bind(pos-N, thought)`
pairs and bundles them alongside the trade atoms in a flat bundle,
then extraction can query individual positions. You can ask "what
was at position 3?" by unbinding `pos-3` from the thought vector.
With the permute approach, you cannot — permute is not reversible
via unbind. This is a real difference. The bind-with-position-atom
approach preserves queryability. The permute approach sacrifices it
for compactness.

Whether queryability matters depends on whether the system ever
needs to ask "what happened at the third pivot." If only the
reckoner sees the vector (as a whole, for similarity matching),
queryability is irrelevant and permute is fine. If extraction
ever needs positional decomposition, permute is the wrong
mechanism. Decide this based on the use case, not on which is
easier to type.

## 10. Caching

Cache each child independently. Recompute the permuted bundle when
the sequence shifts.

The children are pivot thoughts and gap thoughts. A pivot thought
is the same for its entire duration — it was computed when the
pivot was detected and does not change until the next pivot. The
cache already handles this: the ThoughtAST for a pivot thought is
identical across candles, so the encoder returns a cache hit. The
permuted bundle changes only when a new pivot arrives and the
window shifts — one new child enters, one old child exits, all
positions shift by one.

Caching the Sequential as a whole is wasteful. The whole-sequence
AST changes every time the window shifts (which is every new
pivot). The cache key is the entire `Sequential(Vec<...>)` — a
new key every time. Cache miss every time. No benefit.

Caching each child is natural. The children are stable. The
permute-and-bundle is cheap — it is N vector rotations and one
majority vote. At N=20 (10 pivots + 10 gaps) and 4096 dimensions,
this is roughly 80K element copies and one threshold pass. Under
a microsecond. Do not optimize what is already fast.

If you use the bind-with-position-atom desugaring instead, the
caching story is even cleaner. Each `Bind(pos-N, pivot_thought)`
is a distinct AST node that the existing cache handles
automatically. When the window shifts, the new bindings are new
AST nodes (cache miss, computed once, cached thereafter). The old
bindings that fell off the window are simply not queried and
eventually evicted. The existing machinery does exactly the right
thing without any special-case logic.

## Summary

The domain proposal is good. The vocabulary additions are
well-motivated. The AST extension is not. `Sequential` is sugar
that complects ordering strategy with algebraic structure. Keep
the AST minimal. Let the vocabulary compose the primitives it
already has. If permute is the right positional encoding, write a
function. If bind-with-position-atom is better, write that
function. Either way, it lives in the vocabulary, not the AST.

Simple is not easy. Six variants is simpler than seven. The
seventh does not earn its place because it does nothing the six
cannot express.
