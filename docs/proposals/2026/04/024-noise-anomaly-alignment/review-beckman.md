# Review — Proposal 024

**Reviewer:** Brian Beckman (simulated)
**Date:** 2026-04-10

## Is this a natural transformation?

Yes. You have two functors from Candle to Verdict:

- **F**: Candle -> Thought -> Anomaly -> Prediction (the prediction path)
- **G**: Candle -> Thought -> (stored) -> Label -> Learn (the learning path)

Before the fix, G routes through the full thought while F routes through the anomaly. The diagram does not commute. The reckoner's discriminant lives in im(f) — the noise-projected subspace — but training samples arrive from the full space. The component at each observer is not a legitimate morphism because the domains disagree.

After the fix, both paths factor through the same projection f. The component at each observer becomes the identity on im(f). The diagram commutes. This is a natural transformation between F and G, with the naturality square closing at the anomaly.

## Does the stale noise model matter?

The anomaly at candle N is computed from the noise subspace at time N. At candle N+K, the subspace has drifted. You store the *output* of f_N, not f_{N+K} applied to the old thought. This is correct. The reckoner should learn: "this specific residual vector produced this outcome." The residual is a *measurement* — it happened, it is a fact. You are not recomputing the anomaly under a newer model; you are replaying the exact input. This is the same principle as experience replay in RL: store the observation, not the observation function. The staleness of f is irrelevant because you never re-evaluate f. You store its image point.

## Does alignment preserve or destroy information?

It destroys information — deliberately. The full thought contains directions the reckoner never saw. Training on those directions teaches the discriminant to separate on axes it cannot evaluate at inference time. That is strictly harmful: it adds noise to the discriminant without adding predictive power. The alignment restricts the training distribution to match the evaluation distribution. By the data processing inequality, you cannot lose *useful* information by restricting to the sufficient statistic — and the anomaly is, by construction, the sufficient statistic for the reckoner's decision.

The memory cost (two vectors per paper) is real but orthogonal. Compress later if needed.

## Verdict

Ship it. The current system has a type error — prediction and learning operate in different spaces. The fix closes the naturality square. The stale snapshot is not a defect, it is a feature: measurements are facts, not functions. The information destroyed was never accessible to the reckoner anyway.

One suggestion: the broker's composed-thought anomaly (question 3) needs the same fix. Same diagram, same argument. Do both.
