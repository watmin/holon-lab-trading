# Review: Proposal 027 — Brian Beckman

**Verdict:** ACCEPTED — with one clarification required before implementation

## Assessment

The proposal is algebraically sound. Let me state the category theory
precisely, because the proposal gestures at it but does not commit.

### The diagram

Let `A` be the set of ThoughtASTs, `V` be the vector space R^D (D=10,000),
and `[0,1]` be the unit interval of cosine presences. We have:

```
encode : A → V          (the injection)
cosine : V × V → [-1,1] (the inner product, normalized)
```

Extraction is not the adjoint of encoding — it is a READ morphism:

```
extract : A × V → A'
```

where `A'` is the same tree shape as `A` but with scalar leaves
replaced by their cosine presence against the query vector.

This is NOT a left-inverse of encode. `extract(ast, encode(ast))` does
not recover the original scalar values — it returns the cosine of each
leaf's encoding against the full bundle. For a bundle of N leaves,
each leaf vector has expected cosine `1/sqrt(N)` against the bundle,
not 1.0. The proposal is correct to call these "presences," not
"values." The algebra is honest.

### The bundle extraction theorem

If `v = bundle(f1, f2, ..., fn)` and the `fi` are quasi-orthogonal
(which holds in expectation at D=10,000 by JL), then:

```
cosine(v, fi) ≈ 1/sqrt(N) * (1 if fi is present, 0 otherwise)
```

The JL guarantee is that for N leaves with expected cosine ~0 between
them, the presence signal dominates the noise. With N=100 leaves and
D=10,000, the signal-to-noise ratio is approximately sqrt(D/N) = 10.
This is comfortable — the geometry supports the extraction.

### The anomaly-space geometry

The critical subtlety: the proposal asks to cosine leaf encodings
against the ANOMALY, not the original thought. The anomaly is the
projection of the thought onto the complement of the noise subspace.
The noise subspace is a low-rank approximation (8 principal components
in the market observer).

The extraction produces a DIFFERENT decomposition than encoding against
the full thought. A leaf whose direction aligns with the noise subspace
will have lower presence in the anomaly than in the full thought. This
is not a bug — this is the point. The exit wants to know what was
unusual to the market observer. The anomaly carries exactly that.

The algebra closes: the anomaly vector is still in V. The leaf encodings
are still in V. Cosine is well-defined. The extraction is sound in
anomaly-space.

### Compositionality

The output of extraction is a ThoughtAST. The ThoughtEncoder encodes
it to a vector via the same path as any other AST. The types close:

```
extract : A × V → A    (ThoughtAST in, ThoughtAST out)
encode  : A     → V    (ThoughtAST in, Vector out)
```

The composition `encode ∘ extract` is valid. The extracted AST goes
straight into the encoder. The bundle at the exit level includes
extracted market facts as first-class terms. This is the correct
generalization — no special cases, no side channels.

### The `m:` namespace

The `m:` prefix creates new atom names, which create new vectors in
the VectorManager (deterministic from seed). An `m:rsi` atom is
orthogonal (in expectation) to the `rsi` atom. This is correct: the
exit's own RSI reading and "what the market observer found unusual
about RSI" ARE different things. They should be different vectors.
Sharing the atom would conflate the exit's current-candle measurement
with the market's noise-stripped judgment about the same measurement.
Keep `m:` separate.

### Hierarchical extraction

The broker extracting from both market and exit anomalies:

```scheme
(Bundle
  broker-self-facts
  (extract market-ast market-anomaly encoder)
  (extract exit-ast exit-anomaly encoder))
```

The types compose. The extracted ASTs are ThoughtASTs. The broker's
ThoughtEncoder handles them uniformly. The hierarchy is clean.

The dimensionality arithmetic: broker-self-facts + market-extracted
(~100) + exit-extracted (~28) ≈ 140 leaves. At D=10,000, signal-to-noise
is sqrt(10000/140) ≈ 8.5. Still comfortable.

## Concerns

### Concern 1: The N=100 assumption is not stated explicitly

The proposal describes ~100 market facts and ~28 exit facts, but these
numbers float. The extraction soundness depends on D >> N. The
implementation should fail loudly or at minimum warn if N approaches
D/100 (i.e., 100 at D=10,000). The JL guarantee holds in expectation
— individual runs can have higher collision probability. Document the
expected N for each observer so the geometry can be verified.

### Concern 2: Bundle depth and the anomaly subspace interaction

