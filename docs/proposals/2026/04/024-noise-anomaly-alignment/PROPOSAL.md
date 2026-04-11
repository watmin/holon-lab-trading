# Proposal 024 — Noise-Anomaly Alignment

**Date:** 2026-04-11
**Author:** watmin + machine
**Status:** PROPOSED

## The mismatch

The reckoner PREDICTS on the anomaly (noise-stripped thought). The
reckoner LEARNS from the original thought (propagated back from
the broker). They are different vectors. The discriminant is built
from one distribution and evaluates another.

```scheme
;; Prediction time (candle N):
(let ((thought (encode lens candle)))
  (let ((anomaly (anomalous-component noise-subspace thought)))
    (predict reckoner anomaly)))   ;; reckoner sees the ANOMALY

;; Learning time (candle N+K, paper resolved):
(observe reckoner thought label weight)  ;; reckoner sees the FULL THOUGHT
```

The noise subspace at candle N stripped certain directions. The
reckoner predicted based on what remained. K candles later, the
broker propagates the ORIGINAL thought — which includes the
directions that were stripped. The reckoner learns from a vector
it never evaluated. The discriminant drifts.

## The fix

The paper stores the ANOMALY from prediction time. The broker
propagates the anomaly, not the original thought. The reckoner
learns from what it actually saw.

```scheme
;; Prediction time (candle N):
(let ((thought (encode lens candle)))
  (let ((anomaly (anomalous-component noise-subspace thought)))
    (predict reckoner anomaly)
    ;; Store the ANOMALY on the paper — this is what the reckoner saw
    (set! paper :prediction-thought anomaly)))

;; Learning time (candle N+K, paper resolved):
;; Propagate what the reckoner ACTUALLY predicted on
(observe reckoner (:prediction-thought paper) label weight)
```

The noise subspace at candle N is different from candle N+K. That
doesn't matter. The reckoner should learn: "when I saw THIS anomaly,
the outcome was Grace." Not "when the market looked like THIS (full
thought), the outcome was Grace." The reckoner never saw the full
thought. It saw the anomaly. The anomaly IS the input. The label IS
the output. The training pair must match.

## The loop in wat

```scheme
;; The observer's full loop per candle:
(define (observe-candle observer candle window ctx)
  ;; 1. Encode — all N facts for this lens
  (let ((thought (encode-thought ctx candle window (:lens observer))))
    ;; 2. Noise subspace updates — learns the background
    (update (:noise-subspace observer) thought)
    ;; 3. Strip — what remains is the anomaly
    (let ((anomaly (anomalous-component (:noise-subspace observer) thought)))
      ;; 4. Predict — the reckoner evaluates the anomaly
      (let ((prediction (predict (:reckoner observer) anomaly)))
        ;; 5. Return: the ANOMALY (for paper storage), the prediction
        (list anomaly prediction)))))

;; The paper stores the anomaly:
(define (register-paper broker anomaly prediction direction price dists)
  (make-paper
    :prediction-thought anomaly    ;; what the reckoner saw
    :composed-thought composed     ;; for exit observer composition
    :market-thought anomaly        ;; for market observer learning
    :prediction direction
    :entry-price price
    :distances dists))

;; At paper resolution, the broker propagates the anomaly:
(define (propagate-market-signal broker paper outcome)
  (observe (:reckoner market-observer)
    (:prediction-thought paper)    ;; the ANOMALY from prediction time
    (direction-label outcome)
    (weight outcome)))
```

## Each thinker owns their noise

Six market observers, each with its own noise subspace. Each learns
its own background from its own lens. The momentum observer's noise
is different from the regime observer's noise. Each strips what's
always true FOR ITS LENS.

The broker also has its own noise subspace on the COMPOSED thought.
The broker's anomaly is what's unusual about this specific (market,
exit) combination. The broker's paper stores the broker's anomaly.

Each thinker:
1. Owns its noise subspace
2. Strips its own background
3. Predicts on its own anomaly
4. Stores the anomaly on the paper
5. Learns from its own anomaly at resolution

No cross-contamination. No mismatch. Each thinker sees the same
vector at prediction time and learning time.

## What changes

1. **PaperEntry** gains `prediction_thought: Vector` — the anomaly
   from prediction time. This is what the market observer's reckoner
   evaluated. Separate from `composed_thought` (which the broker and
   exit observer use).

2. **Market observer observe()** — returns the anomaly alongside the
   prediction. Re-enable noise stripping (it's currently OFF).

3. **Broker register_paper** — stores the anomaly as `prediction_thought`.

4. **Broker propagation** — sends `prediction_thought` (the anomaly)
   to the market observer learn channel, not the original thought.

5. **Broker propose()** — re-enable noise stripping on the composed
   thought. Store the broker's anomaly for its own learning.

## The prior experiments, reinterpreted

**Cascade + strip vs cascade + no strip: same disc_strength.** Both
had the mismatch — strip used anomaly for prediction but original
for learning. No-strip used original for both (consistent, but
no filtering). Neither was correct. The aligned version (anomaly
for both) has never been tested.

**The noise subspace "doesn't matter"** was wrong. The noise
subspace DOES matter — but only when prediction and learning are
aligned. The prior test compared "mismatched with strip" vs
"consistent without strip." The correct comparison is "consistent
WITH strip" — anomaly for both prediction and learning.

## Questions

1. The anomaly at prediction time is a snapshot — the noise
   subspace was in a specific state. Storing it means the paper
   carries a 10,000-dim vector from a past noise model. Is the
   training honest? The reckoner learns from an anomaly computed
   by a stale noise model. Is that ok?

2. Memory: each paper now carries TWO 10,000-dim vectors
   (prediction_thought + composed_thought). Doubles the paper size.
   With 1000+ papers per broker, that's significant. Can we share
   or compress?

3. Should the broker's anomaly also be aligned? The broker predicts
   Grace/Violence on the noise-stripped composed thought. The broker
   should learn from the same noise-stripped composed thought. Same
   fix, same alignment.
