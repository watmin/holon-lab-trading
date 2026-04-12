# Review: Proposal 026 — Brian Beckman

**Verdict:** CONDITIONAL

---

## Assessment

The proposal splits one composed vector into two properly factored ones. That
is the right move categorically. Let me state why, then state what still
troubles me.

**The composition problem is real and correctly diagnosed.**

In category theory we ask: does this morphism factor cleanly? The current
`recommended-distances` function receives a composed vector:

```
composed = bundle(market-thought, exit-thought)
```

and uses it as input to a continuous reckoner that predicts scalar distances.
The reckoner's K=10 bucketed prototypes must partition this space. But the
space is a product: Direction × Exit-State. The distance to set a trailing
stop is a function only of Exit-State. Direction is not in the codomain's
support.

This is not a minor efficiency complaint. The reckoner's bucket assignment
(nearest prototype in cosine space) is now partitioning a product manifold
when it should be partitioning a submanifold. Half the coordinate dimensions
carry zero information about the target scalar. The K=10 buckets will be
positioned in the full product space, not in the relevant subspace. That is
a structural degradation of the readout. The proposal's fix — query on
`exit-thought` only — collapses the product correctly.

**The vocabulary additions are well-reasoned.**

Regime facts (Hurst, choppiness, DFA alpha, entropy-rate, fractal-dim,
variance-ratio) are the correct prior for "how wide should distances be."
These are second-order statistics about the market's geometry. Volatility
(ATR) is a magnitude. Regime tells you the *kind* of environment in which
that magnitude lives. Wide trail in high ATR is correct in trending markets.
Wide trail in high ATR during chop is expensive. The exit observer currently
cannot distinguish these cases. Regime closes that gap.

Time facts (hour, day-of-week) are appropriate. The exit's relevant question
is liquidity regime, not calendar precision. Hour captures session transitions.
Day-of-week captures weekend illiquidity. The proposal correctly excludes
minute (too fine) and month (too coarse — already captured by regime
statistics). The granularity selection commutes with the encoding: circular
atoms at those periods do what the proposal intends.

**One structural concern: the regime atom naming collision.**

The exit `structure.wat` already encodes `exit-kama-er` from `(:kama-er c)`.
The market `regime.wat` encodes `kama-er` from the same field. The proposal
adds the full regime module to exit vocabulary. That means the exit observer's
generalist lens will now encode BOTH `exit-kama-er` (from structure) AND
`kama-er` (from regime). These are the same underlying field with different
atom names. In VSA, different atom names produce different role vectors, so
different bindings. The encoder does not know they are semantically redundant.
This is not fatal — the discriminant can learn to ignore one — but it is
wasteful and potentially confusing. The condition: decide explicitly whether
to keep `exit-kama-er` in `exit/structure.wat` or rename it. Do not silently
carry both.

**The proposal also claims 8 regime atoms exist but selects 6.**

`vocab/market/regime.wat` encodes 8 atoms: kama-er, choppiness, dfa-alpha,
variance-ratio, entropy-rate, aroon-up, aroon-down, fractal-dim. The proposal
lists 6 (hurst instead of kama-er, omits aroon-up, aroon-down). Two
discrepancies:

1. The proposal refers to `hurst` — but `regime.wat` encodes `dfa-alpha` (the
   DFA scaling exponent), not a raw Hurst exponent. These are related but not
   identical. The naming in the proposal does not match the atoms in the spec.

2. `aroon-up` and `aroon-down` appear in regime.wat but are not mentioned in
   the proposal's new atom list. If the exit observer should use the full
   regime module (as the proposal implies), both aroon atoms come along. If
   aroon is excluded by design, the proposal must define a new
   `encode-exit-regime-facts` function that selects the 6 it wants. This
   matters — it determines whether `exit-lens-facts` calls `encode-regime-facts`
   directly or a new filtered variant.

The condition: the implementation must resolve this precisely. Either import
`encode-regime-facts` as-is (8 atoms, include aroon, rename dfa-alpha
reference) or define `encode-exit-regime-facts` with the exact 6 atoms, each
matching an actual field name.

---

## Concerns

**1. Self-assessment feedback topology.**

The self-assessment atoms (`exit-grace-rate`, `exit-avg-residue`) are facts
about the exit observer's own recent performance, encoded into the exit
observer's own input vector, which trains the exit observer's own reckoner.
This closes a loop. The loop is:

```
exit-obs learns → performance metrics →
exit-obs encodes metrics → reckoner queries on them →
exit-obs predicts distances → broker outcome → performance metrics
```

The proposal argues this is safe because the simulation provides honest labels.
I accept that argument for *resolution* (the simulation labels are not
optimistic). But consider what happens when the loop is in a good period: high
grace-rate encodes into the input, the reckoner learns "high grace-rate →
use these distances," performance stays good, grace-rate stays high. The
discriminant has learned to track its own success. When the market regime
shifts and the discriminant's learned distances become wrong, grace-rate drops —
but with a lag. The lag during which grace-rate is still high but distances are
now wrong is the dangerous period.

This is not a reason to reject self-assessment. It is a reason to track it
explicitly. The implementation should ensure the performance metrics fed back
are computed over a short rolling window (not cumulative). Rolling grace-rate
is informative. Cumulative grace-rate is a biased version of "how old is this
observer." The proposal does not specify window length for these computations.
The condition: define the rolling window for `exit-grace-rate` and
`exit-avg-residue`. I suggest 50-100 observations — long enough to be stable,
short enough to track regime changes.

