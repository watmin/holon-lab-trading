# Proposal 036 — Exit Journey Learning

## The Problem

The exit observer is a trade MANAGER. It proposes distances every
candle. The trade lives or dies by those distances. The exit should
be graded on management quality — per candle, during the trade.

Currently: the deferred batch sends one observation per candle of
a runner's life, all marked `is_grace: true`. The runner succeeded,
so every candle along the way is labeled Grace. This is a lie.

A runner that nearly hit the stop 30 times before reaching the
trail — those 30 near-miss candles weren't good management. The
final outcome was Grace but the path was violent. The exit observer
learns "everything I did was right" when the truth is "I got lucky
on 30 candles and managed well on 5."

The evidence: exit observer grace_rate is 87-93%. Almost all Grace.
The rolling window that should reflect management quality instead
reflects survivor bias — only runners produce batch observations,
and runners are Grace by definition. Violence papers produce one
observation each. Grace papers produce N observations (one per
candle of life). The Grace count dominates by volume.

## The Model

The exit observer manages a trade. Every candle is a management
event. The simulation knows the optimal distances at each candle.
The actual distances are what the exit observer proposed. The gap
between actual and optimal IS the grade.

Three outcomes per candle of a runner's life:

1. **Grace** — the actual distances were close to optimal. The
   management was good. The trade survived this candle because
   the distances were appropriate.

2. **Violence** — the actual distances were far from optimal. The
   management was poor. The trade survived this candle by luck,
   not by skill. The stop was too tight, or the trail was too
   wide, or both.

3. **The trade dies** — the stop fires. This IS Violence. The
   exit observer failed to manage. The distances were wrong for
   this moment. (Already handled by the immediate resolution
   signal.)

## The Grading

At each candle in the deferred batch:

```scheme
(let* ((actual-trail (:trail distances-at-candle))
       (actual-stop  (:stop distances-at-candle))
       (optimal-trail (:trail optimal-at-candle))
       (optimal-stop  (:stop optimal-at-candle))

       ;; The gap: how far from optimal?
       (trail-error (abs (- actual-trail optimal-trail)))
       (stop-error  (abs (- actual-stop optimal-stop)))

       ;; Normalize by the optimal magnitude
       (trail-ratio (/ trail-error (max optimal-trail 0.0001)))
       (stop-ratio  (/ stop-error (max optimal-stop 0.0001)))

       ;; The grade: close to optimal = Grace, far = Violence
       ;; Threshold: if error > 50% of optimal, it's Violence
       (is-grace (and (< trail-ratio 0.5)
                      (< stop-ratio 0.5))))

  (observe-distances exit-obs thought optimal weight is-grace residue))
```

The threshold (50% of optimal) is a starting point. The curve
judges it. If the threshold is too tight, everything is Violence
and the exit never learns Grace. If too loose, everything is
Grace and we're back to the current lie. The threshold should be
learned — but that's a future refinement.

## The Weight

Currently all batch observations have the same weight. The weight
should reflect how far into the trade this candle was. Early
candles (near entry) should weigh less — the trade hasn't proven
itself yet. Late candles (near exit) should weigh more — the
management decisions that matter most are the ones near the end.

Or: the weight should reflect the residue at that candle. Candles
where the trade had high excursion (far from entry, capturing
value) should weigh more than candles near the entry.

## The Impact

1. **Exit grace_rate becomes honest.** Currently 87-93% — survivor
   bias. After the fix: reflects actual management quality.
   Expected: 40-60%.

2. **The exit discriminant sharpens.** Currently the exit learns
   "everything is Grace." After: it learns the difference between
   good management and lucky management. The discriminant can
   separate "this thought pattern leads to good distances" from
   "this thought pattern leads to near-misses."

3. **The structure exit lens might revive.** Currently dead (0%
   grace). After: it receives mixed Grace/Violence from the
   journey, not all-Violence from the resolution. It might learn.

## What Doesn't Change

- The market observer learning (already proven)
- The broker accounting (already honest)
- The immediate resolution signal (Violence = stop fired, Grace = trail fired)
- The pipeline architecture (no wiring changes)
- The telemetry (same metrics, different values)

## The Question

The optimal distances are computed by the simulation AFTER the
trade resolves — it's hindsight. The actual distances are what
the exit proposed DURING the trade. The comparison is always
hindsight-graded. Is this honest? The exit observer can't know
the optimal distance during the trade. It can only know after.

But that's the entire learning model. The journal accumulates
hindsight-labeled observations. The discriminant learns to
predict what hindsight will say. The exit observer learns:
"when I see this thought, the optimal trail distance was X."
The hindsight IS the teacher. The journey grading just makes
the teacher more granular — per candle instead of per trade.

## Designers

Pending review.
