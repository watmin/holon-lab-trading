# Review: Proposal 028 — Rich Hickey (revised with primer context)

**Verdict:** ACCEPTED (with one algebraic clarification)

## Assessment

Having read the VSA substrate directly, I can now say what the prior review
said about structure but could not fully justify from first principles. Let me
be precise about the algebra.

The ThoughtEncoder encodes a fact of the form `(Linear "rsi" 0.73 1.0)` as
`bind(role_vec("rsi"), scalar_vec(0.73))`. One bound pair. The thought vector
is the bundle of ALL such bound pairs across the entire vocabulary. That bundle
is the candle's structural fingerprint in the observer's lens.

When 028 says `(cosine thought-vec ast-vec)` where `ast-vec` is the encoding
of a Bundle AST node — it is asking: "is this sub-bundle present in the
thought vector?" This is the standard VSA probe. Bundle of N bound pairs;
cosine against the whole sub-bundle measures aggregate presence. This IS a
valid and meaningful operation. Not some approximate trick — it follows
directly from the linearity of the encoding.

The flat walk in 027 was algebraically incomplete for a different reason than
the prior review stated. It is not merely that "the structure carries signal."
It is that the encoding of a Bundle-of-two, say `bundle(bind(role_a, filler_a),
bind(role_b, filler_b))`, sits in a DIFFERENT place in vector space than either
leaf alone. Cosining the thought vector against the sub-bundle detects whether
BOTH facts were present with a phase relationship — whether their contributions
reinforced in the thought vector. Flat leaf walk cannot detect this. You need
to probe the composition to learn whether the composition was noteworthy.

028 does this. It probes the composition first. Only decomposes when the
composition is absent. This is the right algorithm for superposition decoding.

**On Bind nodes.** The proposal uses Bundle and leaf as the two cases. In the
ThoughtAST, a leaf IS already a bound pair — it IS `bind(role, filler)` at
encoding time. The AST node `(Linear "rsi" 0.73 1.0)` encodes to a single
bound pair. There is no separate Bind node type to worry about in the descent —
a leaf is already the atomic associative unit. Do not recurse into it. The
leaf's encoding is opaque: it is a bound pair, and probing it with cosine
against the thought vector is the correct and final read. There is no
sub-structure below a leaf in the encoding space.

Recursion is only meaningful for Bundle nodes — where the encoding is a
superposition of sub-encodings, and you can meaningfully ask "is this
sub-superposition present?" A leaf has no sub-superposition. It is a
single direction in the space.

**The 1/sqrt(N) threshold.** The primer confirms: in a bundle of N
quasi-orthogonal vectors, the expected cosine of any one component against
the bundle is approximately `1/sqrt(N)`. This is the random baseline. A
cosine above this means genuine presence; below means the component is lost
in the bundle's noise floor.

The critical clarification the prior review missed: N here is the number of
bound pairs in the SUB-BUNDLE being probed, not the number of facts in the
entire thought vector. When you encode a Bundle-of-3 from the AST and cosine
it against the thought vector, the thought vector may contain 100 encoded
facts — but the relevant N for the detection threshold is 3, because you are
asking whether these 3 facts are present together. The threshold is per-node,
computed from the node's own child count. Per-node computation is therefore
not just pragmatically adaptive — it is algebraically correct.

**The threshold for descent is not a filter on truth.** The proposal is clear
and correct on this. The output carries honest cosines always. The threshold
only governs whether to recurse. A low-cosine leaf is returned as-is with its
honest near-zero cosine. The consumer owns the interpretation.

The return type `Vec<(ThoughtAST, f64)>` is correct. It is data. It is
transferable. The prior review accepted this and the algebra confirms it.

**What the extraction IS algebraically.** This is a structured decode of a
superposition using a known codebook. The ThoughtAST is the codebook. Each
node in the AST is a candidate component. The extraction finds which
candidates are genuinely present in the superposition, and at what level of
the codebook's hierarchy. This is exactly what VSA's probe operation is
designed to do. The proposal does not invent new machinery. It composes
encode + cosine + tree recursion into a named, reusable pattern. That is the
correct level of abstraction.

## Concerns