**2. Learning target after the split.**

`observe-distances` in `exit-observer.wat` currently receives `composed` (the
market+exit bundle) as the vector to train on. After this proposal, the reckoner
queries on `exit-thought` only — but `observe-distances` still receives
`composed` from the broker's `propagation-facts`. The learning vector and
the query vector will diverge.

Reading `broker.wat`: `propagation-facts` stores `composed-thought` — which
is the full market+exit bundle that was the input at prediction time. The
`observe-distances` call in `post-propagate` passes this composed vector
to the exit observer to learn from. If the reckoner now queries on exit-thought
only, it must also *train* on exit-thought only. The current propagation path
does not thread exit-thought separately — it only carries composed-thought.

This requires a change to `PropagationFacts`. It must carry the
`exit-thought` separately so that `observe-distances` can train on the correct
vector. This is not a minor touch. It ripples through:
- `broker::propagation-facts` (new field: `exit-thought`)
- `broker::propagate` (must record and return exit-thought)
- `post::post-propagate` (must pass exit-thought to `observe-distances`)
- `exit-observer::observe-distances` (receives exit-thought not composed)

The proposal does not mention this. It is the largest implementation gap. The
condition: `PropagationFacts` must be extended with an `exit-thought` field,
and the full propagation path must be updated to carry it.

**3. The update-triggers path has the same problem.**

`post-update-triggers` re-queries the exit observer with `composed` to get
fresh distances for active trades. After this proposal, it should query with
`exit-vec` only. This path is simpler to fix (the exit-vec is already computed
locally in that function), but the proposal does not address it. The condition:
`post-update-triggers` must pass `exit-vec` to `recommended-distances` instead
of `composed`.

---

## On the questions

**Q1: Should the exit observer strip noise on its own input?**

Yes, eventually. No, not in this proposal. Here is the reasoning.

The market observer strips noise because its input space is high-dimensional
and contains a large background distribution (ordinary market movement) that
drowns the directional signal. The anomalous component IS the signal. The exit
observer's situation is different: it is predicting a scalar magnitude, not
a binary direction. The relationship between exit-thought and distances may be
more direct — high ATR may straightforwardly produce wide distance predictions
without needing anomaly extraction. Whether noise subtraction helps the
reckoner's K=10 prototype assignment is an empirical question, not a
structural one.

Introduce noise subtraction in a later proposal, after confirming the vocabulary
expansion alone improves reckoner quality. Adding both at once makes the
experiment ambiguous. The exit observer's quality is measured through the
broker's curve — that is the right signal to watch. If the broker's curve
quality does not improve with 26 atoms and clean input, then noise subtraction
is the next lever to pull.

**Q2: Should self-assessment fields live on the exit observer struct or be
passed from the broker?**

Pass them from the broker at query time. Do not store them on the exit observer.

The exit observer's struct should remain a description of its learned model
— lens, reckoners, default distances, incremental bundle. Performance metrics
are facts about the broker relationship, not about the observer's intrinsic
state. Multiple brokers share each exit observer (it is indexed by ei, shared
across N market observers). Each broker has its own grace-rate. The exit
observer should not aggregate across brokers — that would lose the per-broker
resolution.

The clean interface: the broker computes rolling grace-rate and avg-residue
from its own track record, then passes them as part of the call to
`recommended-distances` alongside the exit-thought. The broker already tracks
`cumulative-grace`, `cumulative-violence`, and `trade-count`. Rolling window
computation is local to the broker. This keeps the exit observer stateless with
respect to performance — it remains a pure readout function from thought to
distances, informed by broker-supplied self-assessment facts.

**Q3: Two different inputs for two different questions — separation or
complication?**

Separation. It is the correct factoring.

The category is: morphisms from thought-space to prediction-space. The exit
reckoner's morphism is `ExitThought → Distances`. The broker's reckoner's
morphism is `ComposedThought → Grace/Violence`. These are different morphisms
with different domains. Using the same composed vector for both was a
conflation of domains. The proposal restores the correct typing. Two inputs
for two questions is not a complication — it is what you get when the types
are right.

The broker remains the composition point. It holds both the market thought
and the exit thought. It composes them for its own reckoner. It passes
exit-thought to the exit observer for distance queries. This is clean
dependency injection, not duplication.

---

## Summary of conditions

The verdict is CONDITIONAL on four things:

1. **Atom naming collision:** Decide whether `exit-kama-er` and `kama-er`
   coexist in the generalist lens. If the regime module is imported as-is,
   remove `exit-kama-er` from `exit/structure.wat` or accept intentional
   redundancy explicitly.

2. **Exact atom selection:** The proposal mentions 6 regime atoms including
   `hurst` which does not exist in `regime.wat` (the field is `dfa-alpha`).
   Either define `encode-exit-regime-facts` with the exact 6 atoms and correct
   field names, or use `encode-regime-facts` as-is (8 atoms including aroon).
   Both are acceptable. Ambiguity is not.

3. **PropagationFacts must carry exit-thought:** The learning path
   (`observe-distances`) must train on `exit-thought`, not `composed`. This
   requires a new field in `PropagationFacts` and changes to the propagation
   chain in `broker.wat`, `post.wat`, and `exit-observer.wat`.

4. **Rolling window for self-assessment:** Specify the rolling window length
   for `exit-grace-rate` and `exit-avg-residue`. Cumulative metrics are not
   informative for regime detection.

These are structural requirements, not polish. The proposal's diagnosis is
correct and the direction is sound. Satisfy the conditions and it is
implementable.
