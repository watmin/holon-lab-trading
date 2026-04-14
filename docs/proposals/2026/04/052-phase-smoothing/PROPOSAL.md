# Proposal 052 — Phase Smoothing

**Scope:** userland

**The builder doesn't know what to express for this.**

## The measurement

The phase labeler produces phases that last 1-2 candles 55%
of the time. 34% of all candles are in a 1-candle phase.
~340 phase changes per 1000 candles — a change every ~3 candles.

```
Phase duration distribution (10k candles):
  1 candle:     3418  (34.2%)
  2 candles:    2079  (20.8%)
  3-5 candles:  2936  (29.4%)
  6-10 candles: 1277  (12.8%)
  11-20:         279   (2.8%)
  20+:            11   (0.1%)
```

The labeler flags every wiggle as a structural turn. The
Sequential encodes these 1-candle "phases" as ordered thoughts.
The position observer bundles them into its thought. The
reckoner tries to find patterns in noise.

## The current design

Two tracking states (Rising/Falling). Three labels derived from
position relative to the tracked extreme. 1.0 ATR smoothing.
Peak = within smoothing/2 of the tracked high. Valley = within
smoothing/2 of the tracked low. Transition = everything else.

The smoothing/2 threshold means: if ATR is $20, a $10 move
crosses the Peak/Valley boundary. At 5-minute BTC candles,
$10 is a routine candle. The labeler sees a peak every time
price bumps $10 above the recent low, and a valley every time
it dips $10 below the recent high.

## The question

The labeler is too eager. It sees structure in noise. But:

1. Making it less eager (wider smoothing) means it misses
   genuine short-term structure. A real 3-candle reversal at
   a key level might be invisible.

2. The market has structure at MULTIPLE scales. A 5-candle dip
   within a 200-candle uptrend. Both are real. The labeler can
   only see one scale at a time.

3. The phase labeler feeds the Sequential thought, the phase
   scalars, and the market observer's boundary weight. If the
   phases are noise, all three downstream consumers learn from
   noise.

## What the builder sees

The builder doesn't trust the phases. The builder sees 34%
single-candle phases and knows: that's not structure. The
builder doesn't know what the right smoothing is. The builder
doesn't know if the problem is the smoothing parameter or the
architecture itself.

## For the designers

1. **Is 1.0 ATR the right smoothing?** The original debate:
   Seykota said 1.0, Van Tharp said 1.5, Wyckoff said adaptive
   (percentile of recent swings). The measurement says 1.0 is
   too eager. What's right?

2. **Should the labeler have a minimum phase duration?** A
   "phase" that lasts 1 candle isn't a phase — it's a sample.
   Should the labeler require N candles before declaring a new
   phase?

3. **Is the architecture right?** Two tracking states with
   derived labels. Or should it be different? A zigzag with
   minimum swing size? A multi-scale labeler that sees structure
   at different horizons? Something the panel hasn't proposed?

4. **What does a good phase distribution look like?** How many
   phases per 1000 candles is right? What's the minimum duration
   that carries signal? The builder has no intuition here.

5. **Should the Sequential encode ALL phases or only
   "significant" ones?** If most phases are noise, should the
   Sequential filter before encoding? Or should it encode
   everything and let the reckoner sort?

6. **Does the phase labeler belong at 1.0 ATR at all?** Maybe
   the 5-minute candle is the wrong scale for phase detection.
   Maybe the labeler should run on hourly closes, or on a
   smoothed price series, not raw 5-minute closes.
