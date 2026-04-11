# Proposal 015 — Cheaper Queries

**Date:** 2026-04-11
**Author:** watmin + machine
**Status:** PROPOSED
**Follows:** Proposal 013 (diagnosis), 014 (debate + F failed)

## What we learned

Proposal 013 identified the continuous reckoner's brute-force KNN as the
315× grid slowdown. Proposal 014 debated six options. The designers agreed
on F (similarity gating) and disagreed on D vs B for reckoner internals.

F was implemented and measured. **F failed.** Zero gate hits in 2000
candles. The cosine between consecutive composed thoughts averages 0.50,
minimum 0.10. The thoughts shift massively every candle — the market
moves, the indicators change, the facts change. The premise that composed
thoughts are stable between candles is false.

The answer is not fewer queries. The answer is cheaper queries.

## The remaining options

F is eliminated. The grid from Proposal 014:

| | **Hickey accepts** | **Hickey rejects** |
|---|---|---|
| **Beckman accepts** | ~~F~~ (eliminated) | **B** — bucketed accumulators, **E** — cache grid distances |
| **Beckman rejects** | **D** — capped FIFO | **A** — single prototype, **C** — subspace |

With F gone, only D and B remain as actionable options. E (cache grid
distances for step 3c reuse) is orthogonal and trivial — do it regardless.

## New data from the F experiment

The composed thought similarity distribution:
- Mean cosine between consecutive candles: **0.50**
- Min cosine: **0.10**
- The thought manifold is HIGH VARIANCE

This tells us:
1. The reckoner's query context genuinely changes every candle.
2. Any compression must handle high-variance input — local smoothness
   assumptions are wrong.
3. The reckoner must be queried every candle. The query itself must be
   cheap.

## The question refined

The continuous reckoner answers: "given this composed thought, what
trail/stop distance?" It does this by cosine-weighting ALL stored
observations against the query thought. O(N × D).

The discrete reckoner answers: "given this thought, Up or Down?" It does
this by cosine against 2 prototypes. O(2 × D). Constant.

The gap: the discrete reckoner has 2 prototypes because the output has
2 values. The continuous reckoner has N observations because the output
has infinite values.

**D says:** cap N. The cost becomes O(cap × D). Constant. Lose old
context. Simple. Not algebraic.

**B says:** discretize the output into K buckets. K prototypes. O(K × D).
Constant. Preserve algebraic structure. One parameter (precision).

Both achieve constant-time queries. The debate is about what we lose.

## For the designers

Given that:
1. F is eliminated (thoughts are too volatile for gating)
2. The thought manifold has cosine ~0.50 between consecutive candles
3. The reckoner is queried 48 times per candle (24 grid + 24 step 3c)
4. At candle 2000, each query scans ~2000 observations at D=10000
5. The grid consumes 92% of candle time

Which achieves constant-time queries with acceptable accuracy loss?
D or B? And: can the choice be informed by the high-variance nature
of the input thoughts?
