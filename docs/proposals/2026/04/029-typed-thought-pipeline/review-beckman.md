# Review: Proposal 029 — Brian Beckman

**Verdict:** ACCEPTED

## Assessment

The proposal describes a pipeline of morphisms in a category where objects
are pairs `(ThoughtAST, Vector)` and morphisms are observer functions. Let
me verify that the algebra closes.

**The pipeline as a diagram**

Each stage is a function:

```
market_observer : Candle → (ThoughtAST_m, Vector_m)
exit_observer   : Candle × ThoughtAST_m × Vector_m → (ThoughtAST_e, Vector_e)
broker          : Candle × (ThoughtAST_m, Vector_m) × (ThoughtAST_e, Vector_e) → Proposal
```

This is a functor chain. The output type of each stage is the input type of
the next, with the candle threaded through as ambient context. The diagram
commutes in the sense that there is no shortcut — no observer can receive
facts it did not produce or consume. The types enforce the topology.

**The extract primitive as a natural transformation**

The `extract` primitive is:

```
extract : Vector × Vec<ThoughtAST> → Vec<(ThoughtAST, f64)>
```

More precisely: `extract` maps a bundle `b` and a set of query forms `F`
to a set of `(form, cosine(b, encode(form)))` pairs. This is the
decoding step of a VSA probe — not a new primitive at all, but the
standard probing operation applied in batch. The claim that this is
"encode in reverse" is operationally correct but needs precision:

In MAP, encoding a form `f` gives vector `v_f`. Bundling N such vectors gives
bundle `b`. Probing: `cosine(b, v_f) ≈ 1/N × (sum of contributions from
f and noise from the N-1 other components)`. With quasi-orthogonal forms at
D=10,000, the noise term is bounded by approximately `(N-1)/sqrt(D) ≈
(N-1)/100`. For N=100 forms, noise ≈ 0.99 — which is exactly the
motivation for the noise subspace. The anomalous component strips the
`(N-1)` background so that the surviving forms produce readable cosines.

The algebraic chain is: encode → bundle → noise-strip → probe. The
`extract` primitive is step four. This closes correctly.

**Typed structs as a functor**

The `ToAst` trait establishes a correspondence:

```
struct MomentumThought → ThoughtAST (via to_ast)
struct MomentumThought → Vec<ThoughtAST> (via forms)
```

This is a pair of natural transformations from the category of typed market
structs to the category of AST trees. The compiler enforces that the
morphism `exit_observer` can only be composed with a compatible
`market_observer` — the types prevent wrong piping. This is correct type
engineering. The 600-atom bug the proposal describes (extracting from all
six market observers instead of one) is precisely a failure of composition
— two morphisms connected that should not be, caught at runtime rather
than compile time. The typed structs fix this by making the composition
rule a compile-time constraint.

**The scoping fix**

The proposal correctly identifies that M exit vectors computed once and
shared across N market observers is wrong: each `(m_i, e_j)` slot must
see the anomaly from `m_i` specifically, not a composite or average. This
is a correctness argument, not an optimization. Pre-computing shared exit
vecs collapses N distinct information channels into one, destroying the
information the N×M grid exists to preserve. The fix — move extraction
into each grid slot — is the only algebraically honest choice.

**The self-describing pair**

The proposal's claim that `(ThoughtAST, Vector)` is "self-describing" is
precise. The AST is the codebook for the vector. Without the AST, the
vector is opaque — you cannot know which forms to probe. With the AST, the
consumer has both the query set (forms) and the measurement target (vector).
The pair is therefore a complete unit. This mirrors the engram design in
the Holon memory layer, where the surprise profile (AST-level) travels
with the learned subspace (vector-level) as a matched pair.

**Proposal 029 supersedes 028 correctly**

028 introduced a descent threshold for hierarchical extraction. The 029
proposal eliminates the threshold from the primitive and hands it to the
consumer. This is the right move: a threshold in the primitive is an
opinion disguised as mechanism. The consumer knows what granularity it
needs. The primitive should only measure. 029 achieves this. The 1/sqrt(N)
heuristic from 028 survives as a consumer-side option, not a primitive-side
obligation.

## Concerns

**Concern 1: Noise floor at small N**

