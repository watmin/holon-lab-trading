# Review — Proposal 031: Broker Derived Thoughts

**Reviewer:** Brian Beckman  
**Date:** 2026-04-12  
**Verdict:** Approve with two precision caveats and one open question that must be answered before implementation

---

## The Algebraic Question

The proposal's motivating claim is correct. Let me state it precisely and then verify it.

**Claim:** The noise subspace (CCIPCA, k=8 principal components) strips the constant
component from the broker's input vector. If the most predictive feature of a broker's
situation is "which exit observer am I paired with" — and that pairing is fixed — then
the corresponding direction in the high-dimensional space is absorbed into the subspace
as a principal component. After `anomalous-component()`, it is gone. The discriminant
cannot recover it.

This is not a defect. This is the noise subspace doing its job. Constants are noise.
What varies is signal. The question is whether the nine derived thoughts provide signal
that (a) varies per candle and (b) is not already algebraically entailed by what the
reckoner already sees.

---

## Algebraic Analysis of Each Derived Thought

### Group 1: Ratio thoughts (trail/ATR, stop/ATR, risk-reward, conviction/vol)

These are products and quotients of existing scalar dimensions. In standard analysis,
nonlinear functions of features can carry information that the raw features do not —
specifically when the response surface is multiplicative rather than additive.

The broker's reckoner sees a bundled vector of opinions, extracted facts, and
self-assessment. That bundle is a superposition — component additions in high-dimensional
space. Superposition is a linear operation on the underlying scalar encodings.

A ratio `trail / atr-ratio` encodes to `bind(atom("trail-atr-multiple"), encode-log(trail/atr))`.
The key observation: `encode-log(trail/atr) = encode-log(trail) - encode-log(atr)` in
the log-scalar basis (log maps multiplication to addition, ratio to subtraction). This
is a NEW direction in the high-dimensional space — it is NOT obtainable by any linear
combination of `encode-log(trail)` and `encode-log(atr)` separately, because those
exist as separate bound facts (`bind(atom("trail"), ...)` and `bind(atom("atr-ratio"), ...)`).
The atom bindings orthogonalize them.

**Verdict on Group 1:** The ratio thoughts are algebraically independent of their raw
components in the VSA basis. They carry genuinely new information. They will survive
the noise subspace if they vary. The proposal argues they vary. I accept the argument.

### Group 2: Rate thoughts (activity-rate)

`Log("activity-rate", paper-count / paper-duration)` — same reasoning as Group 1.
`paper-count` and `paper-duration` may or may not exist as raw facts in the bundle.
If they do not, `activity-rate` is the only encoding of this ratio. If they do, the
ratio is still algebraically independent (same atom-binding argument). Correct either way.

### Group 3: Difference thought (self-exit-agreement)

`Linear("self-exit-agreement", broker-grace-rate - exit-grace-rate, 1.0)` — this is
a difference of two rolling rates. In the linear-scalar basis, subtraction IS linearly
representable from the two components. HOWEVER: the individual rates are not in the
bundle as named scalar facts. `broker-grace-rate` and `exit-grace-rate` are scalar
f64 fields on the broker and exit observer respectively — they appear in the
self-assessment block, but as separate atoms. The difference, bound to its own atom
`"self-exit-agreement"`, is a new bound thought. Algebraically independent: approved.

### Group 4: Compound thoughts (exit-confidence)

`Linear("exit-confidence", exit-grace-rate * exit-avg-residue, 1.0)` — the product
of two scalars that exist separately in the bundle. The same atom-binding argument
applies: the product occupies a new direction. But there is a subtlety here.

`exit-avg-residue` is a measure of anomaly score. Anomaly scores from CCIPCA are
NOT stable across regimes — they depend on what the noise subspace has learned.
As the noise subspace evolves, `exit-avg-residue` changes its distribution even
if market structure is constant. This means `exit-confidence` is entangled with the
online learning process itself. This is not an error — it is a feature. The broker
learns that "this exit is confident in THIS regime." But it should be named precisely.

### Group 5: Excursion ratio

`Linear("excursion-trail-ratio", excursion-avg / trail, 1.0)` — note that `excursion-avg`
comes from scalar accumulator output, not raw candle data. It is itself a learned quantity.
Same regime-entanglement as Group 4. Same conclusion: intentional and correct, but
name it precisely in documentation.

### Group 6: Anomaly norms (market-signal-strength, exit-signal-strength)

`Log("market-signal-strength", norm(market-anomaly))` and similarly for exit.

These are the most interesting. The anomaly vector IS the residual from the
noise subspace — the component of the input that k=8 principal components cannot
explain. Its L2 norm is a scalar measure of how unusual this candle is, in the
broker's background model of normal candles.

This encodes the norm of the residual after projection. The noise subspace sees
the FULL vector (including all bundled thoughts) and strips the predictable component.
The norm of what remains is then RE-ENCODED as a new scalar fact and bundled back in.

Does this create a feedback loop? Let me check the sequencing in `propose()`:

```scheme
(define (propose [broker : Broker] [composed : Vector]) : Prediction
  (begin
    (update (:noise-subspace broker) composed)
    (let ((clean (anomalous-component (:noise-subspace broker) composed)))
      (predict (:reckoner broker) clean))))
```

The `composed` vector is built BEFORE `propose()` is called. The derived thoughts
are part of `composed`. The noise subspace update uses `composed`. The `clean` vector
is `composed` minus its projection onto the subspace. The norm of `composed` — which
is what `market-signal-strength` encodes — is computed BEFORE the noise strip.

