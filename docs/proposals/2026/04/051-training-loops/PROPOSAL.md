# Proposal 051 — Training Loops: What Exists, What's Missing

**Scope:** userland

**This is not a change proposal.** This is a request for criticism
of the current training loops. The builder doesn't know what to
propose. The builder wants feedback on what exists.

## The current training loops

### Market observer — learns direction

The broker resolves a paper. Did the predicted direction match
the actual price movement? (`price > resolution.entry_price`
for Up.) Correct → learn the predicted direction. Incorrect →
learn the opposite.

Weight is doubled at phase boundaries (`phase_duration <= 5`).
The market observer learns MORE at structural turns but does
not KNOW about the phase structure. It thinks about the candle
through its market lens. The phase connection is only the
weight modulation.

Signal: broker → market_learn_tx → market observer learn mailbox.
Label: Correct/Incorrect (directional accuracy).
Weight: facts.weight × 2.0 at phase boundaries, × 1.0 otherwise.

### Position observer — learns distances

Each paper resolution sends an immediate Grace/Violence signal.
Deferred batch training: the broker's journey grading uses a
per-broker rolling percentile (N=200, median) of error ratios.
Each batch observation is labeled Grace (error below median)
or Violence (error above median).

The position observer THINKS about phases:
- Core lens: regime + time + 5 trade atoms
- Full lens: regime + time + phase label + phase duration +
  Sequential series + phase scalars + 13 trade atoms

Signal: broker → position_learn_tx → position observer learn mailbox.
Label: Grace/Violence from trade outcome (immediate) and
  error-vs-median (deferred batch).

### Broker — learns accountability

The broker's reckoner predicts from the composed thought:
market_anomaly + position_anomaly + portfolio_biography.

Grace/Violence from paper outcomes. The broker grades the
PAIR — did this (market, position) pairing produce residue?

The portfolio biography includes phase trend atoms (valley-
trend, peak-trend, regularity, entry-ratio, avg-spacing).

Papers register every candle (Proposal 043). Papers never stop.
Funding is gated at `resolved >= 200 && ev > 0.0` (not yet
implemented — awaiting treasury).

### Phase labeler — ground truth

The indicator bank labels every candle as valley, peak, or
transition. Two tracking states (Rising/Falling), three labels
derived from position relative to the tracked extreme. 1.0 ATR
smoothing. The labeler is NOT a predictor. It is a measurement.
It classifies the present moment from price structure.

The phase label rides the Candle. Every observer sees it. The
position observer thinks about it. The market observer's weight
is modulated by it. The broker's portfolio biography includes
phase trend scalars computed from it.

## The questions

The builder doesn't trust the broker yet. The infrastructure is
proven — six wards, 81 files, near-zero findings. The wiring is
correct. But:

1. **Are the training labels honest?** The market observer learns
   from directional accuracy. The position observer learns from
   trade outcome + journey grading. The broker learns from paper
   outcomes. Are these the right signals for each learner?

2. **Is the weight modulation (2× at phase boundaries) the right
   connection between the phase labeler and the market observer?**
   Should the market observer think about phases directly? Or is
   weight modulation the correct level of coupling — the market
   observer stays focused on the candle, the phases just tell it
   which candles matter more?

3. **The position observer's grace_rate oscillates to 0.0.**
   Experience keeps growing (508K core, 250K full) but the
   journey grading labels everything Violence during long
   stretches. The rolling percentile median converges and
   everything exceeds it. Is this a grading problem or a
   distance-prediction problem?

4. **Papers live ~8 candles and resolve 41% Grace.** Is this
   the right lifecycle? Should papers live longer (hold
   architecture, Proposal 038)? Should they resolve differently?

5. **The broker composes market + position + portfolio into one
   thought.** Is this the right composition? Should the broker
   think about the phase structure directly (not through the
   portfolio biography)? Should the broker have its own phase
   atoms?

6. **What's missing?** What training signal should exist but
   doesn't? What connection between components would improve
   learning? What feedback loop is broken or absent?

## For the designers

Five voices. Three strategy (Seykota, Van Tharp, Wyckoff).
Two architecture (Hickey, Beckman). Each should criticize what
exists and propose what's missing. Multiple rounds of debate.

The builder doesn't have a bias. The builder wants new thoughts.
