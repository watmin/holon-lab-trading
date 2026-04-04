# Review: Beckman

Verdict: CONDITIONAL

## Overview

The proposal asks: can an observer be decomposed into a composition of two existing templates (OnlineSubspace + Journal) such that the result is still an observer? The answer is yes, and the algebra is clean. The conditions below are not objections to the architecture; they are places where the proposal leaves algebraic questions unanswered that must be resolved before implementation.

## The Central Claim: Composition Closes

The proposal composes two existing forms:

```scheme
(define residual (difference thought (project noise-subspace thought)))
(predict journal residual)
```

Let me verify this closes. The six primitives are: atom, bind, bundle, cosine, journal, curve. `difference` is derived from bundle + negate (bundle with the negation of the subtrahend). `project` is the inner product followed by scaling -- it is cosine composed with scalar multiplication. So the pipeline is:

1. `thought` is produced by `bundle` over `bind`-composed facts. This is a vector -- an element of the algebra.
2. `project` decomposes into cosine (primitive) and scalar multiplication (linear). Output: a vector.
3. `difference` decomposes into bundle + negate. Output: a vector.
4. `predict journal residual` -- journal is a primitive, consumes a vector, produces (direction, conviction).

Every step consumes vectors and produces vectors (or the journal's output type). The composition is type-correct. The observer interface -- `(direction, conviction)` -- is preserved. The manager sees the same shape it always saw. No escape from the monoid.

This is the key insight the proposal gets right: the two-stage pipeline is *internal* to the observer. The interface boundary is the observer's output, and that boundary holds. The manager cannot distinguish a one-stage observer from a two-stage observer. This is encapsulation through algebra, not through access control.

## Responses to Numbered Questions

### Question 1: Should the noise subspace learn from ALL candles or only Noise-labeled candles?

The algebra does not prefer one over the other -- both produce valid subspaces. But they answer different questions.

Learning from all candles gives you the *mean manifold* of the thought space. The projection removes the average, leaving deviations from average. This is PCA in the classical sense.

Learning from Noise-labeled candles gives you the *uninformative manifold*. The projection removes what was present when nothing happened. The residual is what distinguishes candles where something DID happen.

The second is more principled for this application. Here is why: the journal's job is to separate Buy from Sell. The noise subspace's job is to make that separation easier. If you learn from all candles, you subtract the mean of Buy + Sell + Noise -- you are removing some signal along with the noise. If you learn from Noise only, you subtract what Buy and Sell have in common with each other and with non-events. The residual preserves what distinguishes Buy from Sell while removing what they share with Noise.

Recommendation: Noise-labeled only. The algebra supports both, but the intent selects one.

### Question 7: Memory vs forgetting (decay, engrams, or lifetime)

Start with no decay. Here is the algebraic argument:

The OnlineSubspace (CCIPCA) maintains k eigenvectors. As n grows, the eigenvalues converge. If the noise manifold is stationary (or cyclical, as the proposal conjectures), the eigenvectors stabilize. A stable subspace means the projection operation converges to a fixed linear operator. This is desirable -- it means the residual computation becomes deterministic for any given thought, which is exactly what you want feeding into a journal that is building prototypes.

Decay introduces non-stationarity into the projection operator itself. Now the residual of the same thought changes over time not because the thought changed, but because the noise model changed. The journal must then track two moving targets: the residual distribution AND the projection operator. This is strictly harder.

Engrams (snapshots at regime boundaries) are algebraically sound -- a stored subspace is a frozen linear operator, and selecting among them by recognition is a valid dispatch. But this adds a layer of indirection (which subspace?) that should be justified by empirical failure of the simpler approach.

Recommendation: Start with lifetime (no decay). The 652k run will show whether eigenvalues stabilize or drift. If they drift, the data tells you decay is needed. If they cycle, engrams are the answer. Do not solve the harder problem before proving the simpler one fails.

### Question 2: Right k (subspace rank) for the noise subspace

The rank k determines the dimensionality of the noise manifold. Too low: some noise dimensions survive projection, polluting the residual. Too high: signal dimensions get captured as "noise" and stripped.

There is a principled answer: the eigenvalue spectrum tells you. After sufficient training, plot eigenvalues in descending order. There will be a gap -- large eigenvalues (noise dimensions that explain variance) followed by a drop to small eigenvalues (signal and random). k should sit at the gap.

For ~53 facts bundled into D=10,000 dimensions, the effective rank of the thought space is at most 53 (and in practice less, because facts are not all independent). The noise subspace rank should be less than the thought rank. Start with k=8 (the default the enterprise already uses for risk branches). This is conservative -- it captures the dominant noise directions without risking signal. The eigenvalue spectrum from the 652k run will tell you if 8 is too few.

Recommendation: k=8 initially, identical to the risk branch convention. Adjust empirically from the eigenvalue gap.

### Question 3: Should the residual be L2-normalized?

Yes. And the proposal is right to flag this.

`difference(thought, project(noise-subspace, thought))` changes the vector's norm. The projection removes energy. If the noise subspace captures 80% of the thought's variance, the residual has 20% of the original norm. The journal's cosine similarity is norm-invariant, but the *accumulator* that builds prototypes is not -- it bundles vectors, and vectors with smaller norms contribute less to the bundle. This means early residuals (when the noise subspace is small and removes little) would dominate prototypes over later residuals (when the noise subspace is mature and removes a lot).

L2-normalization after subtraction puts all residuals on the unit sphere. The journal sees direction, not magnitude. This is correct for the discriminant -- the question is "which direction does this unusual configuration point?" not "how much energy remained after noise removal?"

Recommendation: Normalize. The residual's direction carries the signal. Its magnitude carries information about how well the noise subspace is trained, which is a property of the learner, not the market.

### Question 4: Risk of stripping everything (zero residual)

The concern: if the noise subspace learns too well, `project(noise-subspace, thought)` approaches `thought`, and the residual approaches zero.

This cannot happen if k < rank(thought space). The subspace captures at most k dimensions. If the thought lives in a space of effective dimension m > k, at least m - k dimensions survive projection. With ~53 facts and k=8, at least ~45 dimensions survive (assuming the facts span ~53 independent directions, which is an upper bound).

The pathological case: if all 53 facts are nearly collinear (they all say the same thing), the effective rank approaches 1, and k=8 captures it entirely. But this would mean the vocabulary is degenerate -- 53 facts that are really 1 fact. That is a vocabulary design problem, not a subspace problem.

There is a practical floor: if `||residual|| < epsilon`, pass through the original thought (as the warmup path already does). This is a safety net, not a design feature.

Recommendation: The algebra prevents this for k << m. Add an epsilon floor as a diagnostic tripwire, not as a design feature. If it triggers, the vocabulary has a degeneracy problem.

### Question 5: Calendar/session facts -- Narrative-exclusive or standard?

The algebraic argument for standard: if a fact modifies the meaning of every other fact, it should be present in every bundle so that `bind(calendar, other-fact)` creates the joint encoding. If calendar is exclusive to Narrative, then `bind(calendar, RSI-oversold)` exists only in the generalist's thought (which sees all modules). The momentum specialist never sees "RSI oversold during Asian session" -- it sees "RSI oversold" without temporal context.

The noise subspace argument: if calendar doesn't matter for momentum, the momentum observer's noise subspace will learn that calendar facts are always present (they vary slowly relative to indicators) and strip them. Self-regulating.

Both arguments are algebraically valid. The question is: do you want the momentum specialist to have the *opportunity* to discover that calendar matters, or do you want to restrict that discovery to the generalist?

Recommendation: Make calendar standard. The cost is ~4 additional facts per observer (the four sessions). The benefit is that every observer can discover temporal context independently. The noise subspace handles the case where it does not matter. This aligns with the proposal's own principle: "the pipeline is the same, the vocabulary is configuration."

### Question 6: Principled discovery of vocab combinations

There is no principled a priori method within the algebra. The algebra gives you: for any set of fact modules, compose them with the two-stage pipeline and measure the curve. The curve is the empirical judge.

However, there is a principled *elimination*: if two observers with different vocab sets produce thoughts whose cosine similarity is consistently high (> 0.9), they are redundant. One can be dropped without information loss. This is measurable from the existing pipeline -- just compute pairwise cosines of observer thoughts.

The converse: if the cosine between two specialist thoughts is consistently LOW but their joint prediction (from a combined observer) is better than either alone, the combination has emergent value.

Recommendation: Empirical, but guided by pairwise cosine as a redundancy detector. Do not combinatorially enumerate -- let the curve curves tell you which observers add marginal value.

### Question for Designers: Candidate thoughts

I will evaluate each against the four criteria stated in the proposal: (1) varies across candles, (2) plausibly relates to future direction, (3) not already captured, (4) cheap to compute.

**Recency (time since last event)**: Strong candidate. Varies continuously. "200 candles since anything interesting" is genuinely different from "3 candles since RSI extreme." Not captured by any current fact -- current facts encode WHAT happened, not WHEN it last happened. Cheap: you already track the events, you just encode the distance. The encoding `bind(since-last-extreme, encode-log(candles-since))` is correct -- log scale because the difference between 3 and 5 candles matters more than the difference between 195 and 197.

**Distance from structure**: Strong candidate. Continuous scalar where current facts are mostly binary (above/below). "3% below SMA200" is a different thought than "0.1% below SMA200." The tension IS the information. Cheap: the values are already computed. Encode as `fact/scalar`.

**Candle character (doji, hammer, etc.)**: Moderate candidate. Varies, plausibly predictive. But there is overlap with the existing `price_action` module (inside/outside bars). The named morphologies are COMBINATIONS of existing candle fields (body size relative to range, wick ratios). If `price_action` already encodes the components, the named pattern may not add new information -- the bundle of components IS the pattern in the algebra. Worth testing, but lower priority than recency and distance.

**Velocity (ROC of ROC)**: Moderate. Already partially captured by `oscillators.rs` ROC acceleration. If it is there, do not duplicate. If it is only in one module, making it standard gives other observers the acceleration signal. Check whether it is truly exclusive before adding.

**Relative participation (volume vs its own MA)**: Strong. Continuous where current volume facts are zoned (spike/drought). "2.3x average" is richer than "spike." Cheap -- moving average of volume is already computed. Encode as scalar.

**Self-referential (observer's own state)**: This is the most interesting candidate and the most dangerous. The observer encoding its own accuracy, confidence duration, and recalibration count creates a feedback loop: the observer's state influences its thought, which influences its prediction, which influences its state. This is not algebraically forbidden -- the composition still produces vectors. But it is dynamically unstable in the same way Option B's positive feedback is. The journal could learn "when I have been confident for a long time, keep being confident" -- a self-reinforcing cycle. Recommendation: defer until the two-stage pipeline is stable. Then add self-referential facts and measure whether the noise subspace can regulate the feedback.

**Market session depth**: Moderate. Varies within session. But it is a refinement of calendar (which is already proposed as standard). If calendar becomes standard, session depth adds granularity. Worth testing after calendar goes standard.

**Sequence count as scalar**: Moderate. Current `price_action` fires at 3+ consecutive. The count as scalar (4 vs 7 consecutive up candles) is richer. But the marginal value over the zone encoding is unclear. The noise subspace may strip the distinction anyway.

**Priority ordering for seeding**:
1. Recency -- highest information gain, no overlap, cheap
2. Distance from structure -- continuous where current is binary, cheap
3. Relative participation -- same argument as distance, for volume
4. Calendar as standard -- not a new fact, a reclassification

These four alone add ~20 facts (recency for ~8 event types, ~4 distance measures, ~2 participation scalars, ~4 sessions reclassified). Well within the capacity budget, and each is cheap to compute.

## The Deeper Algebraic Point

The proposal's real contribution is not the two-stage pipeline for the generalist. It is the recognition that **the Observer IS the two-stage pipeline**. This is the correct generalization.

In categorical terms: an Observer is a morphism from the candle space to the opinion space. The one-stage observer is `journal . encode`. The two-stage observer is `journal . residual . encode`, where `residual = id - project(noise)`. The residual operator is a projection (idempotent, linear). Composing a projection with the journal-encode pipeline yields another morphism of the same type. The category of observers is closed under this composition.

This means you can add the noise subspace to ANY observer without changing the observer's external type. The generalist is not special. The momentum specialist benefits equally. This is the right abstraction.

The proposal gets this exactly right in the "Refinement: The Observer IS the Two-Stage Pipeline" section. The table showing Market, Risk, and Exit as instances of the same pipeline is the algebraic closure I want to see.

## Conditions for Approval

1. **Normalization**: The residual MUST be L2-normalized before feeding to the journal. The proposal asks the question; the answer is yes. Without normalization, prototype accumulation is biased by noise-subspace maturity. This is a correctness condition, not a preference.

2. **Noise-only training**: The noise subspace MUST train on Noise-labeled candles only (not all candles). Training on all candles subtracts signal along with noise. The proposal poses this as question 1; the answer must be settled before implementation.

3. **Warmup passthrough**: The proposal already specifies this (`(if (>= (n noise-subspace) MIN_NOISE_SAMPLES) ... thought)`). This must be preserved. During warmup, the observer is a one-stage pipeline. After warmup, it is two-stage. The transition must be monotonic -- once the noise subspace activates, it stays active. No toggling.

4. **Self-referential facts deferred**: Do not add observer-state-as-fact in the same change that adds the two-stage pipeline. Two feedback mechanisms introduced simultaneously cannot be independently diagnosed. The noise subspace is the first experiment. Self-referential encoding is the second, contingent on the first stabilizing.

5. **Wat first**: The observer struct in `market/observer.wat` must gain the `noise-subspace` field and the pipeline must be expressed in wat before any Rust is written. The spec is the source of truth. The current observer.wat has no noise subspace; the proposal's pseudocode must become a real wat amendment.

## What the Proposal Gets Right

- No new primitives. `online-subspace` and `journal` already exist. The composition is userland.
- The interface holds. The manager is ignorant of observer internals. This is algebraic encapsulation.
- The "Observer IS the pipeline" generalization is the correct abstraction. Configuration (vocabulary set) over specialization (different observer types).
- The capacity budget analysis is honest. Kanerva capacity at D=10,000 with ~53 facts leaves room. The noise subspace makes the budget more forgiving by reducing effective dimensionality.
- Options A through E are presented and rejected with clear reasoning. The proposal shows its work.

## What Gives Me Pause

The learning split -- Noise outcomes train the subspace, Buy/Sell outcomes train the journal -- creates a coupling between the labeling scheme and the noise model. If the threshold that separates Noise from Buy/Sell changes (which it does -- it is derived from ATR, a moving target), the noise manifold shifts. The subspace must adapt to a moving boundary. With lifetime learning (no decay), this is fine if the boundary's variance is small relative to the total manifold. With high threshold variance, the noise subspace averages across different definitions of "noise." This is not a flaw in the algebra; it is an empirical question the 652k run must answer.

The proposal is algebraically sound, architecturally clean, and empirically testable. Meet the five conditions and it is approved.

-- Brian Beckman