The `extract` primitive is honest — it returns cosines with no threshold.
But at the grid slot, the consumer must choose a threshold. The expected
cosine of a genuinely present form in an anomaly vector of K surviving
components is approximately `1/K`. The expected cosine of an absent form
is approximately `0 ± noise`. If K is small (e.g., 3–5 components survived
the noise stripping), the separation is large and any reasonable threshold
works. If K is large, the genuine cosines are small and the noise floor is
close. The proposal does not specify how consumers should calibrate their
thresholds given the anomaly's effective density. This is not a blocker —
the consumer can learn it — but it should be acknowledged.

**Concern 2: AST identity vs vector identity**

The `extract` primitive encodes each form via the encoder cache. The cache
key is the ThoughtAST. If two AST nodes are structurally identical (same
form, same value, same name) but were produced by different vocabulary
modules, the encoder may return the same vector for both. This is correct
VSA behavior — same encoding, same vector — but it means the consumer
cannot distinguish "m:close-sma20 from observer A" and "m:close-sma20 from
observer B" if the ASTs are identical. With typed structs, this is less of
a problem because the struct types distinguish them at the call site. But
the extracted cosines will be identical for identical AST nodes regardless
of provenance. The consumer should be aware that the vector does not carry
authorship.

**Concern 3: The exit's noise subspace (Question 2 from the proposal)**

The exit currently has no noise subspace. It encodes own facts (28 atoms)
plus extracted market facts (~100 atoms, filtered). Without stripping, the
exit's anomaly is the raw bundle — every form contributes regardless of
whether it's background for this exit observer's experience. The next
consumer (broker) would then extract from an un-stripped vector, getting
cosines that include noise. This is a real gap. The proposal asks whether
the exit should have one. It should. The noise subspace is not optional for
any stage that produces a pair intended for downstream extraction.

**Concern 4: Bundle capacity under composition**

When the exit encodes own-facts + absorbed market facts, the bundle grows
to approximately 128 atoms. At D=10,000, the expected cosine noise per form
is about `(N-1)/sqrt(D) = 127/100 ≈ 1.27`. This exceeds 1.0, which means
the naive probe is unreliable without noise stripping. The exit's noise
subspace (Concern 3 above) is therefore not just desirable — it is required
for the extraction to be algebraically sound at N=128. Without it, the
broker's extraction from the exit's anomaly will read noise, not signal.

## On the questions

**Question 1: Should typed structs be deferred?**

No. Implement them together with extract and scoping. The 600-atom bug is
already present in the current code. Deferring typed structs while
implementing extraction creates an interval where extraction exists but is
unguarded by types — the bug can re-appear as "I'll pass the right struct,
I promise." The compiler is cheaper than the promise. The refactor touches
every vocabulary module, but the vocabulary modules are the smallest units
in the system. Do it once, in one session, and close the gap permanently.

**Question 2: Should the exit have its own noise subspace?**

Yes, without qualification. See Concern 3 and Concern 4 above. The exit
must strip its own bundle before producing its anomaly. A stage that
produces `(ThoughtAST, Vector)` for downstream extraction must ensure the
Vector is stripped — otherwise the pair is not self-describing, it is
self-misleading. The exit noise subspace should use the same CCIPCA
mechanism as the market observer, configured for the exit's expected bundle
size (~128 atoms → more principal components may be needed than the market
observer's ~100-atom bundles).

**Question 3: Should the broker receive the exit's (ast, anomaly) pair?**

Yes. The broker receives one composed vector today. But the composed vector
discards the information about which forms the exit found noteworthy versus
which were background. If the broker only receives the composed exit vector,
it cannot extract the exit's signal — it can only probe the composed vector,
which may be dominated by the exit's own facts rather than the extracted
market content. Giving the broker the exit's `(ast, anomaly)` pair allows
it to independently read both layers. The broker's thought becomes:

```
broker-facts + extract(market-ast, market-anomaly) + extract(exit-ast, exit-anomaly)
```

This is the full hierarchical read. The composed vector is then redundant
for the broker — it can be dropped, or kept as a single aggregate cosine
for a cheaper "is this exit similar to my history?" check. The pair is
strictly more informative than the composed vector alone.

---

The algebra closes. The types enforce the topology. The proposal is sound.
