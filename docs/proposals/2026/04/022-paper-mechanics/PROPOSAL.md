# Proposal 022 — Paper Mechanics: One Guess, One Measurement

**Date:** 2026-04-11
**Author:** watmin + machine
**Status:** PROPOSED
**Follows:** Proposal 021 (reward cascade — accepted)

## The design

The market observer makes ONE prediction: Up or Down. One guess.
One stance. That's all it does.

The broker tests the guess by playing a superposition — a paper
with both buy and sell halves. The paper is the broker's measurement
device. The market doesn't know about the superposition. The market
just guesses.

## The paper

Each paper has four triggers. Two per half. Trail and stop.

**Buy half:**
- Trail trigger: `entry_price + entry_price * trail_distance` (above entry)
- Stop trigger: `entry_price - entry_price * stop_distance` (below entry)

**Sell half:**
- Trail trigger: `entry_price - entry_price * trail_distance` (below entry)
- Stop trigger: `entry_price + entry_price * stop_distance` (above entry)

The paper ticks every candle. The FIRST trigger to fire determines
the outcome. One trigger. Paper done.

## The four outcomes

The market observer predicted a direction. The paper measures it.

```
Market predicted Up:
  buy trail crosses   → (Up, Grace)    — market correctly identified buy reversal
  buy stop fires      → (Up, Violence) — market was wrong about the buy reversal

Market predicted Down:
  sell trail crosses  → (Down, Grace)    — market correctly identified sell reversal
  sell stop fires     → (Down, Violence) — market was wrong about the sell reversal
```

Only the predicted side matters. The other half exists in the
superposition but its triggers are irrelevant to the market observer.
The broker measures the PREDICTED side.

## Who learns what

**Market observer:**
- Grace: `observe(thought, predicted_direction, +excursion)` — "your
  thought correctly preceded a tradeable reversal in this direction"
- Violence: `observe(thought, opposite_direction, +stop_distance)` —
  "your thought was wrong about this direction"
- The market observer learns to predict tradeable reversals. Not
  price movement. Not paper outcomes. Reversals.

**Exit observer (only if Grace — runner formed):**
- The trail crossed. The paper becomes a runner. The trail follows
  the extreme. Eventually the trail fires (the retracement caught up).
- `observe_distances(composed, optimal_distances, weight=residue)`
- The exit observer learns: "for this context, these distances would
  have captured the most residue from this runner."
- If the market was wrong (Violence), the exit observer learns NOTHING.
  Failed entries are the market's problem.

**Broker (at final paper resolution):**
- Grace: the runner produced residue after the trail fired.
- Violence: the runner produced no residue (trail fired too early,
  distances too tight, gave back the gains).
- `observe(composed, Grace_or_Violence, weight=residue)`
- The broker learns: "this pairing, in this context, produced value."

## The paper lifecycle

```
REGISTERED
  market_prediction = observer's Up or Down
  entry_price = current close
  four triggers set from distances
      ↓
TICKING (every candle)
  check the PREDICTED side's triggers only:
    predicted_side trail crosses?
      → GRACE for market observer
      → paper transitions to RUNNER
    predicted_side stop fires?
      → VIOLENCE for market observer
      → paper REMOVED (no runner, no exit learning)
      ↓
RUNNER (if Grace — ticking continues)
  trail follows the extreme
  exit observer manages distances (step 3c breathing)
  trail fires (retracement caught up):
    → exit observer: learn optimal distances
    → broker: learn Grace/Violence from residue
    → paper REMOVED
```

## What the market observer predicts

The market observer's prediction carries TWO pieces of information:
1. **Direction**: Up or Down — which reversal do I see?
2. **Conviction**: how strongly — the cosine against the discriminant.

The broker uses BOTH. Direction determines which half to measure.
Conviction feeds the broker's edge computation (accuracy at this
conviction level from the proof curve).

The market observer doesn't need to predict "how far" or "how long."
Just "which way" and "how sure." The paper tests "which way." The
conviction-accuracy curve validates "how sure."

## What changes from today

1. **PaperEntry** gains: `market_prediction: Direction`, fixed
   `buy_stop` and `sell_stop` levels (today only has trailing stops).
   Gains `signaled: bool` to track whether the market signal fired.

2. **Paper tick** checks the predicted side's triggers only.
   First trigger to fire determines outcome. Paper lifecycle changes
   from "both sides resolve independently" to "one measurement."

3. **Broker tick_papers** returns a new struct with market signals
   (for market observer learn) and runner resolutions (for exit
   observer learn) separately from broker resolutions.

4. **Market observer** removes self-grading from observe(). Removes
   broker propagation. Learns ONLY from the paper's measurement of
   its own prediction, routed through the broker.

5. **Binary** routes three signal types to three learn channels.

## Questions for the designers

1. The paper only measures the PREDICTED side. The opposite side's
   triggers exist but don't fire for learning purposes. Should the
   opposite side be tracked at all? Or should the paper only have
   TWO triggers (trail and stop for the predicted direction)?

2. The stop distance defines "how wrong is wrong." The trail distance
   defines "how right is right." Both are exit observer parameters.
   The market observer is graded by them. Is this acceptable? The
   alternative is fixed thresholds — which are magic numbers.

3. A paper that sits between trail and stop for hundreds of candles —
   the market neither confirmed nor denied. Should there be a
   timeout? Or does the paper live forever until a trigger fires?

4. The market observer's conviction is used by the broker for edge.
   But the conviction is computed BEFORE the paper tests it. Should
   the conviction influence the paper's parameters (tight stops for
   high conviction, wide stops for low)?