So the sequence is: encode(derived facts including norms) → compose bundle →
noise-update → strip → predict. The norm facts are computed from the input to the
broker, not from the broker's own noise subspace output. No feedback loop.

But wait — `market-anomaly` and `exit-anomaly` are residuals from the MARKET OBSERVER
and EXIT OBSERVER noise subspaces, not from the broker's noise subspace. The proposal
says:

> Market anomaly norm and exit anomaly norm. Two f64s. Computed at the grid level
> before sending. Or computed in the broker thread from the vectors already on the pipe.

The market observer's `anomalous-component()` output is the input to the exit observer's
composition. Its norm is computed at the grid level. This is clean — no self-reference.
The broker's own noise subspace sees these norms as part of its input and will strip
them if they are constant. They will not be constant because the market observer's
subspace is also evolving. Approved.

---

## Two Precision Caveats

### Caveat 1: The Linear scale=1.0 choices need justification

Several derived thoughts use `Linear(..., 1.0)`:

- `risk-reward-ratio`: trail/stop is a ratio of distances. Its range is bounded
  approximately (0.1, 10.0) in practice. `Linear` with scale=1.0 encodes value v
  as the fraction v/1.0 = v. For ratio > 1.0, this saturates. `Log` would preserve
  the ratio structure across the full range and match the multiplicative semantics.
  Consider `Log("risk-reward-ratio", trail/stop)` instead.

- `conviction-vol`: signed-conviction * (1/atr-ratio). `signed-conviction` is in (-1, 1).
  `1/atr-ratio` for BTC ranges roughly (20, 500). The product ranges roughly (-500, 500).
  `Linear` with scale=1.0 over this range will saturate violently. Either cap it (e.g.,
  scale=0.01) or re-examine whether the magnitude is meaningful vs just the sign.

These are not blocking — the VSA will still learn something — but the wrong scale
compresses information before it reaches the reckoner.

### Caveat 2: `excursion-trail-ratio` denominator semantics

`Linear("excursion-trail-ratio", excursion-avg / (max trail 0.001), 1.0)` — `trail`
here is the EXIT OBSERVER's predicted trail distance, not the paper's actual trail.
At the time this fact is computed for the broker's thought bundle, are we using the
exit observer's current prediction or the paper's recorded distance? These diverge as
the exit observer learns. The proposal should name which value is used.

---

## The Open Question

The proposal routes `market-anomaly` and `exit-anomaly` norms through the broker pipe.
The sequencing in the four-step loop is:

1. RESOLVE
2. COMPUTE+DISPATCH: encode candle → market observers predict → exit observers compose → brokers propose
3. TICK
4. COLLECT+FUND

The market observer's `observe()` returns `ObserveResult` which includes the cleaned
thought. The exit observer composes from the market thought. The broker receives a
composed vector. At what point does the grid compute `norm(market-anomaly)` and
`norm(exit-anomaly)` to put on the pipe?

If the market observer's `anomalous-component()` output is part of `ObserveResult`,
its norm is computable at step 2, before the broker's `propose()`. The proposal's
Option C (add f64 to the broker input tuple) is correct and sufficient. But the wat
spec for `ObserveResult` must expose the cleaned thought (not just the prediction and
edge) — confirm this is already the case before implementation.

---

## What Composes Correctly

The full pipeline composes as a category of transformations:

```
Candle → [vocab] → Vec<ThoughtAST>      -- pure function, no state
       → [encoder] → Vector             -- deterministic given atom table
       → [noise-subspace] → clean       -- online, stateful, correct
       → [reckoner] → Prediction        -- online, stateful, correct
```

The derived thoughts insert into the first arrow: they are additional elements of
`Vec<ThoughtAST>` produced by a pure function from scalars already on the pipe.
They do not touch the encoder, the noise subspace, or the reckoner. The diagram
commutes — the pipeline's algebraic structure is preserved.

The proposal adds 11 atoms to the broker's vocabulary. At D=10,000, with ~142
existing atoms, the broker's atom table grows to ~153. In a 10,000-dimensional
space, 153 orthogonal atoms is trivially supported — the expected inner product
between two random binary vectors is 0 with variance 1/D = 0.0001. The new
atoms are algebraically independent of the old ones. No dimensionality concern.

The noise subspace (k=8) will learn the 8 directions of maximum variance in the
broker's composed thoughts. If any of the 9 derived thoughts are constant (e.g.,
the broker is early, no papers yet, `activity-rate = 1/1 = 1` every candle),
they will be absorbed. They should not be: the proposal's "Why these vary" section
is correct for brokers past warm-up. The first N candles (warm-up phase) are
irrelevant — the reckoner's `proven?` gate prevents premature funding anyway.

---

## Summary

The algebraic foundations are sound. The derived thoughts are genuinely new
information in the VSA basis — not redundant linear combinations, not circular
self-references. They will survive the noise subspace if they vary, and they will
vary after warm-up.

Fix the two scale choices (risk-reward-ratio to Log, conviction-vol to a capped
Linear or Log of the ratio's magnitude with separate sign encoding). Clarify which
`trail` value `excursion-trail-ratio` uses. Confirm `ObserveResult` exposes the
cleaned thought for norm computation before merging.

The architecture extends cleanly. The nine pure functions add zero wiring complexity.
The one new pipe field (atr-ratio f64) is the smallest possible coupling. The
diagram commutes.

**Approved pending the scale corrections.**
