# Review: Proposal 030 — Broker Thinks Opinions

**Reviewer:** Brian Beckman  
**Date:** 2026-04-12  
**Verdict:** Accept with one structural correction required.

---

## The Algebraic Diagnosis

The proposal correctly identifies the problem. Let me state it precisely.

The broker's reckoner learns a linear discriminant in the noise-stripped
subspace of the broker's composed thought. Call that discriminant **w**.
The reckoner's prediction for input **v** is:

```
prediction = sign(w · anomalous_component(noise_subspace, v))
```

The reckoner labels this prediction Grace or Violence. For the discriminant
to separate Grace from Violence, the composed thought **v** must carry
*information predictive of the outcome*. Specifically: the projection of **v**
onto **w** must correlate with the label.

Today the broker encodes:

```
v = bundle(market_extracted_facts, exit_extracted_facts, self_assessment)
```

The market extracted facts are the atoms that survived noise stripping in the
*market observer's* subspace. These are the candle features the market observer
found anomalous. They describe *what the candle looked like*. They carry zero
information about *what the market observer decided* in response to that candle.

The exit extracted facts are similarly the exit observer's input atoms that
survived its noise stripping. They describe the volatility and structure context
that the exit observer processed. They carry zero information about *what
distances the exit observer chose*.

The label (Grace or Violence) is determined by whether the paper's excursion
exceeded the *exit observer's chosen trail distance*. The broker's input
carries no information about that distance. The reckoner is therefore fitting
a discriminant to a bundle that is independent of the label. The expected edge
is zero. That is exactly what is observed: 50/50 across 10k candles, 24 brokers.

The proposal is algebraically correct in its diagnosis.

---

## The Signal-to-Bundle Ratio: The Real Question

The proposal asks: "Can 7 opinion atoms drive the discriminant in a 142-atom
bundle?"

This is the right question. Here is the precise analysis.

At D=10,000, a MAP bundle of K independent bipolar vectors has expected
cosine similarity with any individual component of approximately 1/√K. For
K=142, that is ~0.084. The opinion atoms contribute 7 components out of 142.
If the discriminant **w** aligns with the opinion subspace, the opinions'
collective contribution to any inner product is proportional to their
*share of the total signal* — roughly 7/142 = 4.9%.

But this is not the binding constraint. The binding constraint is whether
the discriminant *can find* the opinion subspace at all, given that the
opinion atoms are buried under 135 atoms of noise (the extracted facts carry
no label-correlated signal). The reckoner's learning algorithm sees a bundle
in which 135 components are label-independent noise. It must extract the
7-atom signal from that noise.

The CCIPCA (online subspace, noise stripping) does help here. The noise
subspace learns what is *normal* across candles. If the extracted market
and exit facts vary across candles in a pattern independent of
Grace/Violence — which they likely do, since they reflect candle structure
rather than outcomes — they will be absorbed into the noise subspace and
stripped before the reckoner sees them. What survives noise stripping is the
anomalous component: the directions that are *unusual* relative to the
background distribution.

