# Proposal 009: Dissolve Take-Profit and Runner-Trail — Two Distances

**Date:** 2026-04-10
**Author:** watmin + machine
**Status:** PROPOSED

## Context

The enterprise has four learnable distances on the exit observer: trail,
stop, tp, runner-trail. Each has its own continuous reckoner. Each has
its own scalar accumulator on the broker. The simulation module has four
simulate functions. The Distances struct has four fields. The Levels
struct has four fields.

The first smoke test of the ninth inscription ran 500 candles at 3/s.
The architecture held — the treasury correctly withheld, papers resolved,
Grace at 55.92%. But the complexity of four distances propagates through
every layer: four reckoners per exit observer, four accumulators per
broker, four simulate functions, four fields on every struct that carries
distances or levels.

## The question

Should we dissolve take-profit and runner-trail, leaving two distances:
**trail** and **stop**?

## The argument for dissolution

### Take-profit is a ceiling on a system designed to have no ceiling

The trailing stop follows the peak. It captures as much upside as the
market gives. It exits when the market reverses by the trail distance.
The TP exits at a FIXED level — "I predicted the price would reach X."
The TP caps the upside. A trade that would have run from 1% to 8% exits
at 3% because the TP said so. The trailing stop would have captured 8%
minus the trail distance. The TP destroyed 5% of residue.

The runner phase exists specifically to let winners run. The TP
contradicts the runner by exiting winners early.

### Runner-trail is a second trail that the reckoner can't distinguish from the first

The runner-trail was justified as: "the cost of stopping out a runner is
zero, so afford a wider distance." But the exit reckoner doesn't know
the phase. It sees the composed thought. It predicts one distance for
that thought. Step 3c re-queries every candle with the CURRENT thought —
not the entry thought. The market context at candle N+50 (deep in a
trend) is different from candle N (entry). The reckoner already predicts
wider for trending contexts and tighter for choppy ones. The adaptation
is in the thought, not in the phase label.

If the reckoner were to learn two different distances for the same
thought based on phase, it would need the phase as input. The phase is
not in the thought. It's portfolio state, not market state. The exit
observer thinks about market conditions.

### Two distances compose. Four don't add signal.

- **Trail:** how much reversal to tolerate. Learned per-thought. Adapts
  every candle via step 3c. Follows the peak. IS the profit mechanism.
- **Stop:** how much adverse movement to survive. Learned per-thought.
  Adapts every candle via step 3c. IS the loss mechanism.

Together they define the trade's entire lifecycle. The TP and runner-trail
are refinements that the trail already provides through continuous
adaptation.

## What changes

- **Distances struct:** `[trail : f64] [stop : f64]` — two fields
- **Levels struct:** `[trail-stop : f64] [safety-stop : f64]` — two fields
- **ExitObserver:** two continuous reckoners (trail, stop), not four
- **Broker:** two scalar accumulators, not four
- **Simulation:** `simulate-trail`, `simulate-stop` — two functions
- **PaperEntry:** simplified — one trailing stop per side
- **settle-triggered:** two paths (safety-stop fires, trail-stop fires)
- **compute-optimal-distances:** two sweeps, not four
- **Runner transition:** unchanged — step 3c still detects when trail
  passes break-even. The phase label persists. The distance doesn't
  change — the trail reckoner already adapts to the current context.

## What doesn't change

- The runner phase. It still exists. It marks "principal is covered."
  The trail continues to breathe. The distance doesn't switch.
- The accumulation model. Principal recovery, residue stays.
- The four-step loop.
- The learning mechanism. Reckoner, scalar accumulator, proof curve.
- The barrage. N×M brokers proposing.

## The risk

The TP protected against one scenario: a price spike that reverses
catastrophically in one candle (a gap through the trail). At 5-minute
BTC resolution, gaps this large are rare. And the breathing stops
would tighten the trail as volatility spikes — the reckoner sees the
regime change.

The runner-trail gave explicit "more room" after break-even. Without
it, the trail reckoner must learn this implicitly from the composed
thought. If the thought doesn't encode enough information about the
trending regime, the reckoner might predict tight trails during
runners, causing premature exits.

## The designers' question

Is the trailing stop — continuously adapted via step 3c, learned
per-thought by the exit reckoner — sufficient to replace both
take-profit (a fixed ceiling) and runner-trail (a phase-dependent
width)? Or do the four distances carry signal that two cannot?
