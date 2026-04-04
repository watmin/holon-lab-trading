# Review: Proposal 003 — Observer Redesign

**Reviewer**: Brian Beckman (invited)
**Verdict**: **CONDITIONAL**

Condition: resolve the norm question (point 4 below) before implementation. Everything else is sound or testable.

---

## 1. Does the two-stage pipeline compose algebraically?

Yes, and beautifully. You have two operations:

- **P**: projection onto the noise subspace (a linear operator, idempotent: P^2 = P)
- **I - P**: the complementary projector (also idempotent, also linear)

The residual is `(I - P)(thought)`. The journal sees `(I - P)(thought)`. This is a clean orthogonal decomposition:

```
thought = P(thought) + (I - P)(thought)
        = noise_component + signal_component
```

The inner products are preserved in the sense that matters: `<(I-P)x, (I-P)y> = <x, (I-P)y>` because (I-P) is self-adjoint. So cosine similarity in the residual subspace is well-defined and measures exactly what you want — similarity of the non-noise parts.

The composition `journal(residual(thought))` is the composition of a linear projector followed by a nonlinear classifier. The linear part doesn't destroy information that's orthogonal to the noise — it removes *exactly* the noise and nothing else. The journal then operates on a cleaner input. This is the same pattern as whitening before classification, and it has decades of statistical justification.

One subtlety: the noise subspace is *learned*, not fixed. So P changes over time. The composition `journal . (I - P_t)` is a time-varying pipeline. This is fine as long as P_t changes slowly relative to the journal's learning rate. If the noise subspace shifts faster than the journal can adapt its prototypes, you get transient garbage. The proposal's warmup period (pass through until MIN_NOISE_SAMPLES) handles the cold start. The steady-state stability depends on CCIPCA's convergence rate, which I'll address in point 5.

**Verdict on composition**: Sound. The types close. `thought : V` goes in, `(direction, conviction) : Label x R` comes out, and the intermediate `residual : V` lives in the same vector space. The pipeline is `V -> V -> Label x R`. Clean.

## 2. Observer as product type: (vocabulary, labels, window)

This is the heart of the abstraction and it's nearly right. Let me formalize it.

An Observer is a triple `(V, L, W)` where:
- `V` is a subset of the fact module registry (a set from a powerset lattice)
- `L` is a label type (Buy/Sell, Healthy/Unhealthy, Hold/Exit)
- `W` is a window parameter (natural number, the lookback)

The claim is that these are independent axes — that the pipeline `encode(V) -> noise_strip -> journal(L)` works for any valid triple.

**V and L are independent**: Correct. The vocabulary determines what goes into the thought vector. The labels determine what the journal learns to discriminate. These are genuinely orthogonal concerns. You can combine market facts with Health/Unhealthy labels (weird, but type-safe) and the algebra still works — the journal just learns a different discriminant.

**V and W are independent**: Correct. The vocabulary determines the spatial content. The window determines the temporal resolution. These don't interact at the type level.

**L and W are independent**: Correct. The label type is about what you're learning; the window is about how far you look to resolve it.

So yes, `Observer = Vocabulary x Labels x Window` is a legitimate product type. The projection functions are well-defined: given an observer, you can extract any axis without knowing the others. The pipeline is parametric in all three.

One caution: the *semantic* independence doesn't mean *statistical* independence. Certain vocabulary-label combinations will produce degenerate journals (zero discriminative power). That's not a type error — it's a value-level concern. The algebra permits it; the curve rejects it. This is the right separation of concerns.

## 3. Standard vocabulary: coupling or shared basis?

This is a question about the tensor structure of the encoding.

When all observers share calendar facts, those facts contribute the same bound vectors to every thought. If we write `thought_i = specialist_facts_i + calendar_facts`, then the shared component is additive. In the bundle (superposition), shared facts reinforce across observers' thoughts.

Is this coupling? No — and here's why. The noise subspace handles it. If calendar facts are statistically uninformative for a given observer, they land in P (the noise projector) and get stripped. If they're informative (Asian session matters for volume), they survive in (I-P). The mechanism is self-regulating: shared facts only persist where they carry signal.

This is actually better than the alternative (each observer choosing its own context facts), because it guarantees that cross-domain correlations involving time are *representable* in the generalist's thought space. If only Narrative sees time, the generalist — which bundles all specialists — can only see time through Narrative's lens. If everyone sees time, the binding `bind(time_role, session_filler)` interacts with every other fact in the bundle, creating the cross-domain conjunctions the proposal identifies as the generalist's unique value.

