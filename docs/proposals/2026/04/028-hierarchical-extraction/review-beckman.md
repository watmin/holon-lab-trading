# Review: Proposal 028 — Brian Beckman (revised with primer context)

**Verdict:** CONDITIONAL

---

## Assessment

I have now read the substrate carefully. Let me be precise about the actual
algebra, not a generic VSA abstraction.

**The MAP variant.** Holon uses bipolar vectors in {-1, 0, 1}. Bind is
element-wise multiplication — self-inverse because x·x = x² ∈ {0, 1} for
bipolar values, so bind(bind(A,B), A) = B (the squared role vector acts as
identity on the bound result). Bundle is element-wise majority vote over sums.
Cosine is standard inner product over norms.

**The fundamental encoding morphism.** For a JSON document with N leaf
key-value pairs:

```
encode({"k₁": v₁, ..., "kₙ": vₙ})
  = bundle(bind(role("k₁"), filler("v₁")),
           bind(role("k₂"), filler("v₂")),
           ...,
           bind(role("kₙ"), filler("vₙ")))
```

Each bound pair is approximately orthogonal to every other bound pair — this
is the Johnson-Lindenstrauss property at work. At D = 10,000, two random
bipolar vectors have cosine similarity distributed as N(0, 1/D), so the
standard deviation is 1/√10,000 = 0.01. With high probability, any two
distinct bound pairs are orthogonal to within ±0.03 (three sigma). This is
the geometric foundation on which the proposal's threshold claim rests.

**Now to the proposal's core operation.** The extraction algorithm computes:

```
cosine(thought_vec, encode(thought_ast))
```

where `thought_vec` is a bundle of N approximately-orthogonal components
(the thought after noise-stripping by the OnlineSubspace) and `encode(thought_ast)`
is the vector for one form in the vocabulary. Let's verify the expected value.

If the bundle is:

```
T = majority_vote(c₁, c₂, ..., cₙ)   where cᵢ = bind(role_i, filler_i)
```

then at D large, T ≈ (1/N)∑cᵢ as a float vector before thresholding
(each dimension is the sign of the mean). The cosine of T against a
specific present component cⱼ is:

```
cosine(T, cⱼ) ≈ cosine((1/N)∑cᵢ, cⱼ)
              = (1/N) · [cosine(cⱼ, cⱼ) + ∑_{i≠j} cosine(cᵢ, cⱼ)]
              ≈ (1/N) · [1 + (N-1)·0]
              = 1/N
```

But the proposal claims the threshold should be `1/√N`, not `1/N`. This
needs careful examination. The primer states: "expected cosine similarity 0,
standard deviation ~1/√d where d is dimensionality." That is for two
*independent random* vectors. But here cᵢ and cⱼ are components of T, not
independent of T.

The correct computation uses the fact that the bundle vector T has a
correlation with each present component cⱼ that is the superposition
contribution: roughly 1/N in expectation. The √N factor arises from
a signal-to-noise ratio argument, not the expected value itself. The
noise floor (what an absent component scores) is O(1/√(N·D)) due to the
JL cross-terms. The signal (a present component) scores O(1/N). The
signal-to-noise threshold that separates "present" from "absent" is thus
somewhere between 1/N and 1/√N depending on D and N.

At D = 10,000 and N = 100 (the typical market observer vocabulary), we have:

- Expected cosine of present component: ~1/100 = 0.01
- Noise floor (JL std dev for one cross-term): ~1/√10,000 = 0.01
- Expected magnitude of N-1 noise cross-terms combined: ~√(N-1)/√D ≈ 0.1

This analysis reveals a concern I did not raise in the prior review: **at
N=100 and D=10,000, the expected signal (0.01) is not clearly above the
noise floor (0.01)**. The `1/√N` threshold (= 0.1 at N=100) is actually
the correct *practical* threshold because it sits above the combined noise
floor of the cross-terms. The proposal's derivation is imprecise but arrives
at the right number. The derivation should say: `1/√N` is the expected
standard deviation of the combined cross-term noise for a bundle of N
components at large D — a present component that scores above this threshold
is genuinely distinguishable from noise, not just marginally above the
expected 1/N signal.

**Now the hierarchical descent is well-motivated given this analysis.** A
Bundle of N facts produces a vector whose components have cosine ~1/N against
the target. A sub-Bundle of k < N facts produces a vector whose components
have cosine ~1/k against the target. The threshold `1/√k` at the sub-Bundle
level is scale-appropriate. The hierarchical structure is not a heuristic —
it is the correct response to the capacity-scaling of the MAP bundle operation.