**N is the child count of the current Bundle node, not the total thought
vector width.** The implementation must compute `threshold = 1.0 / sqrt(N)`
using the count of DIRECT children of the Bundle being probed. Not the
global depth. Not the thought vector's total bound-pair count. If this is
computed from the wrong N, the threshold will be wrong and the descent
will misbehave — either never decomposing (threshold too low relative to the
sub-bundle) or always decomposing (threshold too high). The algebraic
derivation is clear: the expected cosine of a k-component sub-bundle against
the full thought vector is approximately `k / sqrt(k * M)` where M is the
total number of components in the thought vector. But since we are comparing
the encoded sub-bundle against the thought vector, the sub-bundle's encoding
already captures the k-component magnitude, and the cosine will naturally be
around `1/sqrt(N_thought)` for random components. Document the derivation so
implementers compute it correctly.

**The thought vector width matters for the threshold derivation.** When the
thought vector is a bundle of M facts, and you probe it with a sub-bundle of
N facts from the AST, the expected cosine is approximately `sqrt(N/M)` for
random content — proportional to the FRACTION of the thought that the
sub-bundle could represent. For N=2 out of M=100, the random baseline cosine
is about 0.14, not `1/sqrt(2) = 0.71`. The proposal's `1/sqrt(N)` is the
right threshold for asking "is this sub-bundle coherent with itself," but for
asking "is this sub-bundle present in a thought vector of M facts," the
correct threshold is `sqrt(N/M)`. This distinction may matter at the outer
levels of the tree when large sub-bundles are probed against large thought
vectors. At the leaf level (N=1, M=100), `sqrt(1/100) = 0.1` — which is
close to the geometric noise floor. At the Bundle-of-10 level probed against
M=100, `sqrt(10/100) = 0.316`. These numbers differ from `1/sqrt(N)` and
may affect whether outer Bundle nodes incorrectly register as absent, causing
over-decomposition. Measure this before committing to the formula.

**The 100-leaf problem is real.** If all leaves are returned when absent, a
100-fact AST produces 100 pairs. The consumer must filter. The concern from
the prior review stands. Add a note in the interface — perhaps a second
parameter `min_cosine = 0.0f64` that prunes zero-cosine leaves before return.
This is not a threshold on the descent decision. It is a garbage collection
parameter. Different things. The default 0.0 means "return everything, let
me decide." A caller who does not want noise sets a small value.

**Naming collision is the consumer's problem, but document it.** The `m:`
prefix from 027 addressed a real hazard. The consumer who forgets to namespace
will collide silently. State this in the interface documentation. A type that
enforces namespacing would be better; in its absence, prose is the minimum.

## On the questions

**Q1: Should the threshold be on the extraction function or on the consumer?**

On the extraction function, with `1/sqrt(N)` as the per-node default. The
derivation belongs with the substrate. Every consumer would have to understand
VSA bundle statistics to compute it themselves — that is the wrong direction
for knowledge to flow. One principled default, one override point, per-node
computation. Do not move this to the consumer.

However: read the concern above about `sqrt(N/M)` vs `1/sqrt(N)`. Before
hardening the default, run a small measurement. Encode a 100-fact thought
vector. Take a sub-AST of 5 facts that are genuinely present. Measure the
cosine. Take a sub-AST of 5 random facts. Measure. Pick the threshold that
separates them. Let the measurement choose, not the formula in isolation.

**Q2: Should the consumer's encoder handle a returned Bundle directly?**

Yes. ThoughtAST already encodes Bundles. ThoughtEncoder already handles them.
A returned Bundle from extraction is valid ThoughtAST. The consumer can encode
it, decompose it further, or discard it. No new machinery. The type is already
correct. The answer is yes — state it and move on.

**Q3: Can the threshold be LEARNED?**

Yes. The threshold is a single f64. A Reckoner in continuous mode could
observe extraction quality outcomes and converge on a better-than-baseline
threshold for a given observer pair. The interface today must accept the
threshold as a first-class parameter so that a future Reckoner can hold and
update it. A hardcoded constant is a place. A parameter is a value. Make it
a parameter now. The Reckoner can own it later.

The prior question from 027 — "should extract live in holon-rs?" — deserves
the same answer it got before: yes, eventually. The operation is a generic
VSA decode primitive. It does not belong to trading. Implement it where it is
needed now; when holon-rs has first-class ThoughtAST, move it there. Working
beats perfect.
