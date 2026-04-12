# Resolution: Proposal 026 — Exit Vocabulary

**Date:** 2026-04-11
**Decision:** ACCEPTED — implement with Beckman's conditions resolved

## Designers

**Hickey — ACCEPTED.** The composition fix is a correction. The
vocabulary expansion completes the exit's job. Self-assessment is
defensible because the regime atoms provide context. Without regime,
grace-rate flips sign at transitions. With regime, the reckoner
can distinguish "high grace in trending" from "high grace about to
collapse." Self-assessment lives on the exit struct.

**Beckman — CONDITIONAL.** Four conditions. All resolved:

### Condition 1: atom naming collision

`exit-kama-er` and `kama-er` encode the same field. The thought
IS the same. Two different minds having the same thought doesn't
mean the thought is different. Applying the same atom twice in a
bundle is calling an identity function on itself — the bundle's
majority vote absorbs the duplicate. It is a safe addition. No
change needed. Accept the redundancy explicitly.

### Condition 2: atom naming / count

Use the market regime module as-is. All 8 atoms: kama-er,
choppiness, dfa-alpha, variance-ratio, entropy-rate, aroon-up,
aroon-down, fractal-dim. More thoughts are better. The noise
subspace (when added) will strip what doesn't matter.

The exit gains 8 regime atoms, not 6.

### Condition 3: PropagationFacts gap

`observe_distances` currently trains on `composed-thought`. This
is poison. The exit must train on `exit-thought` — its own facts,
not the composition with market-thought.

The exit passes its input to the next layer. It may use the market
thought for computing facts. But it does not compose with it. It
does not BE it. The broker may choose to compose them. The broker
may not. Do not assume for the broker. Do not couple the exit's
thoughts with its input.

The fix: `PropagationFacts` gains `exit_thought: Vector`. The exit
observer's `observe_distances` receives `exit_thought`, not
`composed_thought`. The exit's reckoners query on `exit_thought`.
The exit's reckoners train on `exit_thought`. Prediction and
learning aligned — same principle as Proposal 024.

This threads `exit_thought` through the pipeline the same way
Proposal 024 threaded `market_thought`.

### Condition 4: rolling window for self-assessment

Agreed. Cumulative grace-rate is not useful for regime detection.
Rolling window of the last 50-100 observations. The exit observer
tracks a ring buffer of outcomes and computes grace-rate and
average residue from the window. The atoms reflect recent
performance, not lifetime performance.

## The changes

1. **Exit reckoner input:** `exit-thought` only, not composed.
   Both query and training.

2. **Exit vocab gains regime module:** 8 atoms from the market
   regime vocabulary (same encoder function, same candle fields).

3. **Exit vocab gains time atoms:** hour + day-of-week.

4. **Exit vocab gains self-assessment:** 2 atoms from a rolling
   window on the exit observer struct.

5. **PropagationFacts gains `exit_thought`:** threaded through
   broker → post → exit observer, same as `market_thought`.

6. **Exit lenses updated:** generalist gets all atoms (26 → 28
   with the 8 regime atoms instead of 6).

## What doesn't change

- The broker's composed thought.
- The broker's reckoner input.
- The market observer vocabulary.
- The simulation functions.
- The paper mechanics.
- The cascade: reckoner → accumulator → default.
