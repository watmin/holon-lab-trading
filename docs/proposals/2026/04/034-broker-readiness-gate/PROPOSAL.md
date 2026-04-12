# Proposal 034 — Broker Readiness Gate

**Date:** 2026-04-12
**Author:** watmin + machine
**Status:** PROPOSED

## The diagnosis

The broker cannot predict Grace or Violence per-candle.

We proved this across ten runs. The proto_cos converges. The
disc_strength declines. The grace_pct degrades from 60% to 33%
over 10k candles. We tried: extracted facts (Proposal 029),
opinions (030), derived thoughts (031), learned scales (033),
bound whole vectors, 8 PCs, 32 PCs, attribution. None worked.

The data showed why: Grace/Violence is determined by EXCURSION —
how far the price moves in the predicted direction. Papers with
excursion < 0.5% are 12% Grace. Papers with excursion 2-5% are
81% Grace. Papers with excursion 5%+ are 100% Grace. The outcome
depends on the FUTURE. The broker thinks about the PRESENT.

The reckoner accumulates Grace and Violence prototypes. Both are
dominated by the candle state — which is the same for Grace and
Violence because the candle is the present, not the future. The
prototypes converge because Grace thoughts and Violence thoughts
look the same at entry time.

The broker's question was wrong. Not "will this trade produce
Grace?" but "am I ready to be accountable for this trade?"

## The readiness question

The broker knows:
- Its own grace-rate (rolling)
- Its exit's grace-rate (rolling)
- Self-exit agreement (do we align?)
- Excursion-trail ratio (are papers reaching Grace?)
- Activity rate (how loaded am I?)
- Market conviction (how sure is the market?)
- Trail and stop distances (what did the exit choose?)
- Risk-reward ratio (trail / stop)

These are READINESS indicators. Not future predictors. They
describe the CURRENT STATE of the pairing's health. When the
exit is performing well and excursion is reaching the trail and
the market has conviction — the broker is ready. When these
conditions aren't met — the broker waits.

## The learned gate

The readiness threshold is not hardcoded. It's learned from
experience. The broker's reckoner thinks about OPINIONS ONLY —
no extracted candle facts, no bound whole vectors. Just the
rolling metrics of its own performance and its components'
performance.

```scheme
;; The broker's thought — opinions only
(bundle
  ;; What the leaves decided (7 atoms)
  (linear "market-signed-conviction" signed-conviction)
  (linear "market-conviction" conviction)
  (linear "market-edge" edge)
  (log    "exit-trail" trail)
  (log    "exit-stop" stop)
  (linear "exit-grace-rate" exit-grace-rate)
  (log    "exit-avg-residue" exit-avg-residue)

  ;; The broker's own state (7 atoms)
  (linear "grace-rate" grace-rate)
  (log    "paper-duration-avg" duration)
  (log    "paper-count" count)
  (log    "trail-distance" trail)
  (log    "stop-distance" stop)
  (log    "recalib-staleness" staleness)
  (log    "excursion-avg" excursion)

  ;; Derived cross-cutting ratios (11 atoms)
  (log    "trail-atr-multiple" trail/atr)
  (log    "stop-atr-multiple" stop/atr)
  (log    "risk-reward-ratio" trail/stop)
  (log    "conviction-vol-magnitude" ...)
  (linear "conviction-vol-sign" ...)
  (linear "exit-confidence" ...)
  (linear "self-exit-agreement" ...)
  (log    "activity-rate" ...)
  (linear "excursion-trail-ratio" ...)
  (log    "market-signal-strength" ...)
  (log    "exit-signal-strength" ...))
```

25 atoms. All scalars about decisions and performance. No candle
state. No extracted facts. No bound vectors. The reckoner's
question: "given these readiness indicators, will papers
registered NOW tend to produce Grace?"

This is different from "will THIS paper produce Grace." This is
"is this a good TIME to register papers?" The answer changes
slowly — the rolling metrics change slowly. The conviction varies
per candle. The combination of slowly-changing readiness + fast-
changing conviction is the gate.

## What changes

1. **Drop bound whole vectors from broker thought.** Remove the
   4 bind(atom, vec) components. The broker doesn't need the
   candle state. The broker needs the readiness state.

2. **Drop extraction entirely from broker.** No extract_facts.
   No BrokerMarketInput/BrokerExitInput in the hot path. The
   broker receives the raw/anomaly/ast on the pipe (protocol)
   but doesn't use them for its thought bundle.

3. **Broker's noise subspace sees 25 scalar atoms only.** The
   background is simpler — rolling metrics, not high-dimensional
   candle vectors. 8 PCs may be sufficient again (or the reflexive
   subspace discovers its own K).

4. **The gate uses the curve.** If the reckoner CAN learn
   readiness — "when exit-grace-rate > 0.55 AND excursion-trail-
   ratio > 0.8, accuracy is 65%" — then the curve validates.
   The conviction varies because the readiness indicators vary
   between candles. The curve bins by conviction. Higher conviction
   = stronger readiness signals = higher accuracy. The exponential
   fits.

5. **If the curve still can't validate:** the broker's gate
   becomes the rolling grace-rate directly. Fund proportional
   to grace-rate. No curve needed. The track record IS the gate.
   This is the fallback.

## Why this might work

The broker at 8 PCs produced 60% Grace at candle 1000 before
degrading. The early papers resolved fast (near-zero defaults).
The readiness indicators at that point were: fresh exit, no
history, everything near bootstrap. The reckoner saw variation
in the bootstrap phase that correlated with outcomes.

As the distances grew and papers lived longer, the candle state
(which the broker bundled) dominated the thought. The readiness
indicators (which were the real signal) got drowned. With
opinions-only, the readiness indicators ARE the thought. The
candle state is absent. There's nothing to drown the signal.

The per-candle conviction will vary because market-signed-
conviction varies per candle. When the market is MORE convicted
AND the exit is performing well — higher readiness. When the
market is uncertain AND the exit is struggling — lower readiness.
The bins differentiate. The curve fits.

## What Hickey said

Proposal 030 review: "Drop the extracted facts. Run opinions-only
first. Measure. Add context back only if needed."

The datamancer overruled him. We ran with everything. The broker
couldn't separate. We proved that the candle state drowns the
signal. Hickey was right. The broker thinks about decisions and
performance, not candle state.

## What doesn't change

- Market observer encoding and learning
- Exit observer encoding and learning
- The extraction pipeline (exit still extracts from market)
- The paper mechanics
- The simulation
- The raw/anomaly/ast protocol (data flows, broker chooses to ignore)
- The broker's propagate() and learning path
