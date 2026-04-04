# Review: Hickey

Verdict: CONDITIONAL

---

## General Assessment

The proposal asks a good question and arrives at a good answer. The two-stage pipeline is a *composition* of existing primitives, not an invention. That is the right instinct. But there are places where the design reaches for mechanism when it should reach for data, and places where a question is asked but the answer was already given by the architecture.

I will address each numbered question, then the candidate thoughts question, then the conditions.

---

## Question 1: Should the noise subspace learn from ALL candles or only Noise-labeled candles?

Learn from Noise-labeled candles only.

The proposal already states why: "Those thoughts are definitionally uninformative. The facts present during non-events ARE the noise." This is correct. Learning from all candles captures the average thought, which includes the signal you are trying to preserve. The noise subspace should learn what *doesn't matter*, not what *usually happens*. These are different manifolds.

The "average thought" conflates two populations. The "uninformative thought" is one population, cleanly defined by the labeling scheme you already have. Use the label. That is what labels are for.

---

## Question 7: Memory vs forgetting

No decay. Start there.

The proposal lays out three options and correctly identifies this as empirical. But I would go further: decay is a *mechanism* you add when you have *evidence* that the simple thing fails. The simple thing is: accumulate. CCIPCA with fixed k eigenvectors already forgets implicitly -- it is an online algorithm that tracks the top-k principal components. Old directions that stop appearing in the data lose eigenvalue mass to new directions that do. This is not "no forgetting" -- it is *implicit forgetting proportional to irrelevance*. That is the right kind of forgetting.

Exponential decay adds a parameter. Parameters are opinions. You do not yet have an opinion worth encoding. Engram snapshots at regime boundaries add complexity and a regime-detection dependency. You already have a regime observer. Do not couple the noise subspace to it.

Run the 652k candles. Watch the eigenvalues. If they stabilize, you are done. If they oscillate with regime, *then* you have evidence for something more. Not before.

---

## Question 2: What is the right k (subspace rank)?

The proposal asks this but does not propose an answer. I will: k should be small. The noise subspace captures the *shared structure* -- the facts that co-occur regardless of outcome. In a space of ~53 facts, the "boring" manifold is likely low-rank. Start with k=4. If residuals are still dominated by noise (high cosine between residuals across different candles), increase. If residuals are sparse and diverse, k=4 was enough.

The right test: after projecting out noise, do Buy-residuals and Sell-residuals look different? Measure prototype separation in the journal. If separation improves over the current system, k is in the right range. If separation degrades, k is too high -- you are stripping signal.

This is the most important parameter in the proposal. It deserves a calibration protocol, not a guess.

---

## Question 3: Should the residual be L2-normalized?

Yes. The journal's `predict` uses cosine similarity. Cosine is magnitude-invariant, but the *accumulator* that builds prototypes is not. If residual vectors have wildly different norms (which they will -- subtracting a large projection from a small thought gives a tiny vector, subtracting a small projection gives a large one), then prototype accumulation will be dominated by the large-norm residuals.

Normalize after subtraction. This is not a design choice, it is a consequence of how `bundle` and `observe` compose. The alternative is to verify that the journal's accumulator already normalizes internally -- if it does, skip this. But do not leave it unexamined.

---

## Question 4: Can the noise subspace strip everything?

Yes, if k is too high relative to the actual dimensionality of your thoughts. With k=4 and ~53 facts in D=10,000, this is extremely unlikely. The projection captures at most k dimensions. The residual lives in D-k dimensions. The floor is the thought's energy outside the top-k noise directions.

The real risk is not "zero residual" but "residual that is random noise" -- if the noise subspace captures the *signal* directions (because signal and noise are correlated), the residual is orthogonal to everything useful. This is why Question 1 matters: learn from Noise-only candles, not all candles. If you learn from all candles, the subspace captures whatever is most common, which may include signal.

---

## Question 5: Should calendar facts be standard?

Yes. The proposal argues this well:

> "RSI oversold during Asian session" is a different thought than "RSI oversold during US session."

This is a statement about the semantics of `bind`. When you bundle `(bind rsi-oversold asian-session)`, you get a vector that is dissimilar to `(bind rsi-oversold us-session)`. That is the point of bind -- it makes context structural. If time context matters to any observer, it should be available to every observer. Let the noise subspace strip it where it does not matter.

The current design where Narrative exclusively owns calendar is an artificial constraint. Calendar is not a narrative concept. It is a contextual fact. Move it to standard.

---

## Question 6: Principled discovery of vocab combinations?

No. And that is fine.

The proposal asks for a principled method. There is none that does not itself require the thing you are trying to avoid (exhaustive search). The design already provides the right answer: the Observer is parameterized by vocabulary. The curve judges. Start with the six you have (five specialists + one generalist). If the curve says the generalist adds value, you have evidence that cross-domain composition works. Then try pairs if you want.

But I would not. The combinatorial space is O(n^2) for pairs, O(n^3) for triples. The generalist already sees everything. If the noise subspace works, the generalist IS the principled way to discover cross-domain signal -- it sees all facts, strips the boring ones, and whatever remains is what the journal can learn from. A pair observer is just a generalist with a smaller vocabulary. The noise subspace makes that redundant.

