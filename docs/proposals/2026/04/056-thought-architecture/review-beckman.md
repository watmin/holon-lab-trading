# Review: Beckman

**Verdict: CONDITIONAL**

Conditionally approved. The algebraic structure is sound in its core loop. The thermometer encoding is the best part of the proposal. Two concerns need resolution before I would call this clean.

---

## What composes

### The trigram/bigram construction is categorically well-formed

The arrow structure is:

```
PhaseRecord  --encode-->  Vector
Vector^3     --bind+permute-->  Trigram (Vector)
Trigram^2    --bind-->  Pair (Vector)
Pair^N       --bundle-->  Rhythm (Vector)
```

Every arrow lands in the same object: `Vector`. The category is closed. `bind` is an endomorphism on `Vector x Vector -> Vector`. `permute` is an automorphism on `Vector -> Vector`. `bundle` is a variadic operation `Vector^N -> Vector`. At every layer, you start with vectors and end with vectors. The types compose. This is a free algebra over `{bind, permute, bundle}` with the carrier set being the vector space. Good.

The permutation trick for position within the trigram is the right move. `bind(bind(a, permute(b, 1)), permute(c, 2))` gives you three distinct roles because `permute(-, k)` is an automorphism with `permute(-, 0) = id`, so the three positions are distinguished without consuming bundle capacity. The bind is a rotation (deterministic, reversible), the permute is an independent rotation. Three rotations composed. The resulting vector is a unique point in the space determined by the three inputs AND their positions. This is sound.

The bigram layer `bind(tri_i, tri_{i+1})` composes two trigrams into a single vector that preserves their conjunction. Since bind is deterministic, the same pair of trigrams always lands at the same point. Since the trigrams share two phase records (the sliding window overlaps by 2), adjacent bigrams share internal structure, which means their bind products are correlated. This is a feature, not a bug -- it creates a smooth trajectory through vector space as the market evolves.

### Thermometer encoding composes correctly under bind and bundle

This is the strongest part of the proposal. The cosine between two thermometer vectors is:

```
cos(a, b) = 1 - 2|a - b| / (max - min)
```

This is exact, linear, and monotone. No thresholding. No rotation ambiguity. The gradient is constant everywhere in the range. When you bind a thermometer vector with an atom, the bind rotates it but preserves the norm, so the cosine relation between two values of the same indicator survives the binding. When you bundle two bound facts, the thermometer's linear gradient means small differences in indicator value produce proportionally small differences in the fact vector. This is what you want for deltas.

The failure mode of `ScalarMode::Linear` (rotation-based) is real: bipolar thresholding after small rotations kills the sign. `+0.07` and `-0.07` producing identical vectors is a showstopper for a delta-based encoding. The thermometer fixes this by construction. The sign lives in which end of the vector is filled. Correct.

### The delta encoding carries ordering into the bundle

The proposal correctly identifies that the bundle is a set -- it loses the global order of pairs. The claim is that the deltas on each record carry the ordering information that the bundle discards. This is algebraically sound. Each phase record carries `same-move-delta` which is a function of the current record and its predecessor of the same type. The predecessor's identity is not in the bundle, but its effect on the current record IS in the bundle, via the scalar. This is a lossy encoding of the total order, but it preserves the first derivative -- the trend of the trend. For a reckoner that discriminates directions, the first derivative is what matters. You lose "valley 2 came before valley 3" but you keep "valley 3 was weaker than its predecessor." That is the right tradeoff.

### The capacity math is correct

The Kanerva limit for a bundle of N nearly-orthogonal vectors in D dimensions is approximately sqrt(D). This follows from the Johnson-Lindenstrauss lemma: N random vectors in D dimensions have pairwise cosine O(1/sqrt(D)), so you can pack sqrt(D) items before the cross-talk overwhelms the signal. The proposal uses this correctly:

- Inner rhythm: sqrt(10000) = 100 pairs. Each pair is a bind of two trigrams, which are themselves binds of three phase records. The bind products are approximately random (bind is pseudo-random rotation), so the near-orthogonality assumption holds. 100 pairs in 10000 dimensions is within budget.

- Outer broker thought: ~31-34 items at D=10,000 (budget 100). Comfortable headroom.

- Bind costs zero capacity. Correct. Bind is a rotation, not a superposition. Only bundle consumes the Kanerva budget.