Shared basis, not unwanted coupling. The noise subspace is the decoupling mechanism.

## 4. The norm problem: `difference(thought, project(noise, thought))`

Here is where I need to slow down and be precise.

The proposal writes:

```scheme
(define residual (difference thought noise))
```

where `noise = (project noise-subspace thought)`.

In your `primitives.py`, `difference` is:

```python
delta = after.astype(float) - before.astype(float)
return threshold_bipolar(delta)
```

And `project` returns `threshold_bipolar(projection)`.

So the actual computation is:

```
noise_continuous = sum_i (dot(thought, u_i) / ||u_i||^2) * u_i
noise_bipolar = threshold(noise_continuous)
residual = threshold(thought - noise_bipolar)
```

There are two thresholding steps: one after projection, one after subtraction. Each maps to {-1, 0, +1}.

This is NOT an orthogonal projection in the continuous sense. Thresholding the projection before subtracting it means you lose the guarantee that `<residual, noise> = 0`. The bipolar projection is an *approximation* of the geometric projection, and the error introduced by double-thresholding depends on how many dimensions are near zero (where thresholding flips the sign).

However — and this is important — you're working in bipolar hyperdimensional space, where everything is already {-1, 0, +1}. The continuous projection lives in R^d, but your vectors live on the hypercube vertices. The threshold is the *retraction* back onto the manifold. It's the same retraction you apply after every bundle. So while the algebra isn't exact in R^d, it's the *best approximation* in {-1, 0, +1}^d, which is where your algebra actually lives.

The norm question: `||residual||` will be close to `||thought||` when the noise subspace captures a small fraction of the variance, and significantly smaller when it captures a lot. In bipolar space, the norm is approximately `sqrt(D - zeros)`, where zeros are the dimensions that cancel to zero. More noise stripped = more zeros = lower norm. This is fine for the journal's cosine similarity (cosine normalizes by norm), but it changes the *magnitude* of bundles downstream.

**My recommendation**: do NOT re-normalize the residual. The reduced norm is *information* — it tells the journal "this thought had less non-noise content." A thought where 45 of 53 facts are noise should produce a weaker signal. Let the conviction reflect that. If you normalize, you're saying "a thought with 3 real facts is as loud as one with 50," which is false.

But: verify empirically that the journal's prototype accumulation doesn't develop a norm bias. If early residuals (warmup, small noise subspace, big norms) dominate later ones (mature subspace, small norms), the prototypes skew toward early data. The journal's accumulator should handle this if it normalizes inputs — check that it does.

## 5. Memory vs forgetting: CCIPCA and regime shifts

CCIPCA with `amnesia = 1.0` computes a running average: each new observation has weight `1/n`, so the influence of any single observation decays as `O(1/n)`. After 100,000 updates, the last observation contributes 0.001% to each eigenvector. This is *effectively* infinite memory — old data never truly disappears, it just gets diluted.

With `amnesia > 1.0` (your default is 2.0), the effective weight of observation t is proportional to `t^(amnesia-1) / sum`, which gives more recent observations disproportionate influence. This is a polynomial forgetting schedule, not exponential. It's gentler than EMA-style decay.

For regime shifts, the question is: how many observations does it take for a new regime's noise structure to dominate the eigenvectors?

With `amnesia = 2.0` and n observations, the effective window is approximately `sqrt(n)` observations. After 10,000 Noise-labeled candles, the effective window is ~100 candles. This is actually quite adaptive — a new regime that persists for 100+ candles will reshape the noise subspace.

But there's a subtlety for this proposal: the noise subspace only updates on Noise-labeled candles. If 40% of candles are Noise, you get 40,000 updates out of 100,000 candles. Effective window is ~200 candles, which is ~17 hours at 5-minute resolution. That's responsive enough for intraday regime shifts but slow for flash crashes.

The proposal's question about no-decay vs exponential-decay vs engrams is well-posed. My mathematical opinion: start with the existing `amnesia = 2.0` (polynomial forgetting). It's the middle ground — it forgets, but not catastrophically. The eigenvalue trajectories over 652k candles will tell you whether the noise manifold is stable (eigenvalues plateau) or drifting (eigenvalues wander). If they plateau, reduce amnesia toward 1.0. If they wander, increase it or investigate engram snapshots.

Do NOT start with engrams. That's a premature optimization of the memory structure. Let the simplest forgetting schedule run first.

## 6. Capacity budget and the noise subspace