Option E (tiered composition) should be discarded. It adds architectural complexity to solve a problem the noise subspace already solves.

---

## The Candidate Thoughts

The proposal lists eight candidate thought categories: recency, distance from structure, candle character, velocity, relative participation, self-referential, market session depth, and sequence.

My assessment:

**Add**: Recency and distance-from-structure. These are *relational* facts that vary per candle and are not captured by any existing module. "Time since last RSI extreme" is a scalar that changes every candle. "Distance from 24h high" is a scalar that changes every candle. They satisfy all four criteria: varying, plausibly predictive, not duplicated, cheap.

**Add**: Relative participation (continuous volume ratio). You already have binary volume zones. The continuous scalar carries more information than the zone boundary. This is the difference between "volume is high" and "volume is 2.3x average." The scalar encodes the degree. Add it.

**Do not add**: Self-referential thoughts. This is the observer encoding its own state into its own input. This is a feedback loop. The observer's accuracy and confidence are *about* the journal, not *about* the market. If you encode "my recent accuracy is 0.62" as a fact, the journal learns "when I think I'm accurate, predict Buy" -- which is not a market fact, it is a self-fulfilling prophecy. The curve already judges accuracy externally. Do not feed the judge's opinion back into the defendant's testimony.

**Do not add yet**: Candle character (doji, hammer, engulfing). These are named patterns that decompose into facts you already encode: upper-wick vs body ratio, lower-wick vs body ratio, close vs open. If the bundle of `(upper-wick > body) + (lower-wick < body) + (close < open)` does not already give the journal what "shooting star" gives a human, adding the name will not help. The algebra does not know names; it knows geometry. The geometry is already there.

**Do not add yet**: Velocity (ROC of ROC). The proposal notes this is already in oscillators. Moving it to standard adds duplication. If momentum's noise subspace strips it, that is evidence it does not help momentum. If the generalist's noise subspace keeps it, it helps cross-domain. The existing placement is correct until evidence says otherwise.

**Add if cheap**: Session depth as a continuous scalar alongside the binary session fact. This is analogous to the volume argument -- "first 30 minutes of US open" carries more information than "US session." But only if the computation is trivial (it is: candle timestamp mod session length / session length).

**Sequence as scalar**: Yes, replace the boolean zone with a continuous count. `(bind consecutive-up (encode-log count))` is strictly more informative than `(bare consecutive-up-3plus)`. The zone is a lossy compression of the scalar. Remove the zone, add the scalar.

---

## Where The Proposal Is Right

The core insight -- "the Observer IS the two-stage pipeline" -- is the strongest part of this proposal. The sentence:

> The "generalist" is just `vocab = all modules`. A specialist is `vocab = one module`. A cross-domain observer is `vocab = two modules`. The pipeline is the same. The vocabulary is configuration.

This is exactly right. The observer was already parameterized by vocabulary. Adding the noise subspace parameterizes it by *what boring means for this vocabulary*. The pipeline is uniform. The configuration varies. This is simple.

The learning split is also correct:

```scheme
(match outcome
  :noise (update (:noise-subspace observer) thought)
  _      (observe (:journal observer) residual outcome weight))
```

Noise outcomes teach what is boring. Directional outcomes teach what predicts -- from the residual, not the raw thought. The two learning paths use the same thought vector but feed different primitives. No coupling. No shared state. Data flows one direction.

---

## Where The Proposal Is Wrong

The `good-state-subspace` in the current `observer.wat` learns from discriminant vectors -- it captures "what good learning looks like." The proposal does not address the interaction between the noise subspace and the good-state subspace. These are two OnlineSubspaces on the same observer. One learns what thoughts are boring. The other learns what discriminant states are accurate. They operate on different inputs (thought vectors vs discriminant vectors), so they do not interfere. But the proposal should acknowledge them both explicitly rather than presenting the noise subspace in isolation.

---

## Conditions For Approval

1. **Specify k calibration protocol.** Do not ship an unexamined k. The review for Question 2 above gives one concrete protocol: measure journal prototype separation with and without the noise subspace at k=2,4,8. Document results. Pick the k that maximizes separation.

2. **Do not add self-referential thoughts.** The feedback loop argument is not speculative -- it is structural. An observer encoding its own accuracy into its own input creates a fixed point that may have nothing to do with market direction. Remove this from the candidate list.

3. **Address interaction with good-state-subspace.** One paragraph in the spec is sufficient. They operate on different vector spaces (thought vs discriminant). State that explicitly so future readers do not wonder.

4. **Calendar facts move to standard.** The proposal argues for this. Make it a commitment, not a question. The noise subspace handles the case where time does not matter for a given observer.

These four conditions are concrete and implementable. Meet them and the design is approved.

---

## Summary

The two-stage pipeline is a composition of `online-subspace` and `journal` -- two existing primitives, not a new one. The vocabulary-as-configuration principle holds. The learning split is clean. The interface is preserved. The design is simple in the Hickey sense: the components are not interleaved, they are composed.

The conditions above are about rigor, not architecture. The architecture is sound.