The one place to be careful: the JL bound assumes the bundled vectors are approximately independent. The overlapping sliding window means adjacent pairs share a trigram. This introduces correlation. The effective capacity is somewhat less than sqrt(D). The proposal acknowledges this implicitly by using "take-right" trimming rather than packing to the full budget. But I would want to see an empirical measurement of the actual interference at capacity. The 3.49x separation in the proof test is measured at 50 candles (47 pairs) in 10,000 dimensions -- well under the theoretical limit. What happens at 100 pairs? At 90? Where does the separation degrade?

---

## What does not compose

### The "indicator rhythm" reuses the same atom across the window

In `indicator-rhythm`, every candle's fact uses the same atom: `(atom "rsi")`. The first candle's fact is `bind(atom("rsi"), thermometer(0.45))`. The seventh candle's fact is `bind(atom("rsi"), thermometer(0.63))`. These two facts differ only in their scalar component. When they appear in different trigrams and those trigrams are bundled, the atom is a shared constant factor. This means the atom contributes a constant direction to every fact, every trigram, every pair. It is part of the "background" that the noise subspace must learn to strip.

This is not wrong, but it is wasteful. The atom contributes nothing discriminative within a single indicator's rhythm -- it is the same in every candle. Its purpose is to distinguish this indicator's rhythm from other indicators' rhythms in the outer bundle. But within the rhythm itself, it is pure overhead. The trigram/bigram structure already distinguishes positions via permute. The atom is redundant inside the rhythm and only meaningful outside it.

The consequence: the shared atom inflates the cosine between different rhythm vectors (your 0.96 raw cosine). The subspace strips it. The system works. But the subspace is spending capacity learning the constant component when it could have been removed algebraically. Consider: if the atom were bound at the OUTER level (wrapping the finished rhythm), the inner encoding would be atom-free and the raw cosine between different regimes would already be lower, leaving more subspace capacity for learning the actual variation.

This is not a blocking concern. The subspace handles it. But categorically, a constant factor in a variadic bundle is noise by definition. The cleaner algebra would factor it out.

### The proof test is necessary but not sufficient

The proof test demonstrates:
- 3.49x residual separation between uptrend and downtrend
- 6.29x residual separation between uptrend and chop
- Raw cosine 0.9643 reduced to anomaly cosine 0.1223

These are good numbers. The subspace does what you claim. But:

1. **The data generator is too clean.** `noisy_uptrend` produces a monotone series with additive noise. Real market indicators are not monotone within an uptrend. RSI oscillates. MACD crosses zero. Volume spikes. The test proves the concept on idealized data. It does not prove it on market data. I would want to see the same test on windows extracted from `analysis.db`.

2. **The assertion threshold is too weak.** `avg_down > avg_up * 1.2` means 20% separation is passing. Your actual measured separation is 3.49x. If the threshold is 1.2x, the test passes even when the encoding is barely working. Tighten the assertion to at least 2.0x. A proof test should fail when the thing it proves stops being true.

3. **No statistical significance.** 50 test windows per class is enough for a rough check but not for a confidence interval. The test does not report standard deviations. If the uptrend residual distribution has a long tail that overlaps the downtrend distribution, the averages lie. Report the overlap. A Welch t-test or a non-parametric rank test would cost five lines and make the proof rigorous.

4. **The anomaly cosine test (`raw_cosine_vs_anomaly_cosine`) compares one pair.** N=1. This proves nothing about the distribution. Generate 50 pairs and report the distribution of cosine improvements.

### Hour and day-of-week as rhythms is categorically suspect

In `regime-core-thought.wat`, hour and day-of-week are fed through `indicator-rhythm`. This computes deltas: "hour changed by +1" or "day changed by +1". But hour wraps at 24 and day wraps at 7. The delta between hour 23 and hour 0 is -23 in linear encoding, not +1. You have `ScalarMode::Circular` for exactly this case, but `indicator-rhythm` uses `Thermometer`. The delta at the wrap point is a catastrophic outlier.

Either use circular encoding for these two (which requires a different path through indicator-rhythm), or encode hour and day as standalone facts rather than rhythms. The rhythm of "what hour is it" across 50 candles is not a meaningful signal -- it is a deterministic function of the window offset. The regime observer should encode the current time context, not the rhythm of time passing.

---

## Summary

The core algebra closes. `bind`, `permute`, and `bundle` compose correctly over vectors. The thermometer encoding is a genuine improvement over rotation-based scalars for small-delta domains. The trigram/bigram construction preserves local order while the bundle provides offset-independent recognition. The capacity math follows from JL. The delta-in-content trick for carrying ordering into an unordered container is elegant and sound.

Tighten the proof. Factor the atom out of the inner rhythm. Fix the circular-quantity problem for time features. Then this is clean.