**The algorithm is algebraically sound for Bundle nodes.** The key identity:

```
cosine(T, bundle(cⱼ₁, ..., cⱼₖ)) > 1/√k
```

is a meaningful test of whether the *combination* `cⱼ₁ AND cⱼₖ` is present as
a unit in T. This is stronger evidence than the individual cosines alone because
it tests the joint contribution, not the marginals. The greedy top-down descent
is optimal in the sense that it returns the coarsest form that clears the
threshold — minimizing the number of returned elements while maximizing the
compositional information preserved.

**Bind nodes.** Here the prior review was correct but not fully grounded. In
MAP, bind(A, B) produces a vector approximately orthogonal to both A and B.
It is *not* a superposition — it does not contain A or B as extractable
components the way a Bundle does. You cannot decompose a Bind node and
cosine-measure the children against T with any geometric meaning. The
children are not present *in* the bind product the way Bundle children are
present in a bundle. The Bind product is an opaque symbol in the codebook.
Therefore: if a Bind node falls below threshold, return it with its cosine.
Do not recurse. This is not a limitation — it is correct MAP algebra.

**The round-trip composes.** The extracted forms are valid ThoughtAST nodes.
The ThoughtEncoder is a deterministic function of AST structure and the global
seed. Re-encoding an extracted Bundle produces the same vector as the original
encoding of that Bundle. The morphism closes:

```
encode : ThoughtAST → Vector
extract : Vector × ThoughtAST → Vec<(ThoughtAST, f64)>
re-encode ∘ extract : Vector × ThoughtAST → Vec<(ThoughtAST, Vector)>
```

The last composed map is well-defined because the domain of `re-encode` is
exactly the range type of the first component of `extract`'s output.

---

## Concerns

**Concern 1: The 1/√N derivation is stated but not derived.**

The proposal says "this is the expected cosine of a random component in a
bundle of N quasi-orthogonal vectors." This is not the expected cosine — the
expected cosine is approximately 1/N. The `1/√N` is the standard deviation
of the noise floor from N-1 cross-terms. The proposal arrives at the right
threshold for the wrong reason.

This matters in practice: at N = 4 (a small sub-Bundle), `1/√4 = 0.5`. That
is a high bar. At N = 100, `1/√100 = 0.1`. The threshold scales correctly with
N — it is more aggressive for small bundles (requiring stronger signal) and
more permissive for large bundles. This is the right direction. But if the
derivation is wrong, the implementor may not know when to deviate from it.
The specification should state: `1/√N` is the noise floor of combined cross-terms
at large D; a present component scoring above this is in the signal regime.

**Concern 2: D=10,000 is the edge of reliability for N=100.**

The JL guarantee at D=10,000 gives cross-term std dev of 0.01 per pair. With
N=100 cross-terms per dimension contributing to the noise on one component, the
combined noise is ~0.1 (by quadrature). The signal is ~0.01. Signal-to-noise
ratio is ~0.1 — barely above unity. This means the threshold `1/√N = 0.1` is
sitting *at the noise floor*, not comfortably above it.

In practice, the market observer's thought vector is the *anomalous component*
after OnlineSubspace noise-stripping — not the raw bundle. This is a critical
distinction. The OnlineSubspace removes the directions that are explained by
normal variance (the principal components). What remains is the residual
direction — a sparser signal with fewer active components than the raw encoding.
The effective N for the anomalous component is smaller than the raw vocabulary
size. This improves the SNR significantly and is the reason the threshold is
viable at D=10,000 despite the raw vocabulary being ~100 facts.

The proposal should make this explicit: extraction operates on the noise-stripped
anomaly vector, not the raw thought bundle. This is not an assumption hidden in
the implementation — it is load-bearing for the threshold derivation.

**Concern 3: The leaf asymmetry.**

When a Bundle node falls below threshold, the algorithm recurses into its
children. When a leaf falls below threshold, the algorithm returns it with
its (near-zero) cosine. This is a termination condition, not a symmetric
case. The output `Vec<(ThoughtAST, f64)>` therefore mixes two semantically
distinct classes:

- Forms that matched (cosine > threshold at their level) — genuinely present
- Leaves that were reached via descent through absent Bundles — not present

Both are returned with honest cosines. The consumer must filter. The prior
review noted this. I flag it again with specificity: a leaf returned because
it survived a descent through an absent Bundle is *not the same information*
as a leaf whose parent Bundle was present. The absent-parent case means the
composition failed — the leaves are individually undetected remnants, not
confirmed presences. The consumer needs to know which case applies.

