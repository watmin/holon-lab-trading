# 058-025: `Cleanup` — Core Primitive Affirmation

**Scope:** algebra
**Class:** CORE (existing primitive — this proposal affirms)
**Parent:** 058-ast-algebra-surface
**Foundation:** ../FOUNDATION.md

## The Candidate

`Cleanup` is the similarity-based retrieval primitive — given a noisy vector and a codebook of candidates, it returns the candidate most similar to the input.

```scheme
(Cleanup noisy-vector candidates)
```

Two arguments: a vector (typically from Unbind or Analogy or other decode operation) and a LIST of candidate vectors. Returns the candidate most similar to the noisy input (or a sorted/ranked list of candidates in some variants).

### Operation

```
Cleanup(v, candidates) = argmax_{c in candidates} similarity(v, c)
```

Where `similarity` is typically cosine similarity (dot product of normalized vectors) or Hamming distance (for dense-bipolar vectors). The specific similarity metric is an implementation choice; the algebraic role is "retrieve the closest candidate." Per FOUNDATION's "Output Space" section, cosine similarity naturally handles ternary inputs — zero positions contribute zero to the dot product.

### Why it is needed

VSA encoding is LOSSY in the composite — `Bundle`, `Bind` on ternary, `Orthogonalize` all produce vectors where the original operands are only APPROXIMATELY recoverable. Decode operations (Unbind, Difference, Analogy) return NOISY versions of the decoded thought. To ACTUALLY get back a clean thought, the noisy decode must be matched against a codebook of known clean vectors.

That matching is Cleanup.

### AST shape (already exists in holon-rs)

```rust
pub enum ThoughtAST {
    // ... other variants ...
    Cleanup(Arc<ThoughtAST>, Arc<Vec<ThoughtAST>>),
    // or similar — the second argument is a list of candidates
}
```

Current holon-rs exposes cleanup as a library function. Whether it needs a ThoughtAST variant or stays as a runtime function is a design question (see Question 3 below).

## Why This IS Core

**1. Cleanup cannot be expressed in Bind + Bundle + Permute + Atom + Thermometer alone.**

Bind, Bundle, Permute are DETERMINISTIC combiners — they compute a vector from inputs but do not rank/compare vectors. Atom and Thermometer are PRIMITIVE encoders. None of them perform similarity-based selection.

Cleanup is the primitive that introduces SIMILARITY-DRIVEN SELECTION to the algebra. It is the only operation that compares a query vector to a set of known vectors and returns the best match.

**2. It is the decode completion of the algebra.**

Bind encodes; Unbind decodes (to a noisy vector). Bundle encodes many; there is no analogous "unbundle" — instead, Cleanup against the component codebook extracts each component. Analogy produces a noisy completion; Cleanup grounds it to a known answer.

Without Cleanup, decode operations return UNGROUNDED NOISE — vectors that are "near" the right answer but not crisply one of the known answers. The algebra's retrieval story is incomplete.

**3. Every nontrivial VSA retrieval relies on Cleanup.**

- Dictionary lookup (`get` in 058-016-map): Unbind + Cleanup
- Array indexing (`nth` in 058-026-array): Permute + Cleanup
- Analogy completion (058-014): `Bundle(...)` + Cleanup
- Anomaly classification: noise vector compared to prototype library via Cleanup
- Engram matching: incoming pattern compared to learned engrams via Cleanup

Remove Cleanup and the algebra has no grounded retrieval. The holon-rs stdlib is full of cleanup-based retrievals; vocab modules consume them constantly.

**4. MAP VSA tradition.**

Cleanup memory is a classical VSA concept (Kanerva, Plate, Eliasmith). It is the "auto-associative" retrieval mechanism that makes VSA cognitive — the connection between noisy activations and crisp concepts.

Any VSA worth the name provides a cleanup memory. Affirming Cleanup as core matches decades of convention.

## Arguments For Core Status

**1. Foundational to the memory hierarchy.**

FOUNDATION describes five cache tiers (L1-L5). L3/L4 are ENGRAM caches — populations of learned vectors that serve as cleanup codebooks. Cleanup is the OPERATION that interacts with these caches; it is the query mechanism that makes the memory hierarchy useful.

Without Cleanup as core, the memory hierarchy is a bunch of cached vectors with no way to QUERY them for the nearest match.

**2. Well-understood complexity.**

Naive Cleanup against `k` candidates is `O(k · d)` — one dot product per candidate. For small codebooks (a few hundred), this is fast. For large codebooks, engram caching (L3/L4) with eigenvalue prefiltering (per challenge 018) reduces to near-constant time.

The operation is algebraically primitive but computationally well-studied.

**3. Similarity is a first-class algebraic concept.**

"How similar are these two vectors" — via cosine similarity or dot product — is the only way the algebra has to compare thoughts. Every decision in VSA (classification, ranking, retrieval) eventually reduces to a similarity comparison. Cleanup is the batched form of this comparison.

## Arguments Against Removing or Reframing

This is affirmation. Could Cleanup be reframed?

