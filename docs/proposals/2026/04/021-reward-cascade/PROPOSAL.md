# Proposal 021 — The Reward Cascade

**Date:** 2026-04-11
**Author:** watmin + machine
**Status:** PROPOSED
**Supersedes:** Proposals 017-020 (the learning loop, three learners,
signal path, dual observation — all superseded by this unified design)

## The insight

Each learner is graded at a DIFFERENT moment in the paper's life.
The market observer at excursion-crosses-trail. The exit observer at
runner resolution. The broker at paper resolution. They share a paper
but see different events from it.

## The cascade

A paper ticks every candle. Three events can happen:

### Event 1: Excursion crosses the trail → Market observer learns

The buy-side excursion exceeds the trail distance. The trade was a
good idea to enter. The market called it right.

```
if paper.buy_excursion() > paper.distances.trail && !paper.buy_signaled:
    propagate to market observer:
        thought = paper.composed_thought (the market component)
        label = Up
        weight = buy_excursion (the magnitude of the move)
    paper.buy_signaled = true  // only signal once per side
```

Same for sell-side:
```
if paper.sell_excursion() > paper.distances.trail && !paper.sell_signaled:
    propagate to market observer:
        label = Down
        weight = sell_excursion
    paper.sell_signaled = true
```

The market observer is graded by the MARKET. The excursion crossed
the trail — the market committed in that direction. The trail distance
defines "tradeable move" — that's not contamination, that's the
definition of success. A move that doesn't exceed the trail isn't a
tradeable reversal.

The opposite: if the stop fires before the excursion crosses the
trail, the market observer gets Violence. The entry was wrong.

```
if paper.buy_resolved && !paper.buy_signaled:
    propagate to market observer:
        label = Down (the market went against the buy)
        weight = stop_distance - buy_excursion (how badly it failed)
    paper.buy_signaled = true
```

### Event 2: Runner resolves → Exit observer learns

A runner is a paper that crossed the trail (Event 1 already fired).
The runner continues ticking. The trail follows. Eventually the trail
fires — the runner resolves.

The exit observer learns: "for this composed thought, the optimal
distances were X." Computed from hindsight replay of the runner's
price history.

```
if paper.buy_resolved && paper.buy_signaled:
    // This WAS a runner — it crossed the trail before resolving
    optimal = compute_optimal_distances(price_history)
    propagate to exit observer:
        composed = paper.composed_thought
        optimal_distances = optimal
        weight = buy_excursion (how much value was available)
```

The exit observer ONLY learns from runners — papers where the market
was right. Failed entries (stop fired before trail crossed) don't
teach the exit observer. Failed entries are the market observer's
problem. The exit observer manages winners, not losers.

### Event 3: Paper fully resolves → Broker learns

Both sides have resolved (each side fired its trail or stop). The
broker sees the full picture: Grace or Violence for the composition.

```
if paper.fully_resolved():
    outcome = compute_outcome(paper)
    propagate to broker reckoner:
        composed = paper.composed_thought
        label = Grace or Violence
        weight = residue amount
```

The broker learns accountability for the PAIRING. The market observer
might be good. The exit observer might be good. But this specific
pairing either produced value or it didn't. The broker gates future
trades from this pairing based on its own proof curve.

## The separation

| Learner | Graded at | Question | Label |
|---------|-----------|----------|-------|
| Market observer | excursion crosses trail | was the entry right? | Up/Down + magnitude |
| Exit observer | runner resolution | was the management right? | optimal distances |
| Broker | paper resolution | was the pairing right? | Grace/Violence + residue |

Three learners. Three moments. Three questions. No shared label.
No coupling. No contamination.

## The paper lifecycle

```
REGISTERED → ticking every candle
    ↓
buy excursion > trail? → signal market observer (Up, Grace)
sell excursion > trail? → signal market observer (Down, Grace)
    ↓
buy stop fires before trail? → signal market observer (Down, Violence)
sell stop fires before trail? → signal market observer (Up, Violence)
    ↓
buy trail fires (was runner) → signal exit observer (optimal distances)
sell trail fires (was runner) → signal exit observer (optimal distances)
    ↓
both sides resolved → signal broker (Grace/Violence)
    ↓
paper removed
```

## Changes required

1. **PaperEntry** — add `buy_signaled: bool`, `sell_signaled: bool`.
   Track whether Event 1 has fired for each side.

2. **Broker tick_papers** — detect Event 1 (excursion crosses trail)
   alongside the existing Event 3 (side resolves). Return a new
   struct: `PaperSignal { market_signals, exit_signals, resolutions }`.

3. **Market observer** — remove self-grading from observe(). Remove
   broker propagation (already removed). Learn ONLY from Event 1
   signals routed through the broker. Remove prev_thought, prev_close.

4. **Exit observer** — learn ONLY from Event 2 (runner resolution).
   Currently learns from all resolutions. Filter to runners only.

5. **Binary** — route Event 1 signals to market observer learn channels.
   Route Event 2 signals to exit observer learn. Route Event 3 to
   broker learn. Three different signal paths from one paper tick.

## What this resolves

- Hickey: label no longer complected with exit distances (market learns
  from excursion, not resolution)
- Beckman: signal path is clean (each learner sees the right event)
- Ignorant: no circularity (excursion is a market fact, not a paper
  mechanics artifact)
- Ignorant: Grace is defined per learner (three different definitions)
- The horizon ghost: no fixed horizon. The paper's excursion crossing
  the trail IS the natural horizon. The market picks it.