One clean solution: carry a boolean `confirmed: bool` in the return tuple.
A matched Bundle or leaf (cosine > threshold) is confirmed. A leaf reached
through descent from an absent Bundle is unconfirmed. The consumer can then
filter `confirmed = true` for clean matches and examine `confirmed = false`
for exploratory analysis.

**Concern 4: The Bind node specification gap.**

The proposal's `match thought-ast` handles two cases: `Bundle(children)` and
`leaf`. The ThoughtAST includes `Bind(left, right)` as a structural variant.
Bind is not a Bundle and not a leaf in the MAP sense. The proposal has an
unspecified match arm.

The correct behavior is: treat Bind as an opaque atom. If `cosine(T, encode(Bind(l,r))) > threshold`, return it. If below threshold, return it with its cosine — same as a leaf. Do not recurse into `l` and `r` with the expectation that they are superposition components of T. They are not. This must be specified explicitly.

---

## On the questions

**Question 1: Threshold on extraction or consumer?**

The threshold belongs on the extraction function at call time. The consumer
provides it. The default is `1/√k` where k is the *local* Bundle arity —
this must be re-evaluated at each Bundle node in the descent, not computed
once from a global N.

The reason the threshold must be in the extraction and not the consumer:
the descent decision is irreversible. Once the algorithm decomposes a Bundle
into its children, the joint compositional information — `cosine(T, bundle(c₁,c₂))`
— is discarded. The consumer who receives the leaf list cannot recover it.
If the threshold is too low during extraction, no post-hoc consumer filter
can restore the lost Bundle-level signal.

The signature should be:

```
extract(thought_ast, thought_vec, encoder, threshold_fn) → Vec<(ThoughtAST, f64)>
```

where `threshold_fn : usize → f64` takes the local Bundle arity and returns
the threshold. Default: `|k| 1.0 / (k as f64).sqrt()`. This allows the
consumer to provide a different scaling law (e.g., fixed threshold, or
learned threshold from a reckoner) without changing the algorithm's structure.

**Question 2: Should the consumer's encoder handle a returned Bundle directly?**

Yes, without reservation. The ThoughtEncoder is a deterministic morphism from
ThoughtAST to Vector. A Bundle returned by extraction is a valid ThoughtAST.
Encoding it produces the same vector as encoding it in the original vocabulary
because the encoder is a pure function of AST structure and the VectorManager
seed — there is no implicit state that would break this.

The consumer can therefore take a returned Bundle with cosine 0.22, encode it
to get its vector, and inject `Linear("m:momentum-conjunction", 0.22, 1.0)` into
its own IncrementalBundle. The reckoner sees a named scalar for the conjunction.
This is strictly better than two separate `m:close-sma20` and `m:rsi` scalars
when the conjunction was the unit that cleared the threshold — the composition
carries information that the marginals do not.

**Question 3: Can the extraction threshold be learned?**

Yes. The architecture supports this. A reckoner over the threshold parameter
is a meta-level reckoner that maps conviction (how aggressively to decompose)
to accuracy (whether that decomposition depth correlated with correct exit
predictions). The prerequisite is: establish that fixed-threshold extraction
produces a useful signal at all. Do not parameterize a control loop before
the underlying function is proven useful.

The interface requirement: `threshold_fn` must be a named, passable parameter.
Do not hardcode `1/√k` at the call site. A future reckoner provides a
different function. The extraction algorithm does not change — only the
policy that provides the threshold.

---

## Conditions for acceptance

Three clarifications required before implementation:

1. **Threshold derivation.** State that `1/√k` is the noise floor of combined
   cross-terms, not the expected signal cosine. The expected signal is `1/k`.
   The threshold sits at the noise floor to separate signal from noise. Specify
   that `k` is the local Bundle arity at each descent step, not a global constant.

2. **Bind node handling.** Add an explicit match arm: Bind is opaque. If above
   threshold, return as matched. If below threshold, return with cosine — same
   as a leaf. Do not recurse. This is the correct MAP algebra.

3. **Output type clarification.** The `Vec<(ThoughtAST, f64)>` contains
   both confirmed matches and unconfirmed leaves reached via descent. These
   are semantically distinct. Either add a confirmation flag to the tuple, or
   document explicitly that the consumer must threshold the cosine to distinguish
   them. The extraction does not guarantee that all returned elements are present
   — it guarantees that all returned elements are honest.

The core algorithm is sound. The geometry is right at D=10,000 for noise-stripped
anomaly vectors with effective N significantly below the raw vocabulary size.
The hierarchical descent is the correct greedy strategy for MAP bundles. The
type closes. The round-trip composes. The threshold requires sharper derivation
but arrives at the right number.