Candidates:
- **Stdlib over a more primitive `Similarity` operation?** A `Similarity(v, u)` primitive that returns a scalar is more granular. Cleanup becomes stdlib as `argmax(map(Similarity(query), candidates))`. This splits a compound operation into scalar + aggregation.
- **Stdlib over `Nearest(v, candidates)` from a library?** If `Nearest` is a library function without algebraic status, Cleanup just names it.

The first reframing IS cleaner. It exposes Similarity as the primitive and makes Cleanup a specific aggregation (argmax) over it. But:
- Similarity needs to be accepted first (no current proposal).
- All existing VSA literature treats Cleanup as primitive.
- Cleanup's contract (take query + codebook, return best match) is stable and useful even if Similarity is factored out later.

Affirming Cleanup as core NOW, with a future proposal to split it into Similarity + stdlib-Cleanup, is a reasonable progression. This proposal leaves that decomposition as a Question for designers.

## Comparison

| Primitive | Inputs | Output | Role |
|---|---|---|---|
| `Bind(a, b)` | two vectors | one vector | Reversible combination |
| `Bundle(xs)` | list of vectors | one vector | Superposition |
| `Permute(v, k)` | vector, int | one vector | Positional distinction |
| `Atom(literal)` | literal | one vector | Literal encoding |
| `Thermometer(atom, dim)` | atom, int | one vector | Scalar gradient |
| `Cleanup(v, candidates)` | vector, list of vectors | one vector (best match) | Similarity retrieval |

Cleanup is the only CORE primitive that TAKES a LIST of candidates and returns a SELECTION. It is algebraically distinct from all others.

## Algebraic Question

Does Cleanup compose with the existing algebra?

Yes. Input is a noisy vector (from decode operations) and a list of clean vectors (encoded via Atom / Bundle / etc.). Output is a vector (or vector-plus-metadata in some variants). Downstream operations work on the output.

Is it a distinct source category?

Yes. "Similarity-based retrieval" is categorically unique. No other core form performs selection.

## Simplicity Question

Is this simple or easy?

Simple in role: "return the best match." Implementation is well-known (naive O(k·d), or eigen-prefiltered for large codebooks).

Is anything complected?

Potentially. Cleanup bundles:
- Similarity computation (the scoring mechanism)
- Argmax / ranking (the aggregation mechanism)
- Return format (single vector, list of vectors, ranked with scores)

A future proposal could decompose these concerns: `Similarity` as primitive, `Argmax` as stdlib aggregator, `Cleanup` as the specific combination. For now, Cleanup is kept as one primitive — the decomposition is a followup question.

Could existing forms express it?

Not without introducing Similarity as a new primitive. Currently, Cleanup is the only algebra-level operation that compares vectors.

## Implementation Scope

**Zero changes.** Cleanup exists in current holon-rs. This proposal affirms the existing implementation.

**For documentation completeness:**

```rust
pub fn cleanup(query: &Vector, candidates: &[Vector]) -> Option<&Vector> {
    candidates.iter()
        .max_by(|a, b| similarity(query, a).partial_cmp(&similarity(query, b)).unwrap())
}
```

For large codebooks, eigen-prefiltering and engram-library acceleration are used (see challenge 018 for details).

## Questions for Designers

1. **Is this proposal needed?** Cleanup's core status is universally accepted. Leaves-to-root completeness argues for a doc. Recommendation: accept this doc as affirmation; it clarifies Cleanup's algebraic role even though no change is made.

2. **Should Cleanup decompose into `Similarity` + `Argmax`?** A future proposal could split Cleanup into the scalar similarity primitive and the aggregation over candidates. Pros: cleaner layering, more composable. Cons: changes a well-known primitive's signature. Recommendation: defer to a future proposal; affirm Cleanup as-is for now.

3. **Cleanup as AST variant vs. library function.** Currently holon-rs exposes Cleanup as a library function. Should it also be a ThoughtAST variant (so ASTs can contain Cleanup nodes, and caching applies)? Most cleanup calls are AT RESULT TIME, so AST embedding may not be necessary. But for expressible-in-AST patterns, variant status helps. Design question.

4. **Return type.** Cleanup returns THE best match, or a ranked list, or match-with-score. Different variants in different contexts. Should there be multiple Cleanup forms (`Cleanup`, `CleanupRanked`, `CleanupWithScore`), or one with an options parameter? Recommendation: one primitive returns the match; stdlib `CleanupRanked` and similar are extensions.

5. **Similarity metric convention.** Cosine similarity vs. Hamming distance vs. Euclidean distance. The conventional choice is cosine for continuous ternary, Hamming for bitwise dense-bipolar. Document the convention; stdlib may expose named-alternative cleanups (e.g., `HammingCleanup`) if needed. (Cosine handles ternary inputs cleanly per FOUNDATION's "Output Space" section.)

6. **Codebook preprocessing.** Cleanup's performance scales with codebook size. For large codebooks (>10k candidates), eigenvalue-prefiltering (challenge 018) is used. Should this preprocessing be part of the Cleanup contract (always happen), or opt-in? Design choice; likely opt-in via engram libraries.

7. **Relationship to engrams.** Engram caches (L3/L4 per FOUNDATION) are optimized Cleanup targets. Is `EngramCleanup` a distinct stdlib form, or is Cleanup polymorphic over vector-list vs. engram-library candidates? Recommendation: polymorphic — one primitive, multiple acceleration paths.
