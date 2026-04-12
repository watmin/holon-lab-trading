# Review: Proposal 027 — Rich Hickey

**Verdict:** ACCEPTED

## Assessment

This is a good proposal. Not because it is clever — because it is honest about
what it is.

The authors write: "This is not a new primitive. This is cosine + encode
composed into a pattern." That sentence is the review. The function `extract`
has no hidden state, no side effects, no protocol, no shared memory. Given
an AST and a vector, it returns a new AST. The transformation is pure. The
geometry does the work. The function is a name for something that already
exists.

The communication story is sound. The market observer encodes through its
lens, strips noise, produces an anomaly. The exit wants to know what was
noteworthy. The naive approaches are wrong: bundling absorbs the anomaly into
a larger pool and loses the signal; ignoring the anomaly loses the context.
The extraction is the third option: decode what survived. The AST is the
vocabulary. The anomaly is the message. The cosine is the decoding operation.
None of these are new ideas. The composition is.

The hierarchy section is the strongest part. The broker can extract from both
the market thought and the exit thought. Two ASTs, two anomalies, two
extractions — and the broker gets scalar facts about both observers' notable
findings without any protocol, any shared state, any explicit communication
contract. The geometry is the contract. That is the right shape.

The cache observation is correct and important. The market observer encoded
these AST forms this candle. They are in the LRU cache. The extraction is
dot products against cached vectors — constant time per leaf, no allocation,
no recomputation. The decode is genuinely free.

## Concerns

**The dimensionality ratio deserves attention.** The exit's own vocabulary is
28 atoms (26 per proposal 026 plus some growth). The extracted market context
is ~100 atoms. The bundle is now roughly 128 atoms total. In a 10,000-
dimensional space the superposition capacity is high, but the ratio matters:
the market's contribution to the bundle is ~78% of the atoms by count. Whether
the noise subspace can separate signal from the larger extracted component is
an empirical question, not a geometric guarantee.

The authors ask this in question 2. The answer I would give: do not guess. Run
it. The noise subspace learns the background distribution of the full bundle.
If the extracted market facts are structurally correlated with the exit's
noise (because they are background in the market observer's experience too),
the subspace will strip them. If they are structurally informative for exit
decisions, they survive. You cannot reason your way to which one is true.
Measure it.

**The `m:` prefix decision is sound but worth examining.** The proposal
correctly observes that `rsi` and `m:rsi` are different questions. The exit's
`rsi` is: what is RSI doing this candle. The extracted `m:rsi` is: how much
did the market observer's noise-stripped experience encode RSI as noteworthy.
These are different facts. The prefix is the right call. The shared-atom
alternative would collapse two distinct things into one atom — that is
complecting.

**The pipe change is the most consequential change.** Today the observer sends
`(thought, misses)`. Proposal 026 established that the broker composes market
thought with exit thought. The pipe now carries `(thought, ast, misses)`. The
AST is a tree of ~100 nodes. This flows from the market observer thread to
the exit grid every candle. Verify that the AST is cheap to pass. If the AST
is allocated fresh each candle, the pipe is clean. If the AST is shared
across threads with interior mutation, that is a problem.

**The threshold question is a trap.** See concerns on question 1 below.

## On the questions

**1. Should extraction use a threshold?**

No. Do not add a threshold. A threshold is a parameter. Parameters are
decisions pretending to be facts. The question "presence above what minimum"
has no principled answer — you would tune it to the current data and call it
design. The reckoner's job is to learn what matters. Let the reckoner have
all the presences. Near-zero presences contribute near-zero signal to the
encoded vector. They are not noise — they are the absence of signal, which
is also information. The reckoner can discriminate. Do not pre-filter its
inputs.

**2. Does the exit get drowned by the market's 100 extracted facts?**

Unknown until measured. The hypothesis that the noise subspace will separate
what matters is reasonable but not guaranteed. The bundle capacity at 10,000
dimensions is substantial, but the exit's subspace learns from the full
bundle including the extracted facts — so it learns the background of
the composed input, not the exit-only input. The noise subspace will do its
job. Whether what survives includes the right market facts is the experiment.

If you find that the exit's learning degrades after this change, one diagnostic
is to check whether the extracted facts have lower variance across candles than
the exit's own facts. Low-variance extracted facts become part of the noise
model and vanish from the anomaly. High-variance extracted facts stay. That is
the mechanism working correctly.

**3. `m:` prefix — same atom or different?**

Different. This is not ambiguous. `rsi` is a measurement. `m:rsi` is a
presence score — a second-order fact about what a specific observer's
noise-stripped experience found noteworthy about the measurement. The
ontological level is different. Sharing the atom would collapse a first-order
fact with a second-order fact into a single dimension. That is a type error in
the geometry. The prefix is correct.

**4. Should this be in holon-rs rather than the trading lab?**

Yes, eventually. The observation is right: `extract` is a VSA operation — it
decodes a bundle using a known codebook, which is the dual of encoding.
Encode composes a tree of facts into a vector. Extract decomposes a vector
back into a tree of presences given the codebook. It belongs in the substrate.

However: do not move it now. Prove the concept in the trading lab. Get the
empirical result. Generalize when you know what you have. Moving it to
holon-rs before the pattern is validated is premature generalization. Build
it in the trading lab, validate it, then promote.
