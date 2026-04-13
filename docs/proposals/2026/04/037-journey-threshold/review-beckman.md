# Review: Beckman

Verdict: CONDITIONAL

The proposal is sound in its impulse but asks the wrong questions. Let me answer the four, then say why.

**1. EMA vs running median?**

EMA. Not because it's simpler -- because it's algebraically closed. The EMA is a monoid homomorphism: `ema(a, ema(b, s)) = ema(a . b, s)` under the appropriate composition. It threads through your fold as a single scalar accumulator -- the same structure you already use everywhere. A sorted buffer for the median is a different algebraic species entirely: it requires ordering, insertion, and a non-compositional readout. You'd be introducing a data structure that doesn't compose with your existing fold just to get robustness to outliers. But your weight channel (residue) already handles outlier importance. Don't solve the same problem twice in two different algebras.

**2. Per-broker or per-exit?**

Per-broker. The proposal already knows why: isolation. Each broker is an accountability unit binding one market observer to one exit observer. The EMA characterises *that broker's* error distribution. Per-exit would pool across market observers, contaminating the signal. Sample size concerns are real but the EMA's exponential weighting means it converges in ~3/alpha observations. At alpha=0.01 that's ~300 candles -- well within a single broker's lifetime. The algebra says: the accumulator belongs to the unit it measures.

**3. Fixed or learned alpha?**

Fixed. Alpha is a hyperparameter of the observation process, not a parameter of the model. Learning alpha from the same signal it smooths creates a circular dependency -- the threshold would chase its own tail. If you want regime sensitivity, use two EMAs (fast and slow) and take the slower one. That's still a pure fold over a product type `(ema_fast, ema_slow)`. But don't optimise alpha from within the loop.

**4. Initial value 0.5?**

Seed from the first observation, not from a guess. Set `ema_error = first_error` on the first candle. This costs you one branch (`if count == 0`) and eliminates the cold-start bias entirely. The EMA is then always grounded in measurement. The alternative -- spending N observations to compute a seed -- is a bootstrapping problem you don't need to solve. One observation is enough because the EMA is self-correcting by construction.

**The conditional.** Proposal 036 resolved that continuous grading enters through the weight. The `is_grace` bool exists only because the rolling window demands a binary label. This proposal should state that constraint explicitly: the EMA threshold is a *projection* from continuous to binary, not a judgment. The word "Grace" carries moral weight. The threshold is just a sign function applied to `error - ema`. Name it accordingly and the algebra stays clean.
