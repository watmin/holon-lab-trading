# Review: Rich Hickey

Verdict: APPROVED

## What is right here

The proposal has diagnosed the actual problem correctly. The noise
subspace is doing its job — it removes constants. The best predictor
is a constant. Therefore the reckoner sees noise. The response is not
to fight the mechanism but to give it something that varies. That is
the right move.

The nine derived thoughts are pure functions. Values in, values out.
No new state. No new pipes beyond three f64s. No new learning paths.
No new wiring topology. This is addition by composition, not by
complexity. I respect that restraint.

The framing — "relationships, ratios, interactions" — is correct
vocabulary. A ratio varies even when its numerator and denominator
are individually predictable. The market is not ATR. The market is
not trail. The market is ATR relative to trail. That relationship
changes every candle because ATR changes every candle. This is simple
thinking. Simple in the real sense: not conflated with anything else.

The decision to keep this in vocabulary — `src/vocab/broker/derived.rs`
— rather than special-casing it in the broker thread is architecturally
sound. The broker shouldn't know *what* it's encoding. It should
receive thoughts and bundle them. The vocabulary is where knowledge
about what matters lives. Derived thoughts belong there.

## What is worth examining

### 1. Nine is more than zero — and that is the right experiment

I've seen proposals where "let's try nine things" is a smell. Throwing
features at a problem without a theory. This is not that. Each of the
nine corresponds to a legible question:

- Is my trail wide or tight for this volatility regime?
- Is the exit performing like itself?
- How active is the paper stream?
- How anomalous is the market signal right now?

These are meaningful questions. They will have answers in the data. The
proposal earns its nine by explaining *why each varies* and *what
question it answers*. That is the minimum bar for a derived feature.
You cleared it.

### 2. The ATR solution is correct but needs to be precise

Option C — add ATR-ratio as one f64 on the broker pipe — is right.
Not because it is simplest (though it is), but because it is *already
a value*. ATR-ratio exists. It is computed. It lives on the enriched
candle. Passing it is not adding new information to the system; it is
routing existing information to where it is needed.

Option A and C are the same thing stated differently. Option B
(anomaly norm as volatility proxy) complects two distinct concepts:
"how anomalous is the candle" and "how volatile is the market." Those
are not the same question. Thought 8 should remain market-signal-strength
and mean what it says. Do not use it to approximate ATR.

### 3. Watch the interaction between thought 4 and accumulator warmup

Exit-confidence is `grace-rate × avg-residue`. Both are rolling
averages. In the first N papers, both are near zero (or undefined).
The product of two cold values is colder than either alone. The broker's
reckoner will see near-zero exit-confidence for the entire warmup
period, and it will learn that zero exit-confidence is associated with
whatever outcomes happen to occur during warmup.

This is not a reason to reject the proposal. It is a reason to ensure
that the accumulator's warm threshold is treated the same way the
broker's reckoner treats its own warmup — predictions gated until
sufficient data exists. If that gate already exists on the reckoner
side, the leakage is bounded. Verify it.

### 4. Thought 5 — self-exit-agreement — is the most interesting one

`broker-grace-rate - exit-grace-rate` measures whether this broker
is performing like its exit observer's general performance. If the
exit is doing well everywhere but this broker is doing badly, the
broker is learning that this particular market observer + exit pairing
has a problem. If both are struggling, the problem is the market.

This is structural information about the pairing that no other thought
carries. The other eight thoughts describe the market state. This one
describes the relationship between the two observers. It will behave
differently from the others in the reckoner — it will have longer
autocorrelation because grace rates change slowly. The reckoner should
handle this correctly (it sees variance over time), but it is worth
watching whether this thought dominates the bundle.

### 5. Naming: be precise about what "norm" means

Thoughts 8 and 9 use `(norm market-anomaly)` and `(norm exit-anomaly)`.
The norm of a residual vector after noise removal is a meaningful value:
it measures how far this candle is from the principal components of the
noise subspace. That is correct — a large norm means a distinctive
candle.

But make sure this is the *anomaly vector's norm*, not the original
encoded vector's norm. The original vector has approximately constant
norm by construction (VSA guarantees). The anomaly vector's norm varies.
If the wrong vector is normed, thought 8 becomes a constant, and the
noise subspace will strip it.

## What I would not do

Do not add more than these nine at this stage. The reckoner will now
have market thoughts + exit thoughts + extracted thoughts + derived
thoughts. The bundle is getting full. Before adding more, measure
whether these nine move the Grace rate. If they don't, the problem
is not the features — the problem is somewhere else, and you will
need to look elsewhere.

Do not add derived thoughts that are functions of other derived thoughts.
Thought 3 (conviction-vol) is already an interaction term. Thought 4
(exit-confidence) is already a product. Do not build derived-of-derived
terms now. The reckoner doesn't care about polynomial order — it cares
about variance — but humans reading the results need to understand what
they're looking at. Keep the derivation graph shallow.

## The question behind this proposal

There is a deeper question here that the proposal is circling without
naming: why does "which exit lens" predict Grace when the broker can't
find that signal? The answer is that the exit lens is correlated with
systematic differences in paper mechanics — trail widths, stop
distances, paper durations — and the broker doesn't currently have
access to the summary statistics of those mechanics in a form that
varies candle-to-candle.

The derived thoughts are attempting to reconstruct that signal from
per-candle observations. That is the right approach. But if after
this change the reckoner still can't differentiate, the question to
ask is: what does the exit-generalist broker *have* at the moment of
prediction that the exit-structure broker does not? The answer to
that question is the feature set. The proposal has taken a good step
toward that answer.

## Verdict

Approved. Nine pure functions. Three additional f64s. One new vocab
module. Architecture unchanged. These are the right tradeoffs. Verify
the anomaly-norm invariant (thought 8 and 9), gate exit-confidence
on accumulator warmup, and ship it.

Measure from the DB after the run. Not log tails. Not intuition. The
numbers will tell you whether this opened the signal or not.