The exit bundles its own 28 facts with the extracted ~100 market facts.
The exit then has a noise subspace (proposed but not yet added — see
026's Q1). If a noise subspace is added to the exit, the subspace will
learn what is "normal" in the combined 128-fact space. The extracted
market facts — which already represent ANOMALIES in the market's frame —
will appear in the exit's training distribution and become "normal" in
the exit's noise model.

This creates a subtle layering: the exit's noise subspace will strip
what is background across candles in the extracted presences. What
survives is "the market observer was unusually animated about something
it is usually animated about" — a second-order anomaly. This may be
desirable, but it should be named explicitly, not stumbled into.

If the exit does NOT add a noise subspace (as currently specified in
exit-observer.wat — intentionally simpler than the market observer),
this concern is deferred. The extraction enters the exit's reckoner
directly as input, without noise stripping. The reckoner then learns
the correlation between extracted presences and optimal distances.
This is safe and correct.

### Concern 3: Cache coherence across the anomaly boundary

The ThoughtEncoder cache stores `(ThoughtAST → Vector)` pairs. The
extraction calls `encode(encoder, leaf)` for each leaf — cache hit,
returns the leaf's vector. Correct.

But the vector cached is the ENCODED leaf (`bind(atom_vec, scalar_vec)`),
not the anomaly. The extraction then cosines this cached vector against
the anomaly. This is correct — the cache stores encoding, not projection.
The concern is just that this be understood: the LRU cache is an encoding
cache, not an extraction cache. Each extraction call performs N cosine
operations against the anomaly. At D=10,000 and N=100, this is 10^6
multiplications and additions per extraction. Not free, but not expensive
either at hardware speeds.

### Concern 4: The `m:` atoms proliferate the VectorManager

Each `m:`-prefixed atom name must be pre-registered with the
VectorManager at startup. The VectorManager is deterministic — same
name, same seed, same vector. But if the market observer's vocabulary
grows (new atoms added to indicator-bank), the `m:` namespace must grow
in parallel. The extract function creates new atom names dynamically
(via `string-append "m:" (name leaf)`). If those atoms are not
pre-registered, the VectorManager will either panic or create a new
vector on-demand.

The implementation must either: (a) pre-register all `m:` atoms at
startup by walking the market AST once, or (b) ensure the VectorManager
supports on-demand deterministic allocation. The proposal doesn't address
this. This is a concrete implementation requirement.

## On the questions

### Q1: Threshold — absorb all and let the reckoner decide

Absorb all. A threshold introduces a hyperparameter that must be tuned.
The reckoner is precisely the mechanism for learning which presences
matter for the exit's question. A presence of 0.01 for `m:rsi` over
1000 candles teaches the reckoner "RSI is not present in the market's
anomalies when we are here." That is information. Discard it with a
threshold and you lose the negative evidence.

The noise subspace (if/when added to the exit) is the correct mechanism
for stripping irrelevant extracted facts — not a threshold. Thresholds
are hyperparameters. Noise subspaces are learned. Prefer the latter.

### Q2: Exit signal drowned by 100 extracted market facts

Not drowned. Amplified by contrast.

The exit's 28 atoms describe the current market state from the exit's
perspective. The extracted 100 market facts describe what the market
observer found unusual. The reckoner sees 128 atoms total. Its K=10
bucketed accumulators will learn the correlation between this 128-dim
presence vector and optimal distances.

If the exit's 28 atoms are highly predictive, the reckoner will weight
those directions. If the extracted 100 atoms add discriminating power,
the reckoner captures that. If they add noise, the reckoner's banded
architecture averages it away. The signal is not divided — it is
presented jointly. The reckoner's geometry does the weighting.

The honest concern is: does the 128-dim vector preserve enough signal
from each component? At D=10,000, yes. The JL guarantee applies to
the full 128 atoms. The geometry is not stressed.

### Q3: `rsi` and `m:rsi` — same atom or different

Different. The argument is in the Assessment above. The exit's RSI
(a scalar measurement from this candle) and the market's extracted
RSI presence (how much RSI survived the market observer's noise
stripping) are semantically distinct. They should be distinct vectors.

An additional practical reason: the exit's reckoner learns the JOINT
correlation of (exit-rsi, m:rsi) with optimal distances. These two
atoms together encode "the RSI reading AND how unusual the market
observer found it." This joint presence is more informative than either
alone. Sharing the atom would collapse the distinction and lose the
second-order information.

### Q4: Should extract live in holon-rs

Not yet. The operation is logically a VSA operation — decode a bundle
using a codebook. But in holon-rs, the codebook is the ThoughtAST,
which is a trading-lab concept. Holon-rs knows atoms, bind, bundle,
and cosine. It does not know ThoughtASTs or the `m:` naming convention.

The extraction function walks the ThoughtAST tree, which is defined in
the trading lab, not in the substrate. Until the ThoughtAST abstraction
is generalized (if ever), extract belongs in `thought_encoder.rs` or a
companion `extraction.rs`. It is a function that interprets a
trading-lab data structure using substrate primitives — a layer 2
operation, not a layer 1 primitive.

If in the future holon-rs gains a `Codebook` abstraction (a set of
named vectors and a query interface), then a generic `project` or
`decode` primitive would be appropriate at the substrate level. That
is future work. For now: implement in the lab.