The Kanerva bound of ~100 facts at D=10,000 is the right way to think about it, but the noise subspace changes the analysis in a helpful way.

The bound comes from the Johnson-Lindenstrauss lemma applied to bipolar vectors: you can superpose ~D/log(D) approximately orthogonal vectors before interference dominates. At D=10,000, that's roughly 10000/13 ~ 770 in theory, but the practical bound for *recoverable* facts (cosine > 0.1 after cleanup) is much lower, around D/100 ~ 100.

The noise subspace effectively reduces the fact count for the journal's purposes. If P captures a k-dimensional subspace and 45 of 53 facts project almost entirely onto it, then the residual contains ~8 "effective" facts. The journal sees a thought with 8 significant components, well within the capacity bound.

This means the budget is more forgiving than the proposal suggests. You could push to 80-100 raw facts and the noise subspace would keep the effective count manageable. The noise subspace acts as a *capacity amplifier* — it lets you encode more raw information because the journal only sees the non-redundant part.

However: the noise subspace itself has a capacity limit. With k eigenvectors, it can capture at most k dimensions of noise. If k=64 and you have 45 noise facts that span more than 64 dimensions (because bound role-filler pairs are not aligned), some noise leaks through. The choice of k matters. Too small and noise leaks; too large and you risk capturing signal dimensions.

The right k is not `number_of_noisy_facts`. It's the intrinsic dimensionality of the noise manifold, which is an empirical quantity. Start with k=32 or 64, plot the eigenvalue spectrum, and look for the elbow.

## 7. Domain-agnostic Observer table

The table in the proposal:

| Domain | Vocabulary | Labels | Question |
|--------|-----------|--------|----------|
| Market | RSI, MACD, ... | Buy / Sell | Direction? |
| Risk | Drawdown, accuracy, ... | Healthy / Unhealthy | Safety? |
| Exit | P&L, hold duration, ... | Hold / Exit | Close? |

Does the abstraction hold? Let me check the types.

The pipeline is: `encode(V) : Facts -> V`, then `(I - P) : V -> V`, then `journal.predict : V -> (L, R)`.

For the abstraction to hold, the encoding must be *domain-agnostic* — the `encode` function must work the same way regardless of what facts you feed it. Since encoding is role-filler binding (`bind(role, value)` for each fact, then `bundle`), and role-filler binding doesn't care what the roles *mean*, only that they're distinct atoms — yes, the encoding is domain-agnostic. Risk facts bind the same way as market facts.

The noise subspace is domain-agnostic: it learns principal components of whatever vectors you feed it. CCIPCA doesn't know it's looking at market data vs risk data.

The journal is domain-agnostic: it accumulates prototypes under labels. It doesn't know Buy/Sell from Healthy/Unhealthy.

So the abstraction holds at the type level. The pipeline is genuinely parametric over `(Vocabulary, Labels, Window)`.

Where it might leak: the *vocabulary modules* themselves are domain-specific. Computing RSI requires candle data. Computing drawdown requires portfolio state. The Observer doesn't compute facts — it receives them. As long as the fact-generation layer is separate from the Observer pipeline (which it is — `vocab/` modules return `Fact` data, the encoder renders), the abstraction is clean.

One potential leak: the `Window` axis. For market observers, the window is candle-count lookback. For risk observers, the window might mean something different (number of trades? calendar time?). If `Window` is truly just a natural number fed to the same windowing mechanism, it's clean. If different domains need different windowing semantics, the product type breaks and you need `Window` to be a sum type (enum of windowing strategies). Worth watching.

## Summary

The mathematics is sound. The two-stage pipeline is an orthogonal decomposition composed with a classifier — a pattern with deep roots in statistical learning theory. The Observer product type is clean and the axes are genuinely independent at the type level. The standard vocabulary is handled correctly by the noise subspace (self-regulating shared basis, not coupling). The capacity analysis is conservative in a good way — the noise subspace gives you more headroom than you think.

The one thing to get right before implementation: understand that `difference(thought, threshold(project(...)))` introduces quantization error from double-thresholding. It's probably fine in high-dimensional bipolar space (errors wash out), but measure the cosine between the continuous residual and the bipolar residual on real data. If they diverge, consider keeping the projection in continuous space before subtraction, and only thresholding the final residual once.

The decision to start with `amnesia = 2.0` (polynomial forgetting) and no engrams is mathematically conservative and correct. The eigenvalue spectrum will tell you when to revisit.

This is a well-composed system. Two existing primitives, one new composition, no new axioms. That's how you know the algebra is working.
