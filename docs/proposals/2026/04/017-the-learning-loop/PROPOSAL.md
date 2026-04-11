# Proposal 017 — The Learning Loop

**Date:** 2026-04-11
**Author:** watmin + machine
**Status:** PROPOSED

## The loop

The enterprise has a learning loop. It has always had one. This
proposal names it, identifies where the signal breaks, and asks
the designers how to fix it.

```
1. Market observer encodes the moment
   → "these indicators say extreme"

2. Exit observer encodes the context
   → "this volatility regime says give it room"

3. Broker composes them
   → proposes a trade (the superposition of market + exit)

4. Paper tests it
   → both sides simultaneously, market decides which fires first

5. Fast resolution = the market committed
   → the reversal was real (or not)

6. Broker sees Grace or Violence

7. Broker propagates back down:
   → Market observer: "you were right/wrong about direction"
   → Exit observer: "these were the optimal distances for this context"

8. Both learn. The reckoners sharpen. The next prediction is better.
```

The market observer spots reversals. The exit observer manages
reversals. The broker is the accountability of the pairing. The
paper is the test. The market is the judge. Grace or Violence.

## The measurement

At 2000 candles:
- disc_strength: 0.003-0.004 across all 6 observers
- conviction: 0.01-0.20 (noise)
- edge: 0.0 across all 24 brokers
- Grace/Violence: 39.7% (below 50%)
- Papers resolved: 95,218
- Experience per observer: 8,905

The reckoners accumulate. The prototypes build. The discriminant
doesn't sharpen. The loop runs but the signal doesn't land.

## Where the signal might break

### Theory 1: Direction label is contaminated by exit distances

The paper plays both sides. Buy-side trail fires → direction=Up.
But which side fires first depends on the trail DISTANCES, not just
the market direction. Tight buy trail + wide sell trail → buy fires
first even on a small up-move. The direction label is:

```
direction = f(market_move, buy_trail, sell_trail)
```

Not just `f(market_move)`. The market observer is told "Up" when
the truth is "buy-side distances resolved faster." The label is
coupled to the exit observer's choices.

If both sides have equal distances (default 0.015 trail, 0.030 stop),
the coupling is minimal — the market's direction dominates. But as
the exit reckoners learn different distances for different contexts,
the coupling grows. The market observer learns from a label that
is increasingly shaped by the exit observer.

### Theory 2: The edge computation is broken

The broker computes edge by predicting on `Vector::zeros(dims)`.
This gives zero conviction → zero accuracy → edge 0.0. The treasury
rejects every proposal. No real trades execute. The learning loop
runs ONLY through papers.

Fix: compute edge from the conviction of the actual proposal, not
a zero vector. `accuracy_at(propose_conviction)`. This unblocks
real trading but doesn't fix the paper-level learning.

### Theory 3: The noise subspace strips too much

Every observer updates its noise subspace, then computes the
anomalous component (what the noise CAN'T explain = the signal).
If the noise subspace is too aggressive, it strips the signal along
with the noise. The residual IS the prediction input. If the
residual is mostly noise that the subspace missed, the reckoner
learns from noise.

At k=8 principal components, the noise subspace learns the 8
strongest directions in thought-space. If the signal lives in one
of those 8 directions, it gets stripped. The subspace should learn
NOISE, not signal. But it learns from every thought — it doesn't
know which thoughts are signal and which are noise.

### Theory 4: All observers see similar thoughts

Despite different lenses, the observers might produce similar
thought vectors — the shared vocabulary (time + standard) dominates
the lens-specific vocabulary. If 60% of each thought is shared and
40% is lens-specific, the 60% shared component drowns the 40%
signal. The disc_strength is low because the prototypes ARE similar
— not because the reckoner can't learn, but because the inputs
are too alike.

### Theory 5: The reckoner needs more time

2000 candles with disc_strength 0.003 might be normal warmup.
The reckoner has 8905 observations but most are near-random early
papers. The signal emerges only after the noise subspace stabilizes,
the vocabulary facts become meaningful, and the paper resolutions
accumulate enough patterns. 100k candles showed 39.7% Grace — maybe
at 500k it crosses 50%.

## Questions for the designers

1. **The direction label**: is the coupling between exit distances
   and the direction label a real problem? Does it poison the market
   observer's learning? Or is it an acceptable approximation — "fast
   resolution ≈ market commitment" regardless of distances?

2. **The noise subspace**: at k=8, is it too aggressive? Should the
   market observer strip noise at all, or should the raw thought
   go directly to the reckoner? The noise subspace was designed for
   DDoS detection where "normal" is well-defined. In market data,
   what is "normal"?

3. **The time horizon**: how many candles should it take for
   disc_strength to exceed 0.01? 0.05? Is 2000 candles too early
   to judge? What's the expected warmup?

4. **The measurement**: what diagnostic would reveal WHERE in the
   loop the signal breaks? Can we measure the information content
   at each step — thought → noise-stripped → prediction → paper
   outcome → label → back to reckoner — and find the bottleneck?

5. **The prior result**: we achieved 60%+ multiple times before
   this architecture. What changed? The architecture added noise
   subspace, bucketed reckoners, incremental bundling, papers with
   independent sides. Which of these changes might have weakened
   the signal path?