This is the key observation: **the noise subspace may already be doing most
of the work**. If the extracted facts are stationary in distribution (they
reflect the market's normal vocabulary), the noise subspace absorbs them. If
the opinion atoms carry label-correlated signal that is *also* novel
(conviction and distances vary with market regime in ways correlated with
outcomes), the noise stripping preserves them.

However, this is not guaranteed. If the opinion atoms also fall within the
noise subspace learned from the extracted facts, they too will be stripped.
The proposal does not address this.

---

## Question 1: Opinions Only, or Opinions + Context?

The proposal asks whether to drop the extracted facts or keep them.

My recommendation: **implement opinions-only first**.

The algebra is cleaner. The extracted facts add atoms whose label-predictiveness
is zero by construction (they are the *inputs* to the leaves, not the outputs).
Adding zero-signal atoms to a bundle does not help the discriminant. It adds
noise. It increases K. It reduces the signal fraction. It increases the demand
on the noise subspace to separate signal from noise.

The argument for keeping the extracted facts is "context." But context is only
useful if it is *predictive context* — context that interacts with the opinions
to change the label distribution. If "RSI was high AND market said Up AND exit
chose wide trail" predicts Grace better than "market said Up AND exit chose wide
trail" alone, the context is load-bearing. If not, it is noise.

Start with opinions only (7 atoms + 7 self-assessment). Measure edge. If edge
is nonzero, you have proven the opinions carry signal. Then add context back
selectively and measure whether edge improves. Doing it in the other order
(opinions + all context) makes it impossible to attribute the result to the
opinions specifically.

The proposal's instinct — "the opinions are the signal, the context is the
background" — is correct. Act on it. Run opinions-only first.

---

## Question 2: The Feedback Loop

The proposal notes that `edge` is computed from the broker's own reckoner
curve, and including it as an input creates a feedback loop:

```
edge ← reckoner curve ← (reckoner learns from thoughts containing edge)
```

This is a fixed-point iteration, not a circularity. The question is whether
it converges.

The reckoner's curve maps conviction → accuracy. The edge at time t is
read from the curve built from observations at times 0..t-1. The thought
encoded at time t includes that edge. The reckoner then observes this thought
at time t+T (when the paper resolves). So the influence of edge(t) on the
curve is delayed by the paper duration.

This delay breaks the direct feedback. The loop has latency. Latency-delayed
feedback loops are not inherently unstable — they are standard in systems
theory. Whether this specific loop is self-correcting depends on the gain:
if edge(t) contributes weakly to the discriminant (as expected, given it is
one atom in a 14-atom bundle), the gain is small and the loop is stable.

There is also a semantic argument for including it: the broker is asking "given
that I have this much edge, and the market said X, and the exit chose Y, will
this paper resolve Grace?" The edge atom is the broker's prior about its own
reliability. That is legitimate self-assessment.

Keep it. But note it in the implementation as a delayed feedback path so the
reader understands the semantics.

---

## Question 3: Distance Encoding

The proposal asks whether exit distances (trail, stop — values in [0.001, 0.10])
should be Log or Linear encoded.

These are ratios. Trail distance = 0.008 means "8 basis points." The relevant
comparison is multiplicative: a trail of 0.016 is twice as wide as 0.008,
not 8 basis points wider. Price movement in financial markets is multiplicative
by construction — that is why returns are log-normally distributed.

Use Log encoding. The algebra encodes "trail is twice as wide" as a geometric
distance in vector space. That is the right semantic for a distance that
interacts with a price series where returns compound.

The proposal already specifies Log for `exit-trail` and `exit-stop`. This is
correct. Do not change it.

---

## The Signed Conviction Atom

The proposal encodes market direction and conviction as a single signed scalar:

```
market-direction = +0.15 (Up) or -0.08 (Down)
encoded as: Linear("market-direction", signed_value, 1.0)
```

This is elegant. One atom carries two facts. But note the constraint this
imposes on the encoder: the Linear encoder must distinguish positive from
negative values as *directionally opposite*, not just *different magnitudes*.
At D=10,000, `encode_linear(+0.15)` and `encode_linear(-0.15)` must be
approximately antipodal (cosine ≈ -1.0) for the signed encoding to be
geometrically meaningful.

Verify that the scalar encoder produces approximately antipodal vectors for
equal-magnitude opposite-sign inputs before trusting the signed conviction atom.
If `Linear("market-direction", +x)` and `Linear("market-direction", -x)` are
merely different (cosine < 0 but not ≈ -1), the signed encoding is correct
but weaker than intended. The reckoner can still learn from it; the gradient
is just shallower.

---

## The Structural Correction Required

The proposal says the broker bundles opinions + extracted facts + self-assessment.
It does not specify *when* in the `post-on-candle` loop the opinions are
available to the broker.

Reading `post.wat`: the composed thought is built as:

```scheme
(composed (bundle (list market-thought exit-vec)))
```

The market prediction, market conviction, and exit distances are computed in
the same `par-iter` pass that builds `composed`. But `propose(broker, composed)`
is called with the composed thought — the broker's noise stripping and
discriminant run on that thought. The opinions are *derived from* that same
parallel computation: `enterprise-pred`, `edge-val`, `dists` are all in `gv`.

So the opinions are available at the point `propose` is called. The implementation
must bundle them into the thought *before* calling `propose`, not after. The
current call is:

```scheme
(propose broker composed)
```

The new call must be:

```scheme
(let ((opinion-facts (encode-broker-opinions
                        enterprise-pred edge-val dists
                        exit-grace-rate exit-avg-residue)))
  (let ((thought-with-opinions
           (bundle (list composed (encode opinion-facts)))))
    (propose broker thought-with-opinions)
    (register-paper broker thought-with-opinions price dists)))
```

This is a structural change to `post.wat` and to the `par-iter-mut-zip` block.
The composed thought registered in the paper must *also* be the opinion-enriched
thought — otherwise `propagate()` returns the wrong thought to the observers.

More precisely: the thought that the broker calls `propose` with must be the
same thought stored in the paper, because that thought is what the reckoner
learns from at resolution time (via `propagate`). If propose receives opinions
but the paper stores composed-without-opinions, the reckoner learns from a
different vector than the one it predicted from. This breaks the
learning-prediction alignment that Proposal 024 established.

The paper and the prediction must use the same thought. This is a type-level
invariant. Enforce it by constructing the opinion-enriched thought once,
passing it to both `propose` and `register-paper`.

---

## Summary

The proposal is algebraically sound. The diagnosis is correct. The fix is
correct. The signed conviction encoding is elegant and defensible. The Log
encoding for distances is correct.

Required before implementation:

1. Implement **opinions-only first** (drop extracted facts). Measure edge.
   Add context back only if edge proves insufficient, and measure the delta.

2. Verify the scalar encoder produces near-antipodal vectors for
   `Linear(name, +x)` vs `Linear(name, -x)`. This is a unit test, not
   a theoretical question.

3. Enforce the structural invariant: the opinion-enriched thought passed
   to `propose` is the same thought stored in the paper and returned by
   `propagate`. One construction, two uses. The type system can enforce this
   if the enriched thought is a named binding before either call site.

The 50/50 result is a diagnostic finding, not a failure. It confirms the
encoding was blind. Adding opinions is not speculation — it is closing a
well-characterized information gap. The expected outcome is a nonzero
discriminant. The only remaining question is magnitude.

---

*The diagram commutes when the same vector appears at prediction time and
resolution time. Today it does not commute — the broker predicts from
extracted facts, learns from the same extracted facts, and is labeled by
an outcome determined by values it never encoded. Closing that loop is the
whole proposal. The algebra is ready.*
