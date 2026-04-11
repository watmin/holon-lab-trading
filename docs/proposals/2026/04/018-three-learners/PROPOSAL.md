# Proposal 018 — Three Learners, Three Labels

**Date:** 2026-04-11
**Author:** watmin + machine
**Status:** PROPOSED (revised after ignorant's first pass)
**Follows:** Proposal 017 (the learning loop)

## The insight

The enterprise has three learners. Each answers a different question.
Each needs its own signal. Today all three learn from the same paper
resolution. That's the complecting.

## The three learners

### Market observer — "does this thought precede Grace?"

The market observer encodes the moment. RSI divergence. MACD crossing.
Regime shift. Its job: spot when conditions favor a profitable trade.

**What it should learn from:** the paper's outcome. The paper IS the
stance. The enterprise deployed (on paper) with both sides. The
market judged. Was there residue? Grace or Violence.

The market observer doesn't learn "direction." Direction without a
horizon is meaningless. The market observer learns "does this context
produce Grace?" — the same question the broker asks, but on the RAW
market thought before composition with exit facts.

**Label:** Grace or Violence from the paper resolution.

### Exit observer — "what distances extract value?"

The exit observer encodes the context. ATR regime. Trend consistency.
Volatility structure. Its job: set the distances. Trail and stop.

**What it should learn from:** optimal distances from hindsight.
Replay the price history. Sweep candidates. Find the distances that
maximize residue. This IS a retroactive question — and that's correct.
Distances are a continuous optimization. The optimal distances are
knowable after the fact.

**Label:** `optimal = compute_optimal_distances(price_history, direction)`

Already implemented. Already correct.

### Broker — "can I trust this pair?"

The broker IS the composition. Market observer × exit observer. Its
job: judge the pairing. Does this specific (market, exit) combination
produce value?

**What it should learn from:** the paper's outcome. Grace or Violence.
The broker's edge is the accuracy of its conviction — how well it
predicts whether the pairing will produce Grace.

**Label:** Grace or Violence from the paper resolution.

Already implemented. Already correct.

## The paper as honest teacher

The paper IS the stance. It exists until a trigger fires. Every candle:

1. **Check existing papers.** Did any trigger fire? Trail, stop, or
   safety? If yes — the paper resolves. Was there residue? Grace or
   Violence. The old ideas are judged FIRST.

2. **Propagate the outcomes.** The resolved papers teach:
   - Market observer: Grace/Violence (did this context produce value?)
   - Exit observer: optimal distances (what would have been best?)
   - Broker: Grace/Violence (did this pair work?)

3. **Encode the new candle.** The observers think with UPDATED reckoners.
   The learning from step 1 is IN the prediction for this candle.

4. **Propose and register new papers.** New ideas informed by old outcomes.

Bad ideas cascade before new ones happen. Resolve before propose.
The four-step loop already has this order — settle (step 1) before
encode (step 2). The learning precedes the prediction.

## Papers breathe

Papers are not set-and-forget. Like real trades in step 3c, papers
should breathe. Every candle, the exit observer sees the current
context and can recommend new distances. The paper's stops move. The
trade breathes with the market.

This is the same mechanism as treasury's active trade trigger updates.
The distances are living, not frozen at registration. The exit
observer's reckoner gets smarter every candle. The papers should
benefit from that improving intelligence.

The breathing papers test the EXIT OBSERVER continuously — not just
at registration but at every candle. Did the updated distances improve
the outcome? The feedback loop tightens.

## The ignorant's critique (first pass)

The first draft proposed "pure price direction" as the market observer's
label. The ignorant found the hole:

> "Price at resolution is still sampled at a time chosen by the exit
> distances. The decoupling is circular. There is no direction without
> a horizon. The horizon is owned by the exit observer."

The fix: the market observer doesn't learn direction. It learns Grace
or Violence. The SAME outcome as the broker. The paper deployed,
the market judged, there was residue or there wasn't. The market
observer learns "does this RAW thought (before composition) precede
Grace?" That's not contaminated — it's the honest verdict of the
paper on the market observer's input.

The broker learns the same outcome but on the COMPOSED thought (market
+ exit). The market observer learns on its own thought. Each sees the
same outcome through a different lens. The factorization is clean
because the input differs, not the label.

## The attribution problem

The ignorant also found: "the broker can't attribute failure. If the
market observer was right but the exit observer set bad distances, the
broker punishes the pair."

This is correct and intentional. The broker is the PAIRING. If the
pairing fails, the broker's edge drops. It doesn't matter whose fault
it was. The broker gates the composition. A bad pairing gets low edge
regardless of which component caused the failure. The components learn
independently through their own labels. The broker learns whether the
composition works.

Over time: if a market observer is good but paired with a bad exit
observer, the broker for that pair has low edge. The same market
observer paired with a GOOD exit observer has high edge. The good
pair gets funded. The bad pair doesn't. The market observer isn't
punished — it participates in multiple pairings. The ones that work
get capital. Natural selection at the pairing level.

## Questions for the designers

1. Is Grace/Violence the right label for the market observer? Or
   should the market observer learn something the broker doesn't —
   a direction signal independent of outcomes?

2. Should papers breathe (update distances every candle)? Or should
   papers freeze their distances at registration to provide a stable
   test of the original prediction?

3. The market observer and the broker both learn Grace/Violence but
   from different inputs (raw thought vs composed thought). Is this
   redundant? Or is it the right factorization — same question,
   different perspective?

4. The noise subspace (Beckman's Theory 3): should we remove it
   simultaneously with the label fix? Or one change at a time?

5. What measurement proves this works? disc_strength rising above
   0.01 for the market observer? Grace rate crossing 50%? The
   broker's curve validating?
