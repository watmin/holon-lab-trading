# Proposal 030 — Broker Thinks Opinions

**Date:** 2026-04-12
**Author:** watmin + machine
**Status:** PROPOSED

## The problem

The broker is 50/50. Grace ≈ Violence. Edge 0.0. Across 10k
candles, 24 brokers, every one blind.

The broker predicts Grace/Violence with a discrete reckoner.
The reckoner accumulates observations and builds a discriminant.
Prediction and learning are aligned (Proposal 024). The extraction
is correct (Proposal 029). The noise subspace strips. The
pipeline is clean.

The broker is blind because it thinks about the WRONG THINGS.

## What the broker thinks today

```scheme
(Bundle
  extracted-market-facts     ;; what the market found noteworthy
  extracted-exit-facts       ;; what the exit found noteworthy
  self-assessment)           ;; grace-rate, paper-duration, etc.
```

The extracted facts are WHAT the candle looked like through each
observer's lens. "RSI was noteworthy." "ATR was unusual." "Hurst
survived the noise stripping." These are the INPUTS the leaves
processed. Not the OUTPUTS they produced.

The broker's Grace/Violence is determined by the PAPER. The
paper resolves based on PRICE MOVEMENT vs DISTANCES. The distances
were set by the EXIT observer. The direction was predicted by the
MARKET observer. The broker didn't choose either. The broker is
accountable for outcomes it didn't control.

The broker knows what the candle looked like. The broker does NOT
know what the leaves DECIDED about the candle.

## What the broker should think

The broker is the MANAGER. The manager reads expert OPINIONS,
not expert INPUTS. Chapter 4 said it: "the manager doesn't look
at candles. The manager reads expert opinions. Signed convictions.
Evaluated outputs."

The broker should think about what the leaves decided:

```scheme
(Bundle
  ;; What the market observer DECIDED
  (Linear "market-direction"    signed-conviction)  ;; +0.15 = Up, -0.08 = Down
  (Linear "market-conviction"   conviction)         ;; 0.15 = how sure
  (Linear "market-edge"         edge)               ;; accuracy at this conviction

  ;; What the exit observer DECIDED  
  (Log    "exit-trail"          trail-distance)     ;; 0.008 = chosen trail
  (Log    "exit-stop"           stop-distance)      ;; 0.004 = chosen stop
  (Linear "exit-grace-rate"     grace-rate)         ;; 0.62 = exit's recent performance
  (Linear "exit-avg-residue"    avg-residue)        ;; 0.003 = exit's recent residue

  ;; Broker's own performance
  self-assessment)                                   ;; existing 7 atoms
```

These are SCALARS. The market's signed conviction. The exit's
chosen distances. The exit's performance. Scalar facts about
the DECISIONS of the leaves, not the INPUTS to the leaves.

The broker's reckoner sees: "the market said Up at conviction
0.15 with edge 0.03, and the exit chose trail 0.8% and stop 0.4%
with grace-rate 62%." The reckoner learns: "when the market was
moderately convicted and the exit had high grace-rate, Grace
followed." The reckoner can now separate Grace from Violence
because the INPUTS to the prediction carry the signal.

## The extracted facts

The extracted market and exit facts (from Proposal 029) are still
valuable. They are the CONTEXT — what the candle looked like
through each lens. The opinions are the DECISIONS — what the
leaves concluded. Both are facts. Both compose.

```scheme
(Bundle
  ;; OPINIONS — what the leaves decided (7 atoms)
  market-opinions
  exit-opinions

  ;; CONTEXT — what the candle looked like (extracted facts)
  extracted-market-facts
  extracted-exit-facts

  ;; SELF — the broker's own performance (7 atoms)
  self-assessment)
```

The opinions are the signal. The context is the background. The
self-assessment is the meta. All three compose into the broker's
thought. The reckoner finds which combination predicts Grace.

## Where the opinions come from

All of these values ALREADY EXIST on the broker's input pipe:

- `prediction` — the market observer's direction prediction (Up/Down)
- `edge` — the broker's cached_edge from propose() conviction
- Conviction — from the prediction struct
- `reckoner_dists` — the exit's recommended distances (trail, stop)
- Exit grace-rate and avg-residue — on the exit observer struct

The opinions are ALREADY FLOWING through the pipes. The broker
just doesn't encode them as facts in its vocabulary. They're
used for paper registration and distance cascading but NOT for
the broker's own reckoner input.

## What changes

1. **New vocab module:** `src/vocab/broker/opinions.rs` — encodes
   the leaves' decisions as scalar facts. ~7 atoms.

2. **Broker thread encodes opinions:** Before calling `propose()`,
   the broker bundles opinions + extracted facts + self-assessment.
   The opinions come from the pipe input (already available).

3. **The signed conviction:** The market prediction direction is
   encoded as the SIGN of the conviction. Up at 0.15 → +0.15.
   Down at 0.08 → -0.08. One Linear atom carries both direction
   and confidence. The reckoner's discriminant learns that positive
   signed conviction with high exit grace-rate predicts Grace.

## What doesn't change

- The market observer's encoding or learning
- The exit observer's encoding or learning
- The broker's propagate() — still learns from last_composed_anomaly
- The paper mechanics
- The simulation
- The extraction pipeline (proposals 027-029)
- The broker's self-assessment (already exists)

## Questions

1. Should the broker ONLY think about opinions (drop the extracted
   facts)? Or opinions + extracted context? The extracted facts
   add ~100 atoms of candle context. The opinions add ~7 atoms of
   decisions. The ratio matters — 7 opinions in a bundle of 114
   atoms might be drowned.

2. The edge is computed from the broker's OWN curve. Including
   it as an input fact creates a feedback loop — the broker's
   conviction influences its edge which influences its thought
   which influences its conviction. Is this circular or
   self-correcting?

3. Should the exit's distances be Log-encoded (they're small
   positive fractions, 0.001-0.10) or Linear-encoded?
