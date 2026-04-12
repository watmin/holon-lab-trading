# Proposal 031 — Broker Derived Thoughts

**Date:** 2026-04-12
**Author:** watmin + machine
**Status:** PROPOSED

## The situation

The broker wiring is clean. Both sides teach. Cache at 97.8%.
Honest counts. Typed inputs. Opinions in the vocabulary. The
broker differentiates by exit lens — exit-generalist at 55.6%
Grace, exit-structure at 28.6%. The signal exists in the raw
counts but the reckoner can't find it in the thought vectors.

The broker's noise subspace correctly strips constants. The
broker's best predictor — "which exit am I paired with" — is
a fixed property. Constants get stripped. The thing that predicts
is the thing that gets removed.

The broker needs thoughts that VARY per candle AND correlate
with Grace/Violence outcomes. Not raw opinions. DERIVED thoughts.
Relationships. Ratios. Interactions. The institutional trader's
toolkit applied to the data already on the pipe.

## The derived thoughts

Nine pure functions. Values already on the pipe in, ThoughtASTs
out. No new wiring. No new pipes. No new state.

```scheme
;; 1. DISTANCE RELATIVE TO VOLATILITY
;;    "Is the trail wide or tight for THIS market?"
;;    0.8% trail / 0.2% ATR = 4x (wide, room to breathe)
;;    0.8% trail / 1.5% ATR = 0.5x (tight, noise will stop us)
(Log "trail-atr-multiple" (/ trail (max atr-ratio 0.001)))
(Log "stop-atr-multiple"  (/ stop  (max atr-ratio 0.001)))

;; 2. RISK-REWARD RATIO
;;    "How much room to win vs room to lose?"
;;    trail / stop. High = defensive. Low = aggressive.
(Linear "risk-reward-ratio" (/ trail (max stop 0.001)) 1.0)

;; 3. CONVICTION-VOLATILITY INTERACTION
;;    "Is the signal clean or noisy?"
;;    High conviction + low vol = clean. High conviction + high vol = noise.
(Linear "conviction-vol" (* signed-conviction (/ 1.0 (max atr-ratio 0.001))) 1.0)

;; 4. EXIT CONFIDENCE
;;    "Does the exit know what it's doing?"
;;    grace-rate × residue. Both high = good AND profitable.
(Linear "exit-confidence" (* exit-grace-rate (max exit-avg-residue 0.001)) 1.0)

;; 5. SELF-EXIT AGREEMENT
;;    "Am I performing like my exit?"
;;    Divergence = regime shifted for this pairing.
(Linear "self-exit-agreement" (- broker-grace-rate exit-grace-rate) 1.0)

;; 6. ACTIVITY RATE
;;    "How many papers per unit time?"
;;    High = stretched. Low = selective.
(Log "activity-rate" (/ (max paper-count 1) (max paper-duration 1)))

;; 7. EXCURSION-TRAIL RATIO
;;    "Are papers reaching Grace?"
;;    > 1 = papers typically hit the trail. < 1 = fall short.
(Linear "excursion-trail-ratio" (/ excursion-avg (max trail 0.001)) 1.0)

;; 8. MARKET SIGNAL STRENGTH
;;    "How anomalous is this candle?"
;;    Norm of the market anomaly. High = strong signal candle.
(Log "market-signal-strength" (max (norm market-anomaly) 0.001))

;; 9. EXIT SIGNAL STRENGTH
;;    "How anomalous is the exit thought?"
(Log "exit-signal-strength" (max (norm exit-anomaly) 0.001))
```

## Why these vary

- trail-atr-multiple: ATR changes every candle. Same trail, different ratio.
- risk-reward-ratio: trail and stop change as the exit learns.
- conviction-vol: conviction flips and scales every candle.
- exit-confidence: grace-rate rolls, residue rolls.
- self-exit-agreement: both rolling averages drift.
- activity-rate: paper count changes, duration changes.
- excursion-trail-ratio: excursion-avg rolls.
- market-signal-strength: anomaly norm varies every candle.
- exit-signal-strength: anomaly norm varies every candle.

The noise subspace strips what's constant. These vary. The
reckoner sees the variation. The discriminant finds which
variations correlate with Grace.

## Where ATR comes from

The broker needs ATR-ratio for thoughts 1 and 3. ATR-ratio is
on the candle. It's encoded by the market vocabulary as a fact.
It MAY be in the extracted market facts (if it survived the
noise floor). But the broker can't rely on extraction — it needs
ATR-ratio directly.

Options:
A. Add ATR-ratio to the broker pipe. The candle is available
   at the grid level where the pipe is sent.
B. Use the market anomaly's norm as a volatility proxy (thought 8).
   Not as precise as ATR but always available.
C. Send the enriched candle's ATR-ratio as an f64 on the pipe.

Option C is simplest. One f64. Already computed. Already on
the candle struct.

## What changes

1. **New vocab module:** `src/vocab/broker/derived.rs` — nine
   pure functions that take existing pipe values and return
   `Vec<ThoughtAST>`.

2. **Broker pipe gains ATR-ratio:** One f64 added to the broker
   input tuple.

3. **Broker pipe gains anomaly norms:** Market anomaly norm and
   exit anomaly norm. Two f64s. Computed at the grid level before
   sending. Or computed in the broker thread from the vectors
   already on the pipe.

4. **Broker thread encodes derived facts:** Appended to the
   broker's bundle alongside opinions + extracted + self.

## What doesn't change

- All observer encoding and learning
- The extraction pipeline
- The cache protocol
- The paper mechanics
- The simulation
- The broker's propagate() and learning path
